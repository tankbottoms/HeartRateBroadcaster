import SwiftUI

/// Single scrollable screen. `HeartRateBroadcaster_Spec_v2_Updated.md` §2.
struct ContentView: View {

    @Bindable var manager: HeartRateManager
    @State private var showSettings = false
    @State private var showAbout = false
    @State private var showBridgeInfo = false
    @State private var chosenSport: WorkoutSport = .cycling
    /// Non-nil for exactly as long as the summary sheet is up.
    @State private var finishedRecord: WorkoutRecord?
    @Environment(\.scenePhase) private var scenePhase

    /// Staleness is time-derived, so the view needs a heartbeat of its own or a
    /// dead watch keeps showing its last number forever.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var settings: AppSettings { manager.settings }
    private var broadcaster: BLEBroadcaster { manager.broadcaster }
    private var bridge: PhoneSessionBridge { manager.bridge }

    /// Frames are only ever sent to a subscriber, so a zero here says nothing
    /// about the watch link — it says no head unit has connected. Naming that
    /// keeps the count on screen (it is still the number that matters once one
    /// does) while removing the reading that it had stopped working.
    private var framesFooter: LocalizedStringKey {
        broadcaster.subscriberCount == 0
            ? "No broadcast subscriber connected · frames sent \(broadcaster.framesSent)"
            : "Frames sent \(broadcaster.framesSent) · last \(broadcaster.lastFrameHex)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Metric.sectionSpacing) {

                    VStack(spacing: Theme.Metric.cardSpacing) {
                        HRDisplayCard(bpm: manager.currentBPM,
                                      isStale: isStale,
                                      isBeating: !isStale,
                                      sampleAge: sampleAge,
                                      sourceLabel: manager.sourceLabel,
                                      // Built and localized by the manager, which
                                      // is where the sensor names live.
                                      reconciliation: manager.reconciliation.map { .init(stringLiteral: $0) },
                                      // Only while a session is live. The same
                                      // numbers sit on the session card below;
                                      // this is the copy you can read without
                                      // scrolling, which is the whole point of
                                      // it mid-ride.
                                      metrics: manager.recorder.state.isLive
                                          ? WorkoutMetricsStrip(elapsed: manager.recorder.elapsed,
                                                                watts: manager.recorder.currentWatts,
                                                                kilocalories: manager.recorder.runningKilocalories,
                                                                sport: manager.recorder.sport)
                                          : nil)
                        // Directly under the BPM, because both are things you
                        // read and act on without looking away from the road or
                        // the screen you are riding into.
                        if settings.bikeControlEnabled {
                            ShiftControlCard(service: manager.bikeControl,
                                             onGearChanged: { settings.bikeControlGear = $0 })
                        }

                        // Below the shifter rather than above it. The banner is
                        // the one block on this screen whose text genuinely
                        // changes length as things connect, and everything under
                        // it used to move when it did — including the two
                        // buttons the rider is aiming at mid-effort. Prose that
                        // moves belongs below the controls, not between them.
                        if settings.bridgeEnabled {
                            PairingBanner(isConnected: broadcaster.subscriberCount > 0,
                                          peerCount: broadcaster.subscriberCount,
                                          hasData: broadcaster.hasValue && !isStale)
                        }
                    }

                    SessionControlCard(recorder: manager.recorder,
                                       registry: manager.meters,
                                       chosenSport: $chosenSport,
                                       onFinished: { finishedRecord = $0 })

                    statusSection
                    settingsSection
                    BikeControlSection(service: manager.bikeControl,
                                       enabled: bind(\.bikeControlEnabled),
                                       gearCount: bind(\.bikeControlGearCount))
                    proSection

                    // Zero frames with the watch connected is the normal reading
                    // before a head unit subscribes, and reading it as "frames
                    // sent 0" made a working bridge look broken. The count is a
                    // count of frames sent *to subscribers*, so when there are
                    // none the honest label is that there is nobody to send to.
                    Text(framesFooter)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.bottom, 8)

                    // Picture in Picture will not start from a layer that is
                    // not on screen, so the source layer has to live in the
                    // hierarchy. Nothing is drawn here — the user sees the
                    // detached window, not this.
                    if settings.pictureInPicture {
                        PiPHostView(layer: manager.pip.displayLayer)
                            .frame(width: 1, height: 1)
                            .opacity(0.01)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, Theme.Metric.screenPadding)
                .padding(.vertical, Theme.Metric.cardSpacing)
            }
            .background(Theme.background)
            .navigationTitle("HeartRate Broadcaster")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The identifiers are for the screenshot runner in Screenshots/,
                // which has to find these buttons in twenty-five languages. A
                // label is translated and an SF Symbol is a picture; an
                // identifier is the only handle that is the same in every one.
                // They are never shown and never localized.
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAbout = true } label: { Image(systemName: "info.circle") }
                        .accessibilityIdentifier("about-button")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityIdentifier("settings-button")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(manager: manager)
            }
            .sheet(isPresented: $showAbout) {
                AboutView(settings: settings)
            }
            .sheet(isPresented: $showBridgeInfo) {
                BridgeInfoView(manager: manager)
            }
            .sheet(item: $finishedRecord) { record in
                NavigationStack { SessionSummaryView(record: record) }
            }
        }
        .tint(Theme.textPrimary)
        .onReceive(tick) { now = $0 }
        // Route change notifications only fire on an actual change, so AirPods
        // that connected while the app was backgrounded leave no trace. Coming
        // to the foreground is the moment to look again.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { manager.airPods.refreshRoute() }
        }
    }

    // MARK: - Dev & Status

    private var statusSection: some View {
        VStack(spacing: Theme.Metric.cardSpacing) {
            SectionHeading(title: "Dev & Status")

            StatusRow(icon: "antenna.radiowaves.left.and.right",
                      title: "Heart Rate Bridge",
                      detail: broadcastDetail,
                      ok: broadcastOK,
                      hint: broadcastHint,
                      action: { showBridgeInfo = true })

            StatusRow(icon: "applewatch",
                      title: "Watch App",
                      detail: watchDetail,
                      ok: watchOK,
                      hint: watchHint)

            // The route picker is the remedy for this row, so it lives *in* it.
            // Bouncing the audio output away from the AirPods and back is what
            // re-establishes the accessory link when they are connected but not
            // reporting — the Health app that used to be here could only show
            // samples that had already arrived, which is no help at all when the
            // complaint is that none are arriving.
            StatusRow(icon: "airpods.pro",
                      title: "AirPods Pro 3",
                      detail: airPodsDetail,
                      ok: airPodsOK,
                      hint: airPodsHint,
                      action: nil,
                      accessory: {
                          // Unconditional. Gating this on the AirPods source
                          // meant the one control that fixes the row vanished
                          // exactly when the row said something was wrong —
                          // and on iPad, where the default source used to be
                          // the watch, it never appeared at all.
                          AudioRoutePicker()
                              .frame(width: 28, height: 28)
                      })

            if settings.source == .fused {
                StatusRow(icon: "arrow.triangle.merge",
                          title: "Sensor Agreement",
                          detail: agreementDetail,
                          ok: agreementOK,
                          hint: agreementHint)
            }
        }
    }

    // MARK: - Sensor agreement

    /// Every live sensor with its own number, so the fused value on the big
    /// readout can be checked rather than taken on trust.
    private var liveReadings: [(HeartRateFusion.Origin, Int, TimeInterval)] {
        HeartRateFusion.Origin.allCases.compactMap { origin in
            guard let reading = manager.fusion.readings[origin] else { return nil }
            let age = now.timeIntervalSince(reading.at)
            guard age <= manager.fusion.maxAge else { return nil }
            return (origin, reading.bpm, age)
        }
    }

    /// The spread between sensors, but only while there are still two of them.
    ///
    /// `fusion.disagreement` is whatever the last resolve computed and it keeps
    /// that value until the next sample arrives. Once one sensor ages out of the
    /// window the other keeps updating, and the stale delta would sit next to a
    /// single reading — "Watch 96 · 0 BPM apart", a comparison with nothing.
    private var liveDelta: Int? {
        guard liveReadings.count > 1 else { return nil }
        return manager.fusion.disagreement
    }

    private var agreementDetail: LocalizedStringKey {
        let live = liveReadings
        guard !live.isEmpty else { return "No sensor is reporting" }
        let readings = live.map { "\($0.0.label) \($0.1)" }.joined(separator: " · ")
        guard let delta = liveDelta else {
            return "\(readings) — sole source"
        }
        return "\(readings) · \(delta) BPM apart"
    }

    /// Neutral rather than red with one sensor live: a watch on its own is not
    /// a disagreement, and a red dot for it would be a fault report about
    /// something working exactly as configured.
    private var agreementOK: Bool? {
        guard let delta = liveDelta else { return nil }
        return delta <= manager.fusion.agreementWindow
    }

    private var agreementHint: LocalizedStringKey? {
        let live = liveReadings
        guard !live.isEmpty else {
            return "Fused mode is selected but neither the watch nor AirPods have reported inside the last \(Int(manager.fusion.maxAge))s."
        }
        guard let delta = liveDelta else {
            let only = live.map(\.0.label).joined(separator: " + ")
            return "Only \(only) is live, so its reading is passed through unchanged — with nothing to cross-check against, averaging or smoothing would only add lag."
        }
        // Pulled out of the interpolation. Inline, the ternary would have put a
        // bare English "nothing" inside an otherwise translated sentence.
        let broadcast = manager.currentBPM.map { "\($0) BPM" }
            ?? String(localized: "nothing", comment: "Stands in for a BPM value when none is being broadcast, inside 'is being sent as ...'")
        if delta <= manager.fusion.agreementWindow {
            return "Within \(manager.fusion.agreementWindow) BPM, so both are trusted and \(broadcast) is being sent as their average — which also halves the sample noise of either one."
        }
        let decided = manager.fusion.decidedBy.map(\.label).joined(separator: " + ")
        let kept = decided.isEmpty
            ? String(localized: "The closer reading", comment: "Subject of a sentence, used when the winning sensor cannot be named")
            : decided
        return "More than \(manager.fusion.agreementWindow) BPM apart, so one of them is wrong. \(kept) is closer to the recent trend and is being broadcast as \(broadcast); the other is ignored. A PPG sensor that has lost skin contact reads high, so the high one is usually the wrong one."
    }

    /// Seconds spent in the current wait, or nil when nothing is pending.
    /// Driven by the view's own `tick` so the number actually counts up.
    private var airPodsWaited: Int? {
        guard let since = manager.airPods.waitingSince else { return nil }
        return max(0, Int(now.timeIntervalSince(since)))
    }

    private var airPodsElapsed: String {
        guard let waited = airPodsWaited, waited >= 2 else { return "" }
        return " (\(waited)s)"
    }

    /// Says what is being waited on, not just that something is. The gap
    /// between putting AirPods in and the first sample can run to a minute, and
    /// an unexplained pause is indistinguishable from a broken app.
    private var airPodsDetail: LocalizedStringKey {
        guard settings.source.usesAirPods else { return "Not selected as a source" }
        switch manager.airPods.progress {
        case .stopped:                  return "Stopped"
        // `why` arrives already translated — the model localizes it at the point
        // it is built, where the failure is actually understood. Passing it
        // through LocalizedStringKey costs one failed catalog lookup and then
        // renders verbatim, which is what we want; re-localizing here would mean
        // a second lookup on a string that is no longer a key.
        case .unavailable(let why):     return .init(stringLiteral: why)
        case .failed(let why):          return .init(stringLiteral: why)
        case .requestingPermission:     return "Requesting Health permission…"
        case .startingSession:          return "Starting workout session…\(airPodsElapsed)"
        case .connecting(let name):     return "\(name) connected — starting session…\(airPodsElapsed)"
        case .waitingForAirPods:        return "Session live — no AirPods connected"
        case .waitingForSample(let name):
            return "\(name) linked — waiting for first sample\(airPodsElapsed)"
        case .live(let bpm, let name):  return "\(bpm) BPM · \(name)"
        }
    }

    /// Green the moment AirPods are actually present, rather than holding out
    /// for the first sample. Detection is the part the user can do something
    /// about; the sensor warming up is not, and showing red through it reads as
    /// a failure that never happened.
    private var airPodsOK: Bool? {
        guard settings.source.usesAirPods else { return nil }
        switch manager.airPods.progress {
        case .live, .waitingForSample, .connecting: return true
        default:                                    return false
        }
    }

    private var airPodsHint: LocalizedStringKey? {
        guard settings.source.usesAirPods else { return nil }
        switch manager.airPods.progress {
        case .waitingForAirPods:
            return "Put both AirPods in and confirm they are connected to this iPhone. Heart rate sensing is AirPods Pro 3 only."
        case .waitingForSample:
            // The plateau is real: the sensor needs skin contact and a few
            // beats before HealthKit will publish anything. Past twenty seconds
            // it is no longer warm-up, and the reliable fix is a route bounce
            // rather than a trip through Settings.
            return (airPodsWaited ?? 0) > 20
                ? "Still nothing after \(airPodsWaited ?? 0)s. Tap the audio route button, pick iPhone, then pick your AirPods again — that re-establishes the sensor link."
                : "Seat both AirPods in your ears — the sensor needs contact and a few beats before iOS publishes a reading."
        case .failed, .unavailable:
            return "Allow Heart Rate under Health › Sharing › Apps, then use the audio route button to reconnect your AirPods."
        default:
            return nil
        }
    }

    private var broadcastDetail: LocalizedStringKey {
        switch broadcaster.state {
        case .idle:            return "Off"
        case .poweredOff:      return "Bluetooth is off"
        case .unauthorized:    return "Bluetooth permission denied"
        case .unsupported:     return "Not supported on this device"
        case .advertising:     return "Advertising as “\(settings.advertisedName)”"
        case .connected(let n):
            // Inflected rather than concatenated — see PairingBanner.message for
            // why appending an "s" is an English-only assumption.
            return broadcaster.hasValue && !isStale
                ? "Streaming to ^[\(n) device](inflect: true)"
                : "Connected to ^[\(n) device](inflect: true) — no data to send"
        case .failed(let why): return .init(stringLiteral: why)
        }
    }

    private var broadcastOK: Bool? {
        switch broadcaster.state {
        case .connected:   return broadcaster.hasValue && !isStale
        case .advertising: return true
        case .idle:        return nil
        default:           return false
        }
    }

    private var broadcastHint: LocalizedStringKey? {
        switch broadcaster.state {
        case .poweredOff:   return "Turn Bluetooth on in Control Center."
        case .unauthorized: return "Allow Bluetooth for this app in Settings › Privacy › Bluetooth."
        case .advertising:  return "On your head unit, add a heart rate sensor and look for “\(settings.advertisedName)”. Leave this screen open until it connects."
        case .connected where !broadcaster.hasValue || isStale:
            return settings.source.usesWatch
                ? "The head unit is connected but this phone has no heart rate to send. Open the watch app and tap Start."
                : "The head unit is connected but no heart rate is being generated."
        default:            return nil
        }
    }

    private var watchDetail: LocalizedStringKey {
        // An iPad cannot pair an Apple Watch at all, so WatchConnectivity is
        // absent rather than idle. Reporting "No paired Apple Watch" there
        // invites the user to go and fix something that is not fixable.
        guard bridge.isSupported else { return "Not available on this device" }
        guard settings.source.usesWatch else { return "Not selected as a source" }
        if !bridge.isPaired { return "No paired Apple Watch" }
        if !bridge.isWatchAppInstalled { return "App not installed on watch" }
        if bridge.isWatchStreaming {
            // "Streaming" on its own is not verifiable. The number the watch is
            // actually contributing, and how old it is, is what distinguishes a
            // live sensor from a session that is nominally running and sending
            // nothing.
            guard let reading = manager.fusion.readings[.watch] else {
                return "Streaming — no sample yet"
            }
            let age = now.timeIntervalSince(reading.at)
            return age < 2
                ? "Streaming · \(reading.bpm) BPM"
                : "Streaming · \(reading.bpm) BPM · \(Int(age))s ago"
        }
        return bridge.isReachable ? "Connected — not started" : "Not reachable"
    }

    private var watchOK: Bool? {
        guard bridge.isSupported, settings.source.usesWatch else { return nil }
        return bridge.isWatchStreaming
    }

    private var watchHint: LocalizedStringKey? {
        guard bridge.isSupported else {
            return "Apple Watch pairing is an iPhone feature. Use AirPods Pro 3 as the heart rate source here, or run the app on your iPhone."
        }
        guard settings.source.usesWatch else { return nil }
        // Built and localized by the bridge, where the watch model names live.
        if let identity = bridge.watchIdentityDetail, bridge.isWatchStreaming {
            return .init(stringLiteral: identity)
        }
        guard !bridge.isWatchStreaming else { return nil }
        if !bridge.isPaired || !bridge.isWatchAppInstalled { return nil }
        return "Open HeartRate Broadcaster on your watch and tap Start. No heart rate is sent until the workout session is running."
    }

    private var sampleAge: TimeInterval? {
        guard let lastUpdate = manager.lastUpdate else { return nil }
        return now.timeIntervalSince(lastUpdate)
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(spacing: Theme.Metric.cardSpacing) {
            SectionHeading(title: "Settings")

            SettingCard(title: "Heart Rate Bridge",
                        subtitle: "Broadcast over Bluetooth",
                        help: "Relays your heart rate to bike computers and fitness apps as a standard Bluetooth heart rate monitor.") {
                Toggle("", isOn: bind(\.bridgeEnabled))
                    .labelsHidden()
                    .tint(Theme.accentActive)
            }

            SettingCard(title: "Push Frequency",
                        subtitle: settings.pushFrequency == .auto
                            ? "Automatically push when the watch updates"
                            : "Resend the latest value every \(String(format: "%.1f", settings.fixedInterval))s") {
                Picker("", selection: bind(\.pushFrequency)) {
                    ForEach(AppSettings.PushFrequency.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }

            SettingCard(title: "Heart Rate Source",
                        subtitle: sourceSubtitle,
                        help: "Watch + AirPods reads both sensors and broadcasts a single reconciled value — when they agree it sends their average, and when they disagree it drops whichever one has strayed from the trend. Your head unit always sees exactly one sensor. Test Signal generates a heart rate on the phone itself; if the head unit shows that but not your watch, the problem is the watch link, not Bluetooth.") {
                Picker("", selection: bind(\.source)) {
                    ForEach(AppSettings.Source.available) {
                        Text($0.shortLabel).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private var sourceSubtitle: LocalizedStringKey {
        switch settings.source {
        case .watch:      return "Live heart rate from Apple Watch"
        case .airPods:    return "Live heart rate from AirPods Pro 3"
        case .fused:      return "Both sensors, reconciled into one broadcast stream"
        case .testSignal: return "Synthetic 50–100 BPM — proves the Bluetooth link without a watch"
        }
    }

    // MARK: - Pro features

    private var proSection: some View {
        VStack(spacing: Theme.Metric.cardSpacing) {
            SectionHeading(title: "Pro Features")

            SettingCard(title: "Screen Always On",
                        subtitle: "Required while a head unit is discovering this phone",
                        help: "iOS hides this app's Bluetooth advertisement when the app is in the background, so non-Apple devices can only find it while the screen is on. Once connected, you can lock the phone.") {
                Toggle("", isOn: bind(\.screenAlwaysOn))
                    .labelsHidden()
                    .tint(Theme.accentActive)
            }

            SettingCard(title: "Auto Launch Watch App",
                        subtitle: "Start the watch app when broadcasting begins") {
                Toggle("", isOn: bind(\.autoStartWatchApp))
                    .labelsHidden()
                    .tint(Theme.accentActive)
            }

            SettingCard(title: "Dynamic Island Heart Rate",
                        subtitle: "Live heart rate in the Dynamic Island and on the Lock Screen",
                        help: "Starts a Live Activity while broadcasting, so you can see the heart rate your head unit is receiving without unlocking the phone.") {
                Toggle("", isOn: bind(\.dynamicIsland))
                    .labelsHidden()
                    .tint(Theme.accentActive)
            }

            SettingCard(title: "Picture in Picture",
                        subtitle: "Floating BPM window over other apps",
                        help: "Keeps a small always-on-top heart rate readout visible while you use another app on this phone. It does not affect what the head unit receives.") {
                Toggle("", isOn: bind(\.pictureInPicture))
                    .labelsHidden()
                    .tint(Theme.accentActive)
            }

            // The system only allows PiP to be detached from a foreground user
            // action, so this cannot be folded into the toggle.
            if settings.pictureInPicture {
                Button {
                    manager.pip.present()
                } label: {
                    Label(manager.pip.isActive ? "Floating Window Open" : "Show Floating Window",
                          systemImage: "pip.enter")
                        .font(Theme.Typeface.rowTitle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accentActive)
                .disabled(!manager.pip.isSupported || manager.pip.isActive)

                if let error = manager.pip.lastError {
                    Text(error)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.accentAlert)
                }
            }

            SettingCard(title: "Lock Touch Screen for Watch",
                        subtitle: "Lock the watch screen against accidental taps",
                        help: "Locks the watch app's controls while it is streaming. Press and hold the screen for one second to unlock — a stray sleeve cannot stop the workout.") {
                Toggle("", isOn: bind(\.watchAntiMistouch))
                    .labelsHidden()
                    .tint(Theme.accentActive)
            }
        }
    }

    // MARK: - Helpers

    /// Every settings write has to re-derive runtime state, so no control binds
    /// to `AppSettings` directly.
    private func bind<T>(_ keyPath: ReferenceWritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { manager.settings[keyPath: keyPath] },
            set: {
                manager.settings[keyPath: keyPath] = $0
                manager.applySettings()
            }
        )
    }

    /// Deliberately delegates to the manager's window rather than keeping its
    /// own constant. The view used to call anything older than 10s stale while
    /// the manager cleared the value on the first missed sample, so the big
    /// number, the banner and the status dots could each believe something
    /// different at the same instant — which is what produced the second-by-
    /// second green/red flicker. One definition, one answer.
    private var isStale: Bool {
        guard let lastUpdate = manager.lastUpdate else { return true }
        return now.timeIntervalSince(lastUpdate) > manager.holdWindow
    }
}
