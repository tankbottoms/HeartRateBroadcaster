import Foundation

/// Decides which of several power meters is the one to believe.
///
/// Three meters on one bike disagree for physical reasons, not because any of
/// them is broken. Pedals read what the rider puts in; a crank or spider reads
/// the same work one bearing later; a trainer reads what survives the chain,
/// the cassette and the belt. So the highest reading is the one measured
/// closest to the rider, and it is the one worth recording.
///
/// The whole point is to switch *rarely*. A figure that jumps between sources
/// every few seconds is worse than a slightly low one held steady, so a
/// challenger has to be clearly and persistently higher before it wins:
/// smoothed, ahead by a margin, and ahead for several seconds together.
///
/// Pure and time-injected, because the interesting cases — a meter waking up
/// mid-sprint, two meters within a watt of each other, a coast down to zero —
/// are miserable to produce on a bike and trivial to produce in a test.
struct PrimaryMeterPicker {

    /// How fast the smoothed reading follows the raw one. Roughly a five-second
    /// memory at one sample a second, which is long enough to ignore the ragged
    /// per-pedal-stroke disagreement between a pedal meter and a trainer.
    static let smoothing = 0.2

    /// A challenger must beat the incumbent by this much *and* by this fraction.
    /// Both, because 5 W means something at 80 W and nothing at 400 W.
    static let marginWatts = 5.0
    static let marginFraction = 0.03

    /// And must stay ahead this long. A sprint is longer than this; a spike is
    /// shorter.
    static let dwell: TimeInterval = 6

    /// Below this, everybody is coasting and the ordering is noise. Holding the
    /// current pick through a descent avoids a switch decided by which meter
    /// reports zero more enthusiastically.
    static let floorWatts = 25.0

    /// A meter that has said nothing recently is not a candidate. Long enough to
    /// ride through a dropout, short enough that an unclipped pedal does not
    /// keep winning on a stale number.
    static let staleAfter: TimeInterval = 8

    struct Reading {
        var smoothedWatts: Double
        var lastAt: Date
    }

    private(set) var readings: [UUID: Reading] = [:]
    /// Who has been out in front, and since when. Cleared whenever the lead
    /// changes hands, which is what makes the dwell a dwell.
    private var challenger: (id: UUID, since: Date)?

    init() {}

    /// Feeds in one meter's watts.
    mutating func observe(meterID: UUID, watts: Int, at: Date) {
        let value = Double(watts)
        if var existing = readings[meterID] {
            existing.smoothedWatts += Self.smoothing * (value - existing.smoothedWatts)
            existing.lastAt = at
            readings[meterID] = existing
        } else {
            // A meter that has just woken up starts at what it says, not at
            // zero: otherwise it spends its first ten seconds losing to a stale
            // rival on the strength of an average it never claimed.
            readings[meterID] = Reading(smoothedWatts: value, lastAt: at)
        }
    }

    mutating func forget(_ meterID: UUID) {
        readings[meterID] = nil
        if challenger?.id == meterID { challenger = nil }
    }

    /// The meter that should be primary now.
    ///
    /// - Parameters:
    ///   - current: who is primary at the moment. Returned unchanged unless
    ///     somebody has genuinely earned the swap.
    ///   - eligible: the meters that can measure work at all. A cadence sensor
    ///     is not a candidate however loudly it reports.
    /// - Returns: the meter to make primary, or nil to leave things alone.
    mutating func pick(current: UUID?, eligible: Set<UUID>, now: Date) -> UUID? {
        let live = readings.filter { id, reading in
            eligible.contains(id) && now.timeIntervalSince(reading.lastAt) <= Self.staleAfter
        }
        guard !live.isEmpty else { return current }

        // Nobody primary yet, or the incumbent has gone quiet: take the best
        // live meter immediately. There is no incumbency to protect.
        guard let current, let incumbent = live[current] else {
            challenger = nil
            return live.max { $0.value.smoothedWatts < $1.value.smoothedWatts }?.key ?? current
        }

        guard let (leaderID, leader) = live.max(by: { $0.value.smoothedWatts < $1.value.smoothedWatts }),
              leaderID != current else {
            challenger = nil
            return current
        }

        // Coasting: everything is near zero and the ordering means nothing.
        guard leader.smoothedWatts >= Self.floorWatts else {
            challenger = nil
            return current
        }

        let clearlyAhead = leader.smoothedWatts >= incumbent.smoothedWatts + Self.marginWatts
            && leader.smoothedWatts >= incumbent.smoothedWatts * (1 + Self.marginFraction)
        guard clearlyAhead else {
            challenger = nil
            return current
        }

        if let existing = challenger, existing.id == leaderID {
            guard now.timeIntervalSince(existing.since) >= Self.dwell else { return current }
            challenger = nil
            return leaderID
        }

        challenger = (leaderID, now)
        return current
    }
}
