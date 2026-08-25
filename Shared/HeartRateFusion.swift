import Foundation

/// Merges several heart rate sources into **one** broadcast stream.
///
/// The app can hear from the Apple Watch and from AirPods Pro 3 at the same
/// time. A head unit must never see two sensors, and it must never see the
/// value flapping between two sources that disagree — so everything is reduced
/// to a single number here before it reaches `BLEBroadcaster`.
///
/// Deliberately a plain value type with no Apple frameworks in it, so the
/// arbitration rules can be unit tested without a watch, AirPods, or a ride.
struct HeartRateFusion {

    enum Origin: String, CaseIterable {
        case watch
        case airPods

        var label: String { self == .watch ? "Watch" : "AirPods" }
    }

    struct Reading: Equatable {
        var bpm: Int
        var at: Date
    }

    /// A reading older than this is treated as gone, not merely stale. Both
    /// sensors deliver about once a second, so five seconds is many missed
    /// samples rather than a hiccup.
    var maxAge: TimeInterval = 5

    /// Within this many BPM the two sensors are considered to agree and are
    /// averaged. Beyond it one of them is wrong and has to be picked against.
    var agreementWindow: Int = 12

    /// Ceiling on how fast the fused output may move, in BPM per second. A real
    /// heart cannot climb faster than roughly this; a PPG sensor losing contact
    /// absolutely can. Applied only when two sources are live — with a single
    /// sensor there is nothing to cross-check against, and clamping would just
    /// invent a number the sensor never reported.
    var maxSlewPerSecond: Double = 25

    private(set) var readings: [Origin: Reading] = [:]

    /// Last value handed out, and when.
    private(set) var output: Int?
    private(set) var outputAt: Date?

    /// Which sensor the current output came from, for display.
    private(set) var decidedBy: Set<Origin> = []

    /// Absolute difference between the two sensors at the last fuse, when both
    /// were live. nil when only one sensor is contributing.
    private(set) var disagreement: Int?

    /// True when the last fuse threw a sensor out as an outlier.
    private(set) var didRejectOutlier = false

    // MARK: - Input

    mutating func submit(_ bpm: Int, from origin: Origin, at date: Date = Date()) {
        guard (20...250).contains(bpm) else { return }
        readings[origin] = Reading(bpm: bpm, at: date)
    }

    mutating func clear(_ origin: Origin) {
        readings[origin] = nil
    }

    mutating func reset() {
        readings.removeAll()
        output = nil
        outputAt = nil
        decidedBy = []
        disagreement = nil
        didRejectOutlier = false
    }

    // MARK: - Arbitration

    /// Resolve the current sources to a single value. Returns nil when every
    /// source has gone quiet — the caller should then stop broadcasting rather
    /// than repeat the last number forever.
    @discardableResult
    mutating func fuse(now: Date = Date()) -> Int? {
        let live = readings.filter { now.timeIntervalSince($0.value.at) <= maxAge }
        disagreement = nil
        didRejectOutlier = false

        guard !live.isEmpty else {
            output = nil
            outputAt = nil
            decidedBy = []
            return nil
        }

        // One source: pass it through untouched. Smoothing a lone sensor only
        // adds lag to a number nothing else can contradict.
        if live.count == 1, let only = live.first {
            decidedBy = [only.key]
            output = only.value.bpm
            outputAt = now
            return output
        }

        let watch = live[.watch]?.bpm
        let pods = live[.airPods]?.bpm
        guard let watch, let pods else { return output }

        let delta = abs(watch - pods)
        disagreement = delta
        decidedBy = [.watch, .airPods]

        let candidate: Int
        if delta <= agreementWindow {
            // Agreement — average, which halves the sample noise of either one.
            candidate = Int((Double(watch) + Double(pods)) / 2.0 + 0.5)
        } else {
            didRejectOutlier = true
            // Disagreement — keep whichever is closer to where we already were.
            // Absent history, trust the lower reading: a PPG sensor that loses
            // skin contact reads high (it starts tracking motion cadence), it
            // very rarely invents a low pulse.
            if let previous = output {
                candidate = abs(watch - previous) <= abs(pods - previous) ? watch : pods
                decidedBy = [abs(watch - previous) <= abs(pods - previous) ? .watch : .airPods]
            } else {
                candidate = min(watch, pods)
                decidedBy = [watch <= pods ? .watch : .airPods]
            }
        }

        output = slewLimited(candidate, now: now)
        outputAt = now
        return output
    }

    private func slewLimited(_ candidate: Int, now: Date) -> Int {
        guard let previous = output, let previousAt = outputAt else { return candidate }
        let elapsed = max(0.1, now.timeIntervalSince(previousAt))
        let maxStep = Int((maxSlewPerSecond * elapsed).rounded())
        guard maxStep > 0 else { return previous }
        let delta = candidate - previous
        if abs(delta) <= maxStep { return candidate }
        return previous + (delta > 0 ? maxStep : -maxStep)
    }
}
