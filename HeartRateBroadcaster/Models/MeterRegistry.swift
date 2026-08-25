import Foundation
import Observation

/// Which meters belong to this rider, and which one's watts are the ones that
/// count.
///
/// Persisted as JSON in `UserDefaults` rather than as a spread of scalar keys,
/// because the list is variable-length. `AppSettings` is the pattern for the
/// scalar settings; this is a list, so it gets its own store.
///
/// The unit of choice is a ``PowerSource`` rather than a meter, because a pair
/// of pedals is two meters and one answer. Everything below that reads `source`
/// where it used to read `meter` is deliberate.
@Observable
@MainActor
final class MeterRegistry {

    private static let pairedKey = "meters.paired"
    private static let primaryKey = "meters.primary"
    private static let automaticKey = "meters.primaryAutomatic"

    private(set) var paired: [PairedMeter] = [] {
        didSet {
            sources = PowerSource.group(paired)
            persistPaired()
        }
    }

    /// The paired meters read as sources, with left and right pedals joined.
    private(set) var sources: [PowerSource] = []

    /// The chosen source. Named for the meter because that is what it is in the
    /// ordinary case, and because a saved workout records it under that name.
    private(set) var primaryMeterID: UUID? {
        didSet {
            if let primaryMeterID {
                UserDefaults.standard.set(primaryMeterID.uuidString, forKey: Self.primaryKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.primaryKey)
            }
        }
    }

    var primarySource: PowerSource? {
        guard let primaryMeterID else { return nil }
        return sources.first { $0.id == primaryMeterID }
    }

    /// Kept for the callers that only want something to name in a message.
    var primary: PowerSource? { primarySource }

    /// Whether the app chooses the primary source itself, by following whichever
    /// is reading highest. On by default: with pedals, a crank and a trainer all
    /// connected, the right answer is the one measured closest to the rider, and
    /// that is a thing the app can see and the rider would have to guess.
    var automaticPrimary: Bool {
        didSet {
            UserDefaults.standard.set(automaticPrimary, forKey: Self.automaticKey)
            if automaticPrimary { reconsiderPrimary(now: Date()) }
        }
    }

    /// The watts each source is reporting, smoothed, and the rule for switching.
    private var picker = PrimaryMeterPicker()

    /// The last raw reading from each individual meter. The picker holds smoothed
    /// numbers per *source*; adding a pedal pair up needs the two sides' own
    /// latest figures, which is what this is for.
    private var lastRaw: [UUID: (watts: Int, at: Date)] = [:]

    /// How long a pedal may be silent before its side is treated as dropped.
    /// Shorter than the picker's staleness, because a pair that has lost a side
    /// should fall back within a stroke or two rather than keep adding in a
    /// number from ten seconds ago.
    static let sideDropsAfter: TimeInterval = 4

    /// Which sources could carry the energy figure. A cadence-only sensor cannot,
    /// however busily it reports.
    private var powerCapableIDs: Set<UUID> {
        Set(sources.filter(\.measuresPower).map(\.id))
    }

    /// Smoothed watts for one source, for the settings list to show why the app
    /// picked what it picked.
    func smoothedWatts(for id: UUID) -> Int? {
        picker.readings[id].map { Int($0.smoothedWatts.rounded()) }
    }

    /// The last raw figure from a single meter, so a pair's row can show what
    /// each side is contributing to the total it prints.
    func rawWatts(for meterID: UUID) -> Int? {
        lastRaw[meterID]?.watts
    }

    /// A cadence-only sensor cannot drive the energy figure, so the recorder
    /// needs to know whether any paired meter can measure work at all.
    var hasPowerCapableMeter: Bool {
        sources.contains(where: \.measuresPower)
    }

    init() {
        automaticPrimary = UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
        if let data = UserDefaults.standard.data(forKey: Self.pairedKey),
           let decoded = try? JSONDecoder().decode([PairedMeter].self, from: data) {
            paired = decoded
        }
        // A property observer does not fire for a write from inside `init`, so
        // the grouping that `paired` normally maintains has to be done by hand
        // exactly once, here.
        sources = PowerSource.group(paired)
        if let raw = UserDefaults.standard.string(forKey: Self.primaryKey) {
            primaryMeterID = UUID(uuidString: raw)
        }
    }

    /// Idempotent by identifier: reconnecting a known meter refreshes its name
    /// rather than adding a duplicate row.
    func remember(_ meter: PairedMeter) {
        if let index = paired.firstIndex(where: { $0.id == meter.id }) {
            paired[index] = meter
        } else {
            paired.append(meter)
        }
        // The first source that can measure work becomes primary, so the common
        // case — one power meter — never requires a visit to settings.
        if primaryMeterID == nil || primarySource == nil {
            primaryMeterID = sources.first(where: \.measuresPower)?.id
        }
    }

    func forget(_ id: UUID) {
        paired.removeAll { $0.id == id }
        picker.forget(id)
        lastRaw[id] = nil
        // Removing one pedal dissolves the pair, and the pair's identifier was
        // the left pedal's — so the primary may now name a source that no longer
        // exists whether or not the removed meter was the one showing.
        if primarySource == nil {
            primaryMeterID = sources.first(where: \.measuresPower)?.id
        }
    }

    /// Picking one by hand turns the automatic choice off. Anything else would
    /// undo the rider's decision a few seconds after they made it.
    func setPrimary(_ id: UUID?) {
        automaticPrimary = false
        primaryMeterID = id
    }

    // MARK: - Following the highest reading

    /// Every power sample passes through here, whether or not it comes from the
    /// primary source — the losers' numbers are exactly what the decision needs.
    func observe(_ sample: MeterSample) {
        guard let reported = sample.watts else { return }
        lastRaw[sample.meterID] = (reported, sample.at)
        guard let source = source(containing: sample.meterID),
              let combined = watts(of: source, at: sample.at) else { return }
        picker.observe(meterID: source.id, watts: combined, at: sample.at)
        guard automaticPrimary else { return }
        reconsiderPrimary(now: sample.at)
    }

    /// The watts to record for an incoming sample, or nil when it did not come
    /// from the source the app is believing.
    ///
    /// A pedal pair answers with the pair's total rather than the one pedal's
    /// share, which is the whole reason a pair is a source.
    func recordedWatts(for sample: MeterSample) -> Int? {
        guard let reported = sample.watts,
              let primary = primarySource,
              primary.memberIDs.contains(sample.meterID) else { return nil }
        guard primary.isPair else { return reported }
        return watts(of: primary, at: sample.at)
    }

    /// Whether a sample came from the source being believed, for the readings
    /// that are not watts — cadence arrives from either pedal and is not summed.
    func isPrimary(_ meterID: UUID) -> Bool {
        primarySource?.memberIDs.contains(meterID) ?? false
    }

    func source(containing meterID: UUID) -> PowerSource? {
        sources.first { $0.memberIDs.contains(meterID) }
    }

    /// What a source is putting out, as of `now`.
    ///
    /// For a pair this is left plus right. When one side has gone quiet the
    /// other is doubled rather than halving the rider: a single-sided pedal
    /// meter estimates the whole rider from one leg, and a pair that has lost a
    /// side is exactly that. It is an estimate and the UI says so, but it is a
    /// far better one than reporting half the load as if the rider had stopped
    /// using a leg.
    func watts(of source: PowerSource, at now: Date) -> Int? {
        guard case let .pedalPair(left, right) = source.shape else {
            return lastRaw[source.id]?.watts
        }
        let live = [left, right].compactMap { id -> Int? in
            guard let reading = lastRaw[id],
                  now.timeIntervalSince(reading.at) <= Self.sideDropsAfter else { return nil }
            return reading.watts
        }
        switch live.count {
        case 2: return live[0] + live[1]
        case 1: return live[0] * 2
        default: return nil
        }
    }

    /// Whether a pair is currently running on one leg, so the row can say so.
    func isEstimatingFromOneSide(_ source: PowerSource, at now: Date) -> Bool {
        guard case let .pedalPair(left, right) = source.shape else { return false }
        let live = [left, right].filter { id in
            guard let reading = lastRaw[id] else { return false }
            return now.timeIntervalSince(reading.at) <= Self.sideDropsAfter
        }
        return live.count == 1
    }

    private func reconsiderPrimary(now: Date) {
        let chosen = picker.pick(current: primaryMeterID, eligible: powerCapableIDs, now: now)
        guard chosen != primaryMeterID else { return }
        primaryMeterID = chosen
    }

    private func persistPaired() {
        guard let data = try? JSONEncoder().encode(paired) else { return }
        UserDefaults.standard.set(data, forKey: Self.pairedKey)
    }
}
