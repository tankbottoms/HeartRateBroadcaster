import Foundation
import HealthKit
import Observation

/// Owns the `HKWorkoutSession` that makes live heart rate possible.
///
/// **Why a workout session at all.** Both source specs (`Spec.md` §5,
/// `Spec_v2_Updated.md` §5) call for `HKObserverQuery` + `HKSampleQuery`. That
/// does not work: outside a workout the watch samples heart rate roughly every
/// five minutes and HealthKit's sync to the paired phone lags by minutes more.
/// An active `HKWorkoutSession` is the only API that (a) drives the optical
/// sensor at a continuous cadence and (b) grants the watch app runtime with the
/// screen off, via `WKBackgroundModes: workout-processing` in Info.plist.
/// Without both, the broadcast dies the moment the wrist drops.
///
/// Samples arrive every ~1–5s depending on activity — matching the "~4s"
/// automatic push cadence the iOS spec describes.
@Observable
@MainActor
final class WorkoutManager: NSObject {

    // MARK: - Observable state

    enum State: Equatable {
        case idle
        case requestingAuthorization
        case starting
        case running
        case stopping
        case failed(String)

        var isActive: Bool {
            switch self {
            case .starting, .running, .stopping: return true
            case .idle, .requestingAuthorization, .failed: return false
            }
        }
    }

    private(set) var state: State = .idle

    /// Most recent heart rate in beats per minute. `nil` until the first sample.
    private(set) var currentBPM: Int?

    /// When `currentBPM` was last written. Drives staleness in the UI.
    private(set) var lastUpdate: Date?

    /// Total samples ingested this session — a Phase 1 verification aid, and
    /// the cheapest way to tell "sensor is quiet" from "app is wedged".
    private(set) var sampleCount: Int = 0

    private(set) var sessionStart: Date?

    /// Link to the phone. Owned here so every ingested sample is forwarded from
    /// exactly one place.
    let bridge = WatchSessionBridge()

    /// One manager for the whole app.
    ///
    /// The root view could own it — it did — but the phone can now launch this
    /// app straight into a workout, and the launch arrives at the application
    /// delegate before any view exists. Both need to reach the same session, so
    /// it lives here rather than in whichever of them happens to run first.
    static let shared = WorkoutManager()

    override init() {
        super.init()
        // Mirror the phone. Starting a ride on one device and then having to
        // press start again on the other is the bug this closes.
        bridge.onPhoneSessionChanged = { [weak self] active, sport in
            guard let self else { return }
            Task { @MainActor in
                if active {
                    await self.start(sport: sport, announce: false)
                } else {
                    await self.stop(announce: false)
                }
            }
        }
    }

    // MARK: - HealthKit

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private static let heartRateType = HKQuantityType(.heartRate)
    private static let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    // MARK: - Lifecycle

    /// - Parameter sport: what the phone says the session is. `nil` falls back
    ///   to whatever the phone last pushed over the link, and then to indoor
    ///   cycling — the watch never decides this, it only labels its own session
    ///   to match.
    /// - Parameter announce: whether to ask the phone to record this ride too.
    ///   False when the phone is the one that asked for it — otherwise the two
    ///   devices would talk each other in circles.
    func start(sport: WorkoutSport? = nil, announce: Bool = true) async {
        guard !state.isActive else { return }

        let sport = sport ?? bridge.sportOnPhone

        bridge.activate()
        if announce { bridge.requestSessionStart(sport: sport ?? .cycling) }

        guard HKHealthStore.isHealthDataAvailable() else {
            state = .failed(String(localized: "Health data is not available on this device."))
            return
        }

        state = .requestingAuthorization
        do {
            // Sharing `workoutType` is not optional — HKWorkoutSession refuses
            // to start without write access to workouts, even though this app
            // discards every workout it creates.
            try await healthStore.requestAuthorization(
                toShare: [HKQuantityType.workoutType()],
                read: [Self.heartRateType]
            )
        } catch {
            state = .failed(String(localized: "Health access denied: \(error.localizedDescription)",
                                   comment: "Followed by the system error"))
            return
        }

        state = .starting

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = sport?.activityType ?? .cycling
        // Indoor by default: we want the heart rate sensor, not GPS. Outdoor
        // would spin up location services and cost battery for data we never
        // read.
        configuration.locationType = sport?.locationType ?? .indoor

        do {
            let session = try HKWorkoutSession(
                healthStore: healthStore,
                configuration: configuration
            )
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            session.delegate = self
            builder.delegate = self

            self.session = session
            self.builder = builder

            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)

            sessionStart = start
            sampleCount = 0
            state = .running
        } catch {
            teardown()
            state = .failed(String(localized: "Could not start workout: \(error.localizedDescription)",
                                   comment: "Followed by the system error"))
        }
    }

    func stop(announce: Bool = true) async {
        guard state.isActive, let session, let builder else { return }
        if announce { bridge.requestSessionStop() }
        state = .stopping

        session.end()
        try? await builder.endCollection(at: Date())

        // The app is stateless by design (`Spec_v2_Updated.md` §13: no workout
        // history). Discard rather than `finishWorkout()` so we never litter the
        // user's Health app with phantom indoor rides they did not take.
        builder.discardWorkout()

        teardown()
        state = .idle
    }

    private func teardown() {
        bridge.sendStreamingStopped()
        session?.delegate = nil
        builder?.delegate = nil
        session = nil
        builder = nil
        sessionStart = nil
        currentBPM = nil
        lastUpdate = nil
    }

    // MARK: - Ingest

    fileprivate func ingest(bpm: Int, at date: Date) {
        // The optical sensor occasionally emits nonsense on motion artefacts.
        // 20–250 is generous enough to keep real athletes and drop garbage.
        guard (20...250).contains(bpm) else { return }
        currentBPM = bpm
        lastUpdate = date
        sampleCount += 1
        bridge.send(bpm: bpm, at: date)
    }

    fileprivate func handleSessionFailure(_ error: Error) {
        teardown()
        state = .failed(error.localizedDescription)
    }

    fileprivate func handleSessionEndedExternally() {
        guard state.isActive else { return }
        teardown()
        state = .idle
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {

    /// Called on an arbitrary queue — every touch of observable state has to hop
    /// back to the main actor.
    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        let heartRateType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRateType),
              let statistics = workoutBuilder.statistics(for: heartRateType),
              // `mostRecentQuantity` not `averageQuantity` — this is a live
              // readout, and an average over the whole ride would lag badly.
              let quantity = statistics.mostRecentQuantity()
        else { return }

        let bpm = Int(quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())).rounded())
        let timestamp = statistics.endDate

        Task { @MainActor [weak self] in
            self?.ingest(bpm: bpm, at: timestamp)
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Pause/resume/lap events — not used by this app.
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        guard toState == .ended || toState == .stopped else { return }
        Task { @MainActor [weak self] in
            self?.handleSessionEndedExternally()
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.handleSessionFailure(error)
        }
    }
}
