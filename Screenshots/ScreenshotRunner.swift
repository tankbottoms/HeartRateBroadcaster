import XCTest

/// Captures the App Store screenshot set, in one language per run.
///
/// The language is not chosen here — it is chosen by `scripts/screenshots.ts`,
/// which passes it through the `SCREENSHOT_LANG` / `SCREENSHOT_LOCALE`
/// environment variables and launches the app with `-AppleLanguages` and
/// `-AppleLocale`. Those two are read out of `NSArgumentDomain`, which sits at
/// the top of the `UserDefaults` search order, so the app comes up translated
/// without a single line of it knowing this test exists.
///
/// The same trick sets the heart rate source: `AppSettings` reads `source` from
/// plain `UserDefaults`, so `-source testSignal` gives every screenshot a live,
/// deterministic BPM instead of a dash.
///
/// WHAT A SIMULATOR CANNOT SHOW
/// CoreBluetooth peripheral mode does not exist in the simulator. The bridge row
/// will read as unsupported and no head unit will ever appear as subscribed, so
/// these images are not interchangeable with the hand-captured English set that
/// shipped with 1.0 — they are the localized set, and the English one should be
/// recaptured the same way if the two are ever to match.
final class ScreenshotRunner: XCTestCase {

    /// Screenshots come back as attachments on the test result bundle; there is
    /// no writable path from the simulator to the host. `scripts/screenshots.ts`
    /// exports them afterwards with `xcresulttool` and renames them by this
    /// prefix, so the ordinal is the App Store display order.
    private var shot = 0

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCaptureAppStoreSet() {
        let env = ProcessInfo.processInfo.environment
        // Required, not defaulted. `scripts/screenshots.ts` has to set these as
        // TEST_RUNNER_SCREENSHOT_LANG — a UI test is a separate process and gets
        // only the variables xcodebuild forwards under that prefix. Defaulting to
        // English here is how twenty-five languages quietly captured the same
        // English screenshots and reported success for every one of them.
        guard let language = env["SCREENSHOT_LANG"], let locale = env["SCREENSHOT_LOCALE"] else {
            XCTFail("SCREENSHOT_LANG and SCREENSHOT_LOCALE must be set (as TEST_RUNNER_SCREENSHOT_LANG / _LOCALE on the xcodebuild invocation).")
            return
        }

        let app = XCUIApplication()
        app.launchArguments = [
            // The parenthesised list is the format `UserDefaults` expects for
            // AppleLanguages; a bare string is accepted and then ignored, which
            // looks exactly like a translation that did not land.
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
            // A synthetic heart rate, so every language shows a number rather
            // than an em dash and the images are comparable to each other.
            "-source", "testSignal",
            // Off for the screenshots: Picture in Picture detaches a window over
            // the app and the Live Activity is not visible from inside the app
            // anyway, so both only add nondeterminism.
            "-pictureInPicture", "0",
        ]
        app.launchEnvironment = ["UITEST_SCREENSHOTS": "1"]
        // Explicit, because `launch()` on an app that is already in the
        // foreground has been observed to attach to the running process instead
        // of starting a new one — and a process that is already running keeps
        // the argument domain it was started with. That is how a run with
        // `-AppleLanguages (de)` on the command line came up in English: the
        // German launch arguments were never applied, because nothing launched.
        app.terminate()
        app.launch()

        // The first reading arrives on a timer. Waiting on the navigation bar
        // only proves the view loaded, so this waits for the app to be settled
        // and then gives the signal a beat to produce a number.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: 20)
        settle(2.5)

        alignToBeat(app)
        capture(app, "home")

        // The diagnostics live below the fold on every device. Two swipes rather
        // than one: an iPad shows most of the page at once and a phone does not,
        // and a swipe that has nowhere left to go is a no-op rather than an error.
        app.swipeUp()
        settle(0.6)
        capture(app, "status")
        app.swipeUp()
        settle(0.6)
        capture(app, "diagnostics")

        // Back to the top before opening anything, so the sheet animates over a
        // known screen and the screenshot behind it is the same in every language.
        app.swipeDown()
        app.swipeDown()
        settle(0.6)

        if tap(app.buttons["settings-button"]) {
            settle(1.2)
            capture(app, "settings")
            // The permissions row is near the bottom of a long form, and a
            // SwiftUI `Form` does not build rows it has not scrolled to. Waiting
            // for it first therefore times out on a row that is perfectly fine —
            // it simply does not exist yet. Scroll first, ask afterwards.
            let permissions = scrollUntilFound(app, "permissions-link", "checklist")
            if tap(permissions, in: app) {
                settle(1.2)
                capture(app, "permissions")
                // Back out by name would need twenty-five translations of "Back";
                // the first navigation bar button is the back button in all of them.
                let back = app.navigationBars.buttons.firstMatch
                if back.exists { back.tap() }
                settle(0.8)
            }

            _ = tap(app.buttons["settings-done"])
            settle(0.8)
        }

        if tap(app.buttons["about-button"]) {
            settle(1.2)
            capture(app, "about")
        }
    }

    /// A missing control is a warning, not a failure. A language that reaches
    /// five of seven screens is still shippable; a test that aborts on the first
    /// one leaves that language with nothing at all.
    private func tap(_ element: XCUIElement, in app: XCUIApplication? = nil) -> Bool {
        guard element.waitForExistence(timeout: 10), element.isHittable else {
            // The whole tree, into the build log. A control that cannot be found
            // is almost always present under a different element type than the
            // query assumed, and the tree is the only thing that says which.
            if let app { print("SCREENSHOT-MISSING\n\(app.debugDescription)") }
            return false
        }
        element.tap()
        return true
    }

    /// Finds a control by identifier without caring what kind of control it is.
    ///
    /// A toolbar `Button` surfaces as a button; the same identifier on a
    /// `NavigationLink` inside a `Form` surfaces as a cell on some OS versions
    /// and a button on others. Querying `app.buttons` alone is why the
    /// permissions screen was missing from the first two runs.
    private func find(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Scrolls a form down until a row shows up, and returns it.
    ///
    /// Two identifiers because a `Form` row is not one element. The identifier
    /// set on a `Label` lands on the row's accessibility element on some OS
    /// versions and is swallowed by the cell on others; the SF Symbol name, on
    /// the other hand, always appears as the identifier of the row's `Image`,
    /// and a tap on that image hits the row. The symbol is the fallback, not the
    /// first choice, because it is a design decision masquerading as a handle —
    /// change the icon and this stops working.
    ///
    /// Bounded rather than `while`: a row that is genuinely absent would
    /// otherwise swipe forever at the bottom of a list, and one hung language
    /// costs the whole run.
    private func scrollUntilFound(
        _ app: XCUIApplication, _ id: String, _ symbol: String, limit: Int = 8
    ) -> XCUIElement {
        for _ in 0..<limit {
            let byID = find(app, id)
            if byID.exists && byID.isHittable { return byID }
            let bySymbol = app.images[symbol]
            if bySymbol.exists && bySymbol.isHittable { return bySymbol }
            app.swipeUp()
            settle(0.4)
        }
        return find(app, id)
    }

    /// Waits for the heart rate to tick over, then lets the roll finish.
    ///
    /// The test signal updates once a second and the number animates with
    /// `.numericText()`, so a screenshot taken at an arbitrary moment has about
    /// a one-in-three chance of catching a digit halfway between two values.
    /// Watching for the change puts the capture at a known point in the cycle
    /// instead of a random one.
    ///
    /// Gives up rather than failing: on a device with no test signal — or if the
    /// reading happens to hold the same integer across a tick, which the sine
    /// does near its turning points — the screenshot is still worth taking.
    private func alignToBeat(_ app: XCUIApplication, timeout: TimeInterval = 3) {
        let value = find(app, "bpm-value")
        guard value.waitForExistence(timeout: 5) else { return }
        let before = value.label
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && value.label == before { settle(0.1) }
        // Longer than `.snappy`, which settles in about a third of a second.
        settle(0.5)
    }

    /// `sleep` rather than a predicate: what is being waited on is a SwiftUI
    /// animation finishing, which exposes no state to wait on.
    private func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        shot += 1
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = String(format: "%02d-%@", shot, name)
        // Kept regardless of the test outcome — the images are the product of
        // this test, not evidence about it.
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
