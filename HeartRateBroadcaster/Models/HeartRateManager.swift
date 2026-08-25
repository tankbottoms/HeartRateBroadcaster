import Foundation
import UIKit
import HealthKit
import Observation

/// Single source of truth on the phone. Owns the settings, the watch link and
/// the BLE broadcaster, and is the only thing that decides what gets sent.
@Observable
@MainActor
final class HeartRateManager {

    let settings = AppSettings()
    let bridge = PhoneSessionBridge()
    let broadcaster = BLEBroadcaster()
    let airPods = PhoneWorkoutManager()
    let liveActivity = LiveActivityController()
    let pip = PiPController()

    /// The virtual shifter. Constructed always, started only when the rider
    /// turns it on — an idle `BikeControlService` holds no listener and touches
    /// nothing.
    let bikeControl: BikeControlService

    /// Power, cadence and trainer sensors, and the recorded workout built from
    /// them. Constructed here rather than in a view so the connections survive
    /// navigation — a meter should not drop because a screen went away.
    let meters = MeterRegistry()
    let workoutStore = WorkoutStore()
    let central: PowerMeterCentral
    let recorder: WorkoutRecorder

    private(set) var currentBPM: Int?
    private(set) var lastUpdate: Date?

    init() {
        let central = PowerMeterCentral(registry: meters)
        self.central = central
        bikeControl = BikeControlService(gearCount: settings.bikeControlGearCount,
                                         gear: settings.bikeControlGear)
        // `settings` is a stored property of this class, so the provider has to
        // be installed after `self` is whole. It is read once per session, at
        // Start, rather than captured now.
        recorder = WorkoutRecorder(store: workoutStore,
                                   registry: meters,
                                   central: central,
                                   workout: airPods,
                                   profileProvider: { .unset })
        recorder.profileProvider = { [settings] in settings.bodyProfile }
        recorder.healthPolicyProvider = { [settings] in
            HealthSavePolicy(savesWorkout: settings.savesWorkoutsToHealth,
                             savesEnergy: settings.savesEnergyToHealth)
        }
        // Start and Stop are the only two moments the watch's copy of the sport
        // can go stale, and `applySettings` is the one place that pushes it.
        recorder.onSessionStateChanged = { [weak self] in self?.applySettings() }
    }

    /// Whether the recorder was live the last time settings were applied, so
    /// the watch is only launched on the transition into a ride.
    private var wasSessionLive = false

    /// Brings the watch app to the front with a workout already configured.
    ///
    /// This is the only supported way to start a watch app from the phone —
    /// `updateApplicationContext` reaches a watch app that is asleep but cannot
    /// wake one that is not running at all. The watch receives it in
    /// `handle(_ workoutConfiguration:)`.
    ///
    /// Failure is silent on purpose: the watch may not be on a wrist, may not
    /// have the app installed, or may simply refuse. None of that should stop
    /// the ride the rider just started on the phone, and the status row already
    /// says whether the watch is streaming.
    private func launchWatchApp(sport: WorkoutSport) {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = sport.activityType
        configuration.locationType = sport.locationType
        HKHealthStore().startWatchApp(with: configuration) { _, _ in }
    }

    /// Reduces however many sensors are live to the single value that goes out
    /// over BLE. A head unit must only ever see one sensor.
    private(set) var fusion = HeartRateFusion()

    /// Human-readable description of which sensor the broadcast value came
    /// from, e.g. "Watch + AirPods" or "AirPods (Watch rejected)".
    var sourceLabel: String {
        switch settings.source {
        // Same wording as the picker segment it corresponds to — see
        // `AppSettings.Source.shortLabel`.
        case .testSignal: return String(localized: "Test", comment: "Picker segment: synthetic heart rate generated on the phone")
        case .watch:      return "Watch"
        case .airPods:    return "AirPods"
        case .fused:
            let names = HeartRateFusion.Origin.allCases
                .filter { fusion.decidedBy.contains($0) }
                .map(\.label)
            if names.isEmpty { return String(localized: "Watch + AirPods") }
            if fusion.didRejectOutlier {
                let kept = names.joined(separator: " + ")
                return String(localized: "\(kept) (outlier dropped)",
                              comment: "Sensor names, then a note that a disagreeing sensor was discarded")
            }
            return names.joined(separator: " + ")
        }
    }

    /// What each sensor said and what was done about it, in one line.
    ///
    /// The single fused number is the honest thing to broadcast but the
    /// dishonest thing to *show*: when the watch reads 142 and the AirPods read
    /// 118, one of them is wrong and the rider is entitled to know that before a
    /// ride file records the wrong one. nil whenever there is nothing to
    /// reconcile — one live sensor needs no explanation.
    var reconciliation: String? {
        let now = Date()
        let live = HeartRateFusion.Origin.allCases.compactMap { origin -> (HeartRateFusion.Origin, Int)? in
            guard let reading = fusion.readings[origin],
                  now.timeIntervalSince(reading.at) <= fusion.maxAge else { return nil }
            return (origin, reading.bpm)
        }
        guard live.count > 1 else { return nil }

        let readings = live.map { "\($0.0.label) \($0.1)" }.joined(separator: " · ")
        guard let delta = fusion.disagreement else { return readings }

        let verdict: String
        if fusion.didRejectOutlier {
            let kept = fusion.decidedBy.map(\.label).joined(separator: " + ")
            verdict = String(localized: "\(delta) apart — using \(kept)",
                             comment: "BPM difference between two sensors, then the name of the one being trusted")
        } else {
            verdict = String(localized: "\(delta) apart — averaged",
                             comment: "BPM difference between two sensors that were averaged together")
        }
        return "\(readings) · \(verdict)"
    }

    /// Consecutive publishes that produced a real value, capped. This is the
    /// app's confidence that the link is behaving, and it is what buys a gap the
    /// benefit of the doubt — see `holdWindow`.
    private(set) var confidence = 0
    private static let confidenceCap = 20

    /// The cadence the broadcast actually runs at. In auto mode samples arrive
    /// on the sensor's own schedule, which for both the watch and AirPods is
    /// about 1 Hz; in fixed mode the user has told us the interval outright.
    var pushCadence: TimeInterval {
        settings.pushFrequency == .fixed ? max(0.25, settings.fixedInterval) : 1.0
    }

    /// How long the last good reading is held — on screen, in the Dynamic
    /// Island, in the PiP window, and on the wire — after its source goes quiet,
    /// before anything is allowed to call it a failure.
    ///
    /// A single skipped 1 Hz sample is normal; the previous fixed 10 s window
    /// still let `currentBPM` go nil the instant `fuse` returned nothing, so the
    /// UI flipped green → red → green between beats. The window is sized off the
    /// push cadence so Fixed at 5 s does not get judged on a 1 s clock, and it
    /// grows with `confidence` so a stream that has been solid for a minute is
    /// not condemned by one hiccup.
    /// The 15 s ceiling is a deliberate limit, not a round number. This value is
    /// held *on the wire* as well as on screen, and a head unit recording a
    /// frozen heart rate is worse than one recording a gap — past roughly this
    /// long the reading is no longer plausibly the rider's, so the broadcast has
    /// to stop claiming it.
    var holdWindow: TimeInterval {
        let base = max(5, pushCadence * 4)
        let earned = min(Double(confidence), 10) * pushCadence
        return min(15, base + earned)
    }

    private var testTimer: Timer?
    private var fixedPushTimer: Timer?
    private var watchdog: Timer?
    private var workoutTick: Timer?
    private var testPhase: Double = 0

    /// Every timer here must run in `.common` mode. A `Timer.scheduledTimer`
    /// lands in `.default`, which stops firing while a scroll view is tracking —
    /// so scrolling the app would silently stall the broadcast.
    private static func repeatingTimer(_ interval: TimeInterval,
                                       _ body: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { body() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    func onAppear() {
        bridge.onHeartRate = { [weak self] bpm, date in
            guard let self, self.settings.source.usesWatch else { return }
            self.ingest(bpm: bpm, from: .watch, at: date)
        }
        airPods.onHeartRate = { [weak self] bpm, date in
            guard let self, self.settings.source.usesAirPods else { return }
            self.ingest(bpm: bpm, from: .airPods, at: date)
        }
        central.onSample = { [weak self] sample in
            // The registry sees every meter's watts, including the ones that are
            // not primary — that comparison is the whole basis for deciding which
            // meter to believe. It goes first so the recorder attributes this
            // sample under the choice this sample may itself have changed.
            self?.meters.observe(sample)
            self?.recorder.ingest(sample)
        }
        // After the wiring above, so the fabricated samples travel the same path
        // a real notification does rather than a shortcut of their own.
#if DEBUG
        DemoMeters.installIfRequested(registry: meters, central: central)
#endif
        bridge.onSessionCommand = { [weak self] start, sport in
            guard let self else { return }
            Task { @MainActor in
                if start {
                    guard !self.recorder.state.isLive else { return }
                    await self.recorder.begin(sport: sport ?? self.recorder.suggestedSport)
                } else {
                    guard self.recorder.state.isLive else { return }
                    _ = await self.recorder.end()
                }
            }
        }
        bridge.activate()
        broadcaster.advertisedName = settings.advertisedName
        applySettings()
        startWatchdog()
        startWorkoutTick()
    }

    /// The recorder integrates power over time, so it needs a clock of its own
    /// even when no meter is talking — that silence is exactly what it has to
    /// notice. One second is fine: it is the resolution the readout shows.
    private func startWorkoutTick() {
        guard workoutTick == nil else { return }
        workoutTick = Self.repeatingTimer(1.0) { [weak self] in
            self?.recorder.tick(now: Date())
        }
    }

    /// Stops the broadcast claiming a heart rate once the source has gone quiet,
    /// rather than notifying a frozen number forever.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Self.repeatingTimer(2.0) { [weak self] in
            guard let self else { return }
            // Re-arbitrate on a clock as well as on arrival: a sensor that goes
            // silent never sends anything to trigger a re-fuse, so without this
            // a dead AirPods reading would keep dragging the average forever.
            if self.settings.source != .testSignal {
                self.publishFused(at: Date(), touchTimestamp: false)
            }
            if self.isStale { self.broadcaster.clearValue() }
        }
    }

    // MARK: - Settings side effects

    /// Re-derives every piece of runtime state from `settings`. Called on
    /// appear and after any settings change, so there is exactly one place
    /// where a toggle turns into behaviour.
    func applySettings() {
        broadcaster.advertisedName = settings.advertisedName

        if settings.bridgeEnabled {
            broadcaster.start()
        } else {
            broadcaster.stop()
        }

        settings.source == .testSignal ? startTestSignal() : stopTestSignal()

        // AirPods heart rate only arrives while a workout session is running on
        // the phone, so the source setting literally starts and stops it.
        if settings.source.usesAirPods && settings.bridgeEnabled {
            if !airPods.isRunning { Task { await airPods.start() } }
        } else {
            if airPods.isRunning { Task { await airPods.stop() } }
            fusion.clear(.airPods)
        }
        if !settings.source.usesWatch { fusion.clear(.watch) }

        if settings.pushFrequency == .fixed && settings.bridgeEnabled {
            startFixedPush()
        } else {
            stopFixedPush()
        }

        // Launching the watch app is a one-off, not a state to be re-asserted:
        // fire it on the edge into a live session and nowhere else.
        let isLive = recorder.state.isLive
        if isLive && !wasSessionLive && settings.autoStartWatchApp {
            launchWatchApp(sport: recorder.sport)
        }
        wasSessionLive = isLive

        bridge.push(settings: [
            WCKey.bridgeEnabled: settings.bridgeEnabled,
            WCKey.autoStart: settings.autoStartWatchApp,
            WCKey.antiMistouch: settings.watchAntiMistouch,
            // The phone owns the session; the watch only labels its own to
            // match, so the sport rides along with the settings rather than
            // needing a channel of its own.
            WCKey.sport: recorder.sport.rawValue,
            WCKey.sessionActive: recorder.state.isLive
        ])

        bikeControl.gearCount = settings.bikeControlGearCount
        bikeControl.startingGear = AppSettings.defaultGear
        if settings.bikeControlEnabled {
            // Same name as the heart rate advertisement, so the shifter and the
            // sensor read as one device in the game's two separate lists rather
            // than as two unrelated gadgets that happen to be nearby.
            bikeControl.start(name: settings.advertisedName)
        } else {
            bikeControl.stop()
        }

        syncLiveActivity()

        if settings.pictureInPicture && settings.bridgeEnabled {
            pip.start()
        } else {
            pip.stop()
        }

        // Discovery only works while the app is foreground (see BLEBroadcaster).
        // Keeping the screen awake during pairing is the difference between the
        // head unit finding us and the user assuming the app is broken.
        UIApplication.shared.isIdleTimerDisabled = settings.screenAlwaysOn && settings.bridgeEnabled
    }

    // MARK: - Ingest

    /// A sample from one sensor. Never broadcast directly — it goes through
    /// `fusion` first, which is what guarantees a single outgoing stream even
    /// when both the watch and AirPods are reporting.
    func ingest(bpm: Int, from origin: HeartRateFusion.Origin, at date: Date) {
        guard (20...250).contains(bpm) else { return }
        fusion.submit(bpm, from: origin, at: date)
        publishFused(at: date)
    }

    /// Test signal path — synthetic, bypasses arbitration entirely.
    func ingestTestSignal(bpm: Int, at date: Date) {
        guard (20...250).contains(bpm) else { return }
        currentBPM = bpm
        lastUpdate = date
        confidence = min(confidence + 1, Self.confidenceCap)
        // The recorder is fed here as well as in `publishFused`. Bypassing
        // arbitration is the point of this path, but bypassing the *workout* is
        // not: without this a session recorded against the test signal counts
        // zero calories, because the energy integral only ever sees the beats
        // the recorder was handed.
        recorder.ingest(heartRate: bpm, at: date)
        if settings.pushFrequency == .auto { broadcaster.update(bpm: bpm) }
        mirrorToAccessories()
    }

    // MARK: - Secondary displays

    /// What the Dynamic Island and the PiP window show.
    ///
    /// Deliberately the *fused, post-arbitration* number and the live subscriber
    /// count, not the raw watch reading — these two facts together are the only
    /// way to tell at a glance whether the ride is actually being recorded.
    private var activityState: HeartRateActivityAttributes.ContentState {
        HeartRateActivityAttributes.ContentState(
            bpm: currentBPM,
            isLive: currentBPM != nil && !isStale,
            source: sourceLabel,
            subscriberCount: broadcaster.subscriberCount
        )
    }

    /// The Live Activity runs for the whole broadcast, which is what the
    /// Dynamic Island is for: a glanceable readout while the app is in the
    /// background and the phone is on the bars. Gating it on a live subscriber
    /// *and* a non-nil BPM meant it never appeared during the part of a session
    /// where it is most useful — before the head unit has found you — and tore
    /// itself down and back up on every gap in the stream.
    private func syncLiveActivity() {
        let wanted = settings.dynamicIsland && settings.bridgeEnabled

        if wanted {
            liveActivity.start(broadcastName: settings.advertisedName, state: activityState)
        } else if liveActivity.isActive {
            liveActivity.stop()
        }
    }

    /// What the secondary displays call the far end.
    ///
    /// Bluetooth gives a peripheral no way to learn a central's name — the
    /// connection carries an identifier and an MTU and nothing else — so
    /// "connected to 1 device" was all the count could ever say. The advertised
    /// name is the one label in the system that is both meaningful and true: it
    /// is what the head unit picked us out by.
    private var accessorySubtitle: String {
        broadcaster.subscriberCount == 0 ? String(localized: "not connected") : settings.advertisedName
    }

    private func mirrorToAccessories() {
        syncLiveActivity()
        let state = activityState
        liveActivity.update(state)
        pip.update(bpm: state.bpm, isLive: state.isLive, subtitle: accessorySubtitle)
    }

    /// `touchTimestamp: false` for the periodic re-arbitration — re-running the
    /// arbiter is not a new sample, and pretending otherwise would make the
    /// staleness check permanently satisfied.
    private func publishFused(at date: Date, touchTimestamp: Bool = true) {
        guard let fused = fusion.fuse(now: date) else {
            // A gap is not a failure. Hold the last reading — on screen, in the
            // Island and on the wire — for `holdWindow`, so a missed sample at
            // 1 Hz does not blank the display to "--" and flip every status
            // light red between beats. Only past the window is the value
            // genuinely gone, and confidence resets so the *next* stall is
            // judged on a short leash again.
            if let last = lastUpdate, date.timeIntervalSince(last) < holdWindow {
                mirrorToAccessories()
                return
            }
            confidence = 0
            currentBPM = nil
            broadcaster.clearValue()
            mirrorToAccessories()
            return
        }
        currentBPM = fused
        // The recorder wants the fused value, not either raw sensor — the same
        // number that goes out over the wire is the one the workout records.
        recorder.ingest(heartRate: fused, at: date)
        if touchTimestamp {
            lastUpdate = date
            confidence = min(confidence + 1, Self.confidenceCap)
        }
        mirrorToAccessories()
        // Auto mode forwards every sample as it arrives; fixed mode lets the
        // timer resend the most recent value on its own cadence.
        if settings.pushFrequency == .auto {
            broadcaster.update(bpm: fused)
        }
    }

    /// True once the last reading is older than the grace the link has earned.
    /// Everything user-visible — the big number, the pairing banner, the status
    /// dots, the Island, the PiP — keys off this one value, so they change
    /// together instead of arguing with each other.
    var isStale: Bool {
        guard let lastUpdate else { return true }
        return Date().timeIntervalSince(lastUpdate) > holdWindow
    }

    // MARK: - Timers

    private func startFixedPush() {
        stopFixedPush()
        let interval = max(0.25, settings.fixedInterval)
        fixedPushTimer = Self.repeatingTimer(interval) { [weak self] in
            guard let self, let bpm = self.currentBPM, !self.isStale else { return }
            self.broadcaster.update(bpm: bpm)
        }
    }

    private func stopFixedPush() {
        fixedPushTimer?.invalidate()
        fixedPushTimer = nil
    }

    /// Synthetic heart rate, so the BLE half can be proven against a real head
    /// unit without a watch on a wrist. This is a debugging tool, not a feature —
    /// it isolates "the head unit cannot see us" from "the watch is not sending".
    private func startTestSignal() {
        guard testTimer == nil else { return }
        let (centre, swing) = Self.testSignalShape
        testTimer = Self.repeatingTimer(1.0) { [weak self] in
            guard let self else { return }
            self.testPhase += 0.08
            let bpm = Int(centre + swing * sin(self.testPhase))
            self.ingestTestSignal(bpm: bpm, at: Date())
        }
    }

    /// 50–100 BPM, unless the screenshot runner asks for something else.
    ///
    /// A resting-range signal produces no active energy at all once basal
    /// expenditure is subtracted, so the marketing capture seeds these two keys
    /// with `simctl spawn defaults write` beforehand. There is no user-facing
    /// control and the app never writes them, so on a real install they are
    /// absent and the debugging range is what runs.
    private static var testSignalShape: (centre: Double, swing: Double) {
        let d = UserDefaults.standard
        // `object(forKey:) as? Double` looks right and never fires: a value that
        // arrives as `-testSignalCentre 148` on the command line is a string in
        // the argument domain, not a number. `double(forKey:)` does the coercion,
        // and `object(forKey:)` is asked only whether the key exists at all.
        let centre = d.object(forKey: "testSignalCentre") != nil ? d.double(forKey: "testSignalCentre") : 75
        let swing = d.object(forKey: "testSignalSwing") != nil ? d.double(forKey: "testSignalSwing") : 25
        return (min(max(centre, 30), 220), min(max(swing, 0), 40))
    }

    private func stopTestSignal() {
        guard testTimer != nil else { return }
        testTimer?.invalidate()
        testTimer = nil
        currentBPM = nil
        lastUpdate = nil
        confidence = 0
        fusion.reset()
        broadcaster.clearValue()
        mirrorToAccessories()
    }
}
