import Foundation
import AVFoundation
import HealthKit
import Observation

/// Collects heart rate **on the iPhone itself**, from AirPods Pro 3.
///
/// This is possible because iOS 26 brought `HKLiveWorkoutBuilder` and
/// `HKLiveWorkoutDataSource` to iPhone — before that the live builder was
/// watchOS-only and an iPhone app could only read HealthKit *after* samples had
/// been written, minutes late. Verified against `iPhoneOS26.5.sdk`:
///
///     HKWorkoutSession        API_AVAILABLE(ios(17.0), watchos(2.0))
///     HKLiveWorkoutBuilder    API_AVAILABLE(ios(26.0), watchos(5.0))
///     HKLiveWorkoutDataSource API_AVAILABLE(ios(26.0), watchos(5.0))
///
/// AirPods Pro 3 report heart rate to whichever device is running the workout
/// session, so starting one here is the whole mechanism — there is no separate
/// AirPods API to talk to.
///
/// The watch runs its own, independent session. Two sessions on two devices is
/// fine; the two streams are reconciled by `HeartRateFusion`, never broadcast
/// separately.
@Observable
@MainActor
final class PhoneWorkoutManager: NSObject {

    enum State: Equatable {
        case idle
        case unavailable(String)
        case requestingAuthorization
        case starting
        case running
        case stopping
        case failed(String)

        /// True from the moment a session is being brought up until it has
        /// finished tearing down. `WorkoutRecorder` uses this to decide whether
        /// it has to stand down an existing bridging session before starting a
        /// recorded one — there is only one `HKWorkoutSession` per device.
        var isActive: Bool {
            switch self {
            case .starting, .running, .stopping, .requestingAuthorization: true
            case .idle, .unavailable, .failed: false
            }
        }
    }

    /// What the user is actually waiting on. `State` describes the *session*;
    /// this describes the *experience*, which is a different thing — a running
    /// session with no AirPods on the route and a running session that simply
    /// has not produced its first sample yet look identical from `State` and
    /// need completely different explanations.
    enum Progress: Equatable {
        case stopped
        case unavailable(String)
        case failed(String)
        case requestingPermission
        /// Session starting, no AirPods seen on the audio route yet.
        case startingSession
        /// AirPods are present; the workout session is still coming up.
        case connecting(String)
        /// Session is live but nothing is wearing/reporting.
        case waitingForAirPods
        /// AirPods present, session live, first sample not in yet.
        case waitingForSample(String)
        case live(Int, String)
    }

    private(set) var state: State = .idle
    private(set) var currentBPM: Int?
    private(set) var lastUpdate: Date?

    /// Name of the connected AirPods, from the audio route. `nil` means none
    /// are visible to this iPhone right now.
    private(set) var airPodsName: String?

    /// When the current "nothing has arrived yet" wait began, so the UI can say
    /// how long it has been rather than just spinning silently.
    private(set) var waitingSince: Date?

    /// Called on the main actor for every sample the session produces.
    var onHeartRate: ((Int, Date) -> Void)?

    /// Whether the session currently running is one the user asked to keep. A
    /// bridging session is discarded on stop; a recorded workout is finished and
    /// written to Health.
    private(set) var isKeepingWorkout = false

    /// When collection began, so energy can be attributed to the right interval.
    private(set) var builderStart: Date?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    /// `nonisolated` so `deinit`, which is not on the main actor, can still
    /// unregister it; written once in `init` and never again, so the unchecked
    /// annotation is not hiding a race. `@ObservationIgnored` is required —
    /// without it the macro turns this into a computed property and the
    /// isolation annotation has nothing to attach to.
    @ObservationIgnored
    private nonisolated(unsafe) var routeObserver: NSObjectProtocol?

    /// Slow re-read of the audio route while a session is up. See
    /// `startRoutePolling()`.
    private var routePoll: Timer?

    private let heartRateType = HKQuantityType(.heartRate)
    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    var isRunning: Bool { state == .running }

    var progress: Progress {
        switch state {
        case .idle, .stopping:         return .stopped
        case .unavailable(let why):    return .unavailable(why)
        case .failed(let why):         return .failed(why)
        case .requestingAuthorization: return .requestingPermission
        case .starting:
            guard let airPodsName else { return .startingSession }
            return .connecting(airPodsName)
        case .running:
            // A sample outranks the audio route. If heart rate is arriving from
            // the live workout builder then AirPods are on an ear and reporting,
            // whatever the audio session believes about the current route — so
            // never claim to be waiting for hardware that is demonstrably
            // working. `routeName` covers the naming, the reading covers the
            // fact.
            if let currentBPM { return .live(currentBPM, airPodsName ?? "AirPods") }
            guard let airPodsName else { return .waitingForAirPods }
            return .waitingForSample(airPodsName)
        }
    }

    // MARK: - AirPods presence

    override init() {
        super.init()
        refreshAirPods()
        // Route changes are the only signal iOS gives that AirPods came or went.
        // Polling would either lag or burn battery; this fires immediately.
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAirPods() }
        }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    /// There is no API that lists connected Bluetooth accessories, so presence
    /// is inferred from the audio session — every port it can see, on every
    /// list it publishes.
    ///
    /// Three things made the previous version miss AirPods that were plainly in
    /// an ear. `availableInputs` returns nil unless the category allows
    /// recording, and this app runs `.playback` for Picture in Picture, so half
    /// the evidence was never there. `currentRoute.inputs` was not consulted at
    /// all. And requiring the port type to be one of the Bluetooth cases threw
    /// away the case where iOS reports AirPods over a different port while
    /// another app owns audio — the name is the more reliable signal, so a name
    /// match now stands on its own and the port type is a second route to the
    /// same answer rather than a gate on it.
    private func refreshAirPods() {
        let audio = AVAudioSession.sharedInstance()
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        // Anything that is not one of these is, by definition, an accessory.
        let builtIn: Set<AVAudioSession.Port> = [.builtInSpeaker, .builtInReceiver, .builtInMic]
        let route = audio.currentRoute

        var candidates: [(AVAudioSession.Port, String)] =
            route.outputs.map { ($0.portType, $0.portName) }
        candidates += route.inputs.map { ($0.portType, $0.portName) }
        candidates += (audio.availableInputs ?? []).map { ($0.portType, $0.portName) }

        func looksLikeAirPods(_ name: String) -> Bool {
            let lower = name.lowercased()
            return lower.contains("airpods") || lower.contains("beats") || lower.contains("powerbeats")
        }

        // Three passes, weakest assumption last. A name match is the strongest
        // evidence and survives iOS reporting the port oddly; a Bluetooth port
        // type is next; and finally any port that is not built-in hardware is
        // still an accessory worth naming, which catches AirPods that a user has
        // renamed *and* that iOS is reporting through an unexpected port.
        let found = candidates.first { looksLikeAirPods($0.1) }?.1
            ?? candidates.first { bluetooth.contains($0.0) }?.1
            ?? candidates.first { !builtIn.contains($0.0) }?.1

        guard found != airPodsName else { return }
        airPodsName = found
        noteWaitBoundary()
    }

    /// Makes `currentRoute` mean something.
    ///
    /// An audio session that has never been activated does not necessarily
    /// report the system's real output route — an app that has not asked to play
    /// anything is told about the speaker, whatever is actually connected. That
    /// is why AirPods sitting in an ear could leave this screen red: not because
    /// detection was wrong, but because the app was reading a route that was
    /// never populated. `.playback` with `.mixWithOthers` claims nothing, ducks
    /// nothing and prompts for no permission; it exists purely so the route
    /// query has an answer. Picture in Picture sets the same category, so the
    /// two cannot fight.
    private func primeAudioRoute() {
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audio.setActive(true)
        } catch {
            // Not fatal — a delivered heart rate sample still proves presence.
            return
        }
        refreshAirPods()
    }

    /// Route-change notifications are not a complete signal. They do not fire
    /// for AirPods that connected before the app launched, nor while the app is
    /// suspended, and iOS can revise a route quietly after another app releases
    /// audio. So while there is a session running and nothing detected, ask
    /// again on a slow clock — this is three property reads every few seconds,
    /// which is far cheaper than a user staring at a red dot.
    private func startRoutePolling() {
        guard routePoll == nil else { return }
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.airPodsName == nil || self.currentBPM == nil else { return }
                self.refreshAirPods()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        routePoll = timer
    }

    private func stopRoutePolling() {
        routePoll?.invalidate()
        routePoll = nil
    }

    /// Re-reads the audio route on demand.
    ///
    /// Route change notifications only fire on a *change*. AirPods that were
    /// already connected when the app launched, or that reconnected while the
    /// app was suspended and therefore not receiving notifications, produce no
    /// event at all — so the UI needs a way to ask.
    func refreshRoute() {
        refreshAirPods()
        // Only worth activating a session over if the answer still looks wrong:
        // a workout is up and yet nothing is detected.
        if airPodsName == nil, state == .running || state == .starting {
            primeAudioRoute()
        }
    }

    /// Restarts the "how long have I been waiting" clock whenever the thing
    /// being waited on changes, so the elapsed time on screen always refers to
    /// the current wait rather than the whole session.
    private func noteWaitBoundary() {
        if currentBPM == nil, state == .running || state == .starting {
            waitingSince = Date()
        } else {
            waitingSince = nil
        }
    }

    // MARK: - Control

    /// - Parameters:
    ///   - sport: what the workout is. `nil` keeps the historical behaviour —
    ///     indoor cycling, chosen because it is the closest match to a turbo
    ///     session and keeps the session from asking for location.
    ///   - keepWorkout: whether `stop()` should finish and save the workout
    ///     instead of discarding it. HealthKit fixes the activity type when the
    ///     session is created, which is why the sport arrives here and not later.
    func start(sport: WorkoutSport? = nil, keepWorkout: Bool = false) async {
        guard state != .running, state != .starting else { return }

        guard HKHealthStore.isHealthDataAvailable() else {
            state = .unavailable(String(localized: "Health data is not available on this iPhone."))
            return
        }

        primeAudioRoute()
        startRoutePolling()
        state = .requestingAuthorization
        waitingSince = Date()
        let share: Set<HKSampleType> = [HKQuantityType.workoutType()]
        let read: Set<HKObjectType> = [heartRateType]
        do {
            try await store.requestAuthorization(toShare: share, read: read)
        } catch {
            state = .failed(String(localized: "Health permission was refused: \(error.localizedDescription)",
                                   comment: "Followed by the system error"))
            return
        }

        state = .starting
        isKeepingWorkout = keepWorkout
        let config = HKWorkoutConfiguration()
        config.activityType = sport?.activityType ?? .cycling
        config.locationType = sport?.locationType ?? .indoor

        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            builder.delegate = self
            session.delegate = self

            self.session = session
            self.builder = builder

            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            builderStart = start
            state = .running
        } catch {
            state = .failed(String(localized: "Could not start the AirPods session: \(error.localizedDescription)",
                                   comment: "Followed by the system error"))
            teardown()
        }
    }

    /// - Returns: the saved workout when this session was started with
    ///   `keepWorkout: true`, otherwise `nil`.
    @discardableResult
    func stop() async -> HKWorkout? {
        guard let session, let builder else {
            state = .idle
            return nil
        }
        state = .stopping
        session.end()
        var saved: HKWorkout?
        if isKeepingWorkout {
            try? await builder.endCollection(at: Date())
            saved = try? await builder.finishWorkout()
        } else {
            try? await builder.endCollection(at: Date())
            // A bridging session is not a workout the user asked for — this app
            // is a sensor bridge, not a training log. Discarding avoids
            // littering Health with phantom rides.
            builder.discardWorkout()
        }
        teardown()
        isKeepingWorkout = false
        builderStart = nil
        state = .idle
        currentBPM = nil
        lastUpdate = nil
        waitingSince = nil
        return saved
    }

    /// Writes an energy total onto the running workout, so the calories the app
    /// computed from power are the ones Health shows for the ride.
    ///
    /// `activeEnergyBurned` means *above resting*, which is why the caller
    /// subtracts BMR before handing the figure over — otherwise the ride would
    /// be counted twice against the move ring.
    func addEnergy(kilocalories: Double, from: Date, to: Date) async {
        guard let builder, kilocalories > 0, to > from else { return }
        let type = HKQuantityType(.activeEnergyBurned)
        let quantity = HKQuantity(unit: .kilocalorie(), doubleValue: kilocalories)
        let sample = HKCumulativeQuantitySample(type: type,
                                                quantity: quantity,
                                                start: from,
                                                end: to)
        try? await builder.addSamples([sample])
    }

    private func teardown() {
        stopRoutePolling()
        session?.delegate = nil
        builder?.delegate = nil
        session = nil
        builder = nil
    }

    fileprivate func ingest(_ statistics: HKStatistics?) {
        guard let statistics, statistics.quantityType == heartRateType else { return }
        // `mostRecentQuantity` — the average over the whole session is useless
        // for a live broadcast.
        guard let quantity = statistics.mostRecentQuantity() else { return }
        let bpm = Int(quantity.doubleValue(for: bpmUnit).rounded())
        guard (20...250).contains(bpm) else { return }
        let at = statistics.mostRecentQuantityDateInterval()?.end ?? Date()
        // A reading proves the hardware is there. If the audio route never told
        // us its name, this is the moment to go and look again.
        if airPodsName == nil { refreshAirPods() }
        currentBPM = bpm
        lastUpdate = at
        waitingSince = nil
        onHeartRate?(bpm, at)
    }

    fileprivate func handle(sessionState: HKWorkoutSessionState) {
        switch sessionState {
        case .running:  state = .running
        case .ended, .stopped: if state != .stopping { state = .idle }
        default: break
        }
        noteWaitBoundary()
    }

    fileprivate func handle(error: Error) {
        state = .failed(error.localizedDescription)
        teardown()
    }
}

// MARK: - HKWorkoutSessionDelegate

extension PhoneWorkoutManager: HKWorkoutSessionDelegate {

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        Task { @MainActor in handle(sessionState: toState) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didFailWithError error: Error) {
        Task { @MainActor in handle(error: error) }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension PhoneWorkoutManager: HKLiveWorkoutBuilderDelegate {

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard collectedTypes.contains(HKQuantityType(.heartRate)) else { return }
        let statistics = workoutBuilder.statistics(for: HKQuantityType(.heartRate))
        Task { @MainActor in ingest(statistics) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
