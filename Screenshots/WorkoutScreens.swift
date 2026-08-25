import XCTest

/// Captures the workout screens for the marketing site: the session card before
/// a ride, the live readout during one, the summary afterwards, and the body
/// details the calorie figure is derived from.
///
/// Separate from `ScreenshotRunner` on purpose. That one runs twenty-five times,
/// once per language, and produces the App Store set; this one runs once, in
/// English, and produces pictures for a web page. Sharing a class would mean
/// recording a workout in every language for no one's benefit.
///
/// A simulator has no Bluetooth radio, so `-demoMeters 1` stands a fabricated
/// trainer, crank and pedal pair in front of the app — see ``DemoMeters``. Every
/// pixel is still the app's own: its grouping, its arithmetic, its choice of
/// which source counts. Only the radio is missing.
final class WorkoutScreens: XCTestCase {
    private var shot = 0

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCaptureWorkoutScreens() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-source", "testSignal",
            "-pictureInPicture", "0",
            // Sensors the simulator cannot have. Debug-only, and the app ignores
            // the flag in a Release build.
            "-demoMeters", "1",
            // The language runner leaves the simulator in whatever locale it
            // finished on, so English has to be asked for rather than assumed.
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment = ["UITEST_SCREENSHOTS": "1"]
        app.terminate()
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: 20)
        // The heart rate arrives as a rolling digit animation. Long enough here
        // that it has finished rolling before the shutter, or the last digit
        // photographs as two glyphs on top of each other.
        settle(6)

        // Before the ride: sport picker and the Start button.
        capture(app, "workout-start")

        if tap(find(app, "session-toggle"), in: app) {
            // Calories accumulate at a few per minute, and the readout is a
            // rounded integer — thirteen seconds photographs a zero. Three
            // minutes puts a real number under the label at the 97 BPM the
            // test signal is pinned to.
            settle(185)
            capture(app, "workout-live")

            if tap(find(app, "session-toggle"), in: app) {
                // The summary arrives as a sheet, which animates up over the
                // screen behind it.
                settle(2.5)
                capture(app, "workout-summary")
                // Dismiss by dragging the sheet down: the sheet has no close
                // button and swiping is what a user does.
                app.swipeDown(velocity: .fast)
                settle(1.2)
            }
        }

        if tap(app.buttons["settings-button"], in: app) {
            settle(1.2)
            // A `Form` does not build rows it has not scrolled to, so each row is
            // scrolled into existence before it is asked for.
            // Body first and sensors last, so that if the pop back to Settings
            // ever fails it costs the run nothing: the last screen captured
            // needs no return journey.
            if tap(scrollUntilFound(app, "body-link"), in: app) {
                settle(1.2)
                capture(app, "body")
                back(app)
            }
            if tap(scrollUntilFound(app, "sensors-link"), in: app) {
                // Long enough for the picker to have an average to print beside
                // the instantaneous figure, and to have settled on the pedals.
                settle(8)
                capture(app, "sensors")
            }
        }
    }

    // MARK: - Plumbing

    /// Finds a control by identifier without caring what kind of control it is:
    /// the same identifier lands on a button, a cell, or an image depending on
    /// the OS version and the container it is in.
    private func find(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Scrolls down until a row exists and can be tapped. Bounded, so a row that
    /// is genuinely absent costs eight swipes rather than the whole run.
    private func scrollUntilFound(_ app: XCUIApplication, _ id: String, limit: Int = 8) -> XCUIElement {
        for _ in 0..<limit {
            let hit = find(app, id)
            if hit.exists && hit.isHittable { return hit }
            app.swipeUp()
            settle(0.4)
        }
        return find(app, id)
    }

    /// Leaves a pushed screen. The back control carries the previous screen's
    /// title, which is translated, so it is taken by position rather than name —
    /// and if it is not in a navigation bar at all, by the edge swipe that pops
    /// a stack whether there is a button to see or not.
    private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons.firstMatch
        if button.exists && button.isHittable {
            button.tap()
        } else {
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            edge.press(forDuration: 0.05,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        }
        settle(1.2)
    }

    /// A missing control is a warning, not a failure — four screens out of five
    /// is still four screens.
    private func tap(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.waitForExistence(timeout: 10), element.isHittable else {
            print("SCREENSHOT-MISSING\n\(app.debugDescription)")
            return false
        }
        element.tap()
        return true
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
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
