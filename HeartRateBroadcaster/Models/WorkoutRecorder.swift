import Foundation
import HealthKit
import Observation

/// A session, from Start to a saved record.
///
/// Energy accrues incrementally rather than being computed at Stop from a list
/// of samples: the running figure on screen and the saved figure are then the
/// same arithmetic, and there is no chance of the summary disagreeing with what
/// the user watched for an hour.
/// How much of a finished session this app puts into Apple Health.
///
/// The rest of a session is unaffected either way: the summary, the history and
/// everything broadcast to a cycling app are this app's own and never went
/// through Health to begin with.
struct HealthSavePolicy: Equatable {
    var savesWorkout = true
    var savesEnergy = true
    static let everything = HealthSavePolicy()
}

@Observable
@MainActor
final class WorkoutRecorder {

    enum State: Equatable {
        case idle
        case starting
        case recording
        case stopping

        var isLive: Bool { self == .recording || self == .starting }
    }

    /// A power meter notifies about once a second whether or not you are
    /// pedalling — a coast reports a real zero. Three seconds of nothing is the
    /// link, not the rider.
    static let silenceThreshold: TimeInterval = 3

    private(set) var state: State = .idle
    private(set) var sport: WorkoutSport = .cycling
    private(set) var start: Date?
    private(set) var elapsed: TimeInterval = 0

    private(set) var currentWatts: Int?
    private(set) var currentCadence: Double?
    private(set) var runningKilocalories: Double = 0
    private(set) var energySource: EnergySource = .none
    private(set) var lastRecord: WorkoutRecord?

    /// Body profile is read at Start and held for the session, so editing it
    /// mid-ride cannot retroactively change a figure already on screen.
    var profileProvider: () -> BodyProfile

    /// Read at Start for the same reason as the profile: whatever the switches
    /// said when the ride began is what the ride is filed under, so changing
    /// them mid-effort cannot half-save a session.
    var healthPolicyProvider: () -> HealthSavePolicy = { .everything }

    /// Fired when the session starts or ends. The watch has to be told which
    /// sport this is, and the only moments that changes are these two.
    var onSessionStateChanged: (() -> Void)?

    private let store: WorkoutStore
    private let registry: MeterRegistry
    private let central: PowerMeterCentral
    private let workout: PhoneWorkoutManager

    private var sessionID = UUID()
    private var profile: BodyProfile = .unset
    private var healthPolicy: HealthSavePolicy = .everything

    // Accumulators.
    private var joules: Double = 0
    private var lastPowerAt: Date?
    private var lastIntegratedAt: Date?
    private var heartRateSum: Double = 0
    private var heartRateCount: Int = 0
    private var maximumHeartRate: Int = 0
    private var lastHeartRate: Int?
    private var lastHeartRateAt: Date?
    private var cadenceSum: Double = 0
    private var cadenceCount: Int = 0
    private var maximumWatts: Int = 0
    private var wattsSum: Double = 0
    private var wattsCount: Int = 0

    private var perMeter: [UUID: (name: String, kind: MeterKind, sum: Double, max: Int, joules: Double, count: Int, lastAt: Date?)] = [:]

    private var gaps: [SignalGap] = []
    private var openGapStart: Date?

    init(store: WorkoutStore,
         registry: MeterRegistry,
         central: PowerMeterCentral,
         workout: PhoneWorkoutManager,
         profileProvider: @escaping () -> BodyProfile) {
        self.store = store
        self.registry = registry
        self.central = central
        self.workout = workout
        self.profileProvider = profileProvider
    }

    /// Cycling when a meter that can measure work is paired, because that is
    /// the session the hardware is describing. Otherwise whatever was chosen
    /// last.
    var suggestedSport: WorkoutSport {
        registry.hasPowerCapableMeter ? .cycling : sport
    }

    // MARK: - Lifecycle

    func begin(sport: WorkoutSport) async {
        guard state == .idle else { return }
        state = .starting
        self.sport = sport
        sessionID = UUID()
        profile = profileProvider()
        healthPolicy = healthPolicyProvider()
        resetAccumulators()

        let now = Date()
        start = now
        lastIntegratedAt = now
        store.openJournal(id: sessionID, sport: sport, start: now)

        // The one session. If a bridging session is already running it has the
        // wrong activity type and cannot be reconfigured, so it is stopped and
        // replaced — the heart rate stream resumes within a second.
        if workout.state.isActive {
            _ = await workout.stop()
        }
        // The session runs either way — it is what keeps a heart rate coming off
        // the watch or the AirPods. `keepWorkout` decides only whether it is
        // saved at the end or discarded, which is the whole of the setting.
        await workout.start(sport: sport, keepWorkout: healthPolicy.savesWorkout)
        state = .recording
        onSessionStateChanged?()
    }

    func end() async -> WorkoutRecord? {
        guard state == .recording, let start else { return nil }
        state = .stopping
        let now = Date()
        integrate(to: now)
        closeGap(at: now)

        let recordedSeconds = max(0, now.timeIntervalSince(start) - gaps.reduce(0) { $0 + $1.duration })
        let active = EnergyModel.active(total: runningKilocalories,
                                        profile: profile,
                                        seconds: recordedSeconds,
                                        on: now)

        // The figure is still computed and still shown on the summary; this only
        // decides whether Health is told about it.
        if healthPolicy.savesEnergy {
            await workout.addEnergy(kilocalories: active, from: start, to: now)
        }
        let saved = await workout.stop()

        let record = WorkoutRecord(
            id: sessionID,
            sport: sport,
            start: start,
            end: now,
            gaps: gaps,
            totalKilocalories: runningKilocalories,
            activeKilocalories: active,
            energySource: energySource,
            primaryMeterID: registry.primaryMeterID,
            meterTotals: perMeter.map { id, m in
                MeterTotals(meterID: id, meterName: m.name, kind: m.kind,
                            averageWatts: m.count > 0 ? m.sum / Double(m.count) : 0,
                            maximumWatts: m.max,
                            kilojoules: m.joules / 1000,
                            sampleCount: m.count)
            }.sorted { $0.meterName < $1.meterName },
            averageHeartRate: heartRateCount > 0 ? Int((heartRateSum / Double(heartRateCount)).rounded()) : nil,
            maximumHeartRate: maximumHeartRate > 0 ? maximumHeartRate : nil,
            averageCadence: cadenceCount > 0 ? cadenceSum / Double(cadenceCount) : nil,
            averagePower: wattsCount > 0 ? wattsSum / Double(wattsCount) : nil,
            maximumPower: maximumWatts > 0 ? maximumWatts : nil,
            totalKilojoules: joules / 1000,
            savedToHealth: saved != nil,
            profileWasComplete: profile.isComplete)

        store.save(record)
        store.closeJournal()
        lastRecord = record
        state = .idle
        self.start = nil
        onSessionStateChanged?()
        return record
    }

    // MARK: - Ingestion

    func ingest(heartRate: Int, at date: Date) {
        guard state == .recording else { return }
        lastHeartRate = heartRate
        lastHeartRateAt = date
        heartRateSum += Double(heartRate)
        heartRateCount += 1
        maximumHeartRate = max(maximumHeartRate, heartRate)
    }

    func ingest(_ sample: MeterSample) {
        guard state == .recording else { return }
        var entry = perMeter[sample.meterID] ?? (sample.meterName, sample.kind, 0, 0, 0, 0, nil)
        entry.name = sample.meterName

        if let watts = sample.watts {
            let span = entry.lastAt.map { min(sample.at.timeIntervalSince($0), Self.silenceThreshold) } ?? 0
            entry.joules += EnergyModel.joules(watts: Double(watts), seconds: span)
            entry.sum += Double(watts)
            entry.max = max(entry.max, watts)
            entry.count += 1
        }
        entry.lastAt = sample.at
        perMeter[sample.meterID] = entry

        // Only the primary source's watts reach the integral. Three meters
        // measuring at three points in the drivetrain disagree for physical
        // reasons, and averaging them would describe no point on the bike.
        // A pedal pair is one source and answers with its total, so the two
        // halves of one rider are added rather than raced against each other.
        guard registry.isPrimary(sample.meterID) else { return }
        if let watts = registry.recordedWatts(for: sample) {
            integrate(to: sample.at)
            closeGap(at: sample.at)
            currentWatts = watts
            lastPowerAt = sample.at
            wattsSum += Double(watts)
            wattsCount += 1
            maximumWatts = max(maximumWatts, watts)
            energySource = .power
        }
        if let cadence = sample.cadenceRPM {
            currentCadence = cadence
            cadenceSum += cadence
            cadenceCount += 1
        }
    }

    /// Called once a second by the manager's existing timer. Advances the
    /// integral, and decides whether the primary meter has gone quiet.
    func tick(now: Date) {
        guard state == .recording, let start else { return }
        elapsed = now.timeIntervalSince(start)
        integrate(to: now)

        let silent = lastPowerAt.map { now.timeIntervalSince($0) > Self.silenceThreshold } ?? (registry.primary != nil)
        if silent && registry.primary != nil {
            openGap(at: lastPowerAt.map { $0.addingTimeInterval(Self.silenceThreshold) } ?? start,
                    meterName: registry.primary?.name)
            currentWatts = nil
        }
    }

    // MARK: - Integration

    /// Advances the energy figure to `now`. Power when the primary meter is
    /// speaking, heart rate when it is not, and nothing at all across a gap.
    private func integrate(to now: Date) {
        guard let previous = lastIntegratedAt, now > previous else { return }
        defer { lastIntegratedAt = now }
        guard openGapStart == nil else { return }
        let span = now.timeIntervalSince(previous)

        if let watts = currentWatts, registry.primary != nil {
            let addedJoules = EnergyModel.joules(watts: Double(watts), seconds: span)
            joules += addedJoules
            runningKilocalories += EnergyModel.kilocalories(joules: addedJoules)
            energySource = .power
            return
        }

        // No power. A heart rate no older than the fusion's own hold window is
        // still a measurement; anything older is silence and contributes
        // nothing rather than freezing the last beat into an hour of effort.
        if let bpm = lastHeartRate,
           let at = lastHeartRateAt,
           now.timeIntervalSince(at) < 10,
           let perMinute = EnergyModel.kilocaloriesPerMinute(heartRate: bpm, profile: profile, on: now) {
            runningKilocalories += perMinute * span / 60
            if energySource != .power { energySource = .heartRate }
        }
    }

    private func openGap(at date: Date, meterName: String?) {
        guard openGapStart == nil else { return }
        openGapStart = date
        pendingGapMeter = meterName
    }

    private var pendingGapMeter: String?

    private func closeGap(at date: Date) {
        guard let openGapStart, date > openGapStart else {
            self.openGapStart = nil
            return
        }
        gaps.append(SignalGap(start: openGapStart, end: date, meterName: pendingGapMeter))
        self.openGapStart = nil
        pendingGapMeter = nil
        lastIntegratedAt = date
    }

    private func resetAccumulators() {
        joules = 0
        runningKilocalories = 0
        energySource = .none
        elapsed = 0
        currentWatts = nil
        currentCadence = nil
        lastPowerAt = nil
        lastIntegratedAt = nil
        heartRateSum = 0; heartRateCount = 0; maximumHeartRate = 0
        lastHeartRate = nil; lastHeartRateAt = nil
        cadenceSum = 0; cadenceCount = 0
        wattsSum = 0; wattsCount = 0; maximumWatts = 0
        perMeter = [:]
        gaps = []
        openGapStart = nil
        pendingGapMeter = nil
    }
}
