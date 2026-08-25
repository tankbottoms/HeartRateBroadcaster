import Foundation

/// Turns successive cumulative-revolution samples into a rate.
///
/// Both counters are 16 bits and both wrap during a normal ride — the event
/// clock every 64 seconds. Unsigned subtraction with `&-` wraps the same way
/// the counter does, which turns the rollover from a special case into the
/// ordinary arithmetic. Also used for wheel revolutions, which is why the time
/// base is a parameter rather than a constant.
struct CadenceTracker {

    private let timeUnitsPerSecond: Double
    private var lastRevolutions: UInt16?
    private var lastEventTime: UInt16?

    /// The most recent computed rate. Held across stalled samples so a meter
    /// repeating itself does not blank the display.
    private(set) var rpm: Double?

    init(timeUnitsPerSecond: Double = 1024) {
        self.timeUnitsPerSecond = timeUnitsPerSecond
    }

    /// Returns the new rate, or `nil` when this sample cannot produce one —
    /// either it is the first, or the meter repeated an event time and no time
    /// has passed to divide by. `rpm` keeps its previous value in that case.
    @discardableResult
    mutating func submit(revolutions: UInt16, eventTime: UInt16) -> Double? {
        defer {
            lastRevolutions = revolutions
            lastEventTime = eventTime
        }
        guard let previousRevs = lastRevolutions, let previousTime = lastEventTime else {
            return nil
        }
        let elapsedUnits = eventTime &- previousTime
        guard elapsedUnits > 0 else { return nil }
        let turns = Double(revolutions &- previousRevs)
        let seconds = Double(elapsedUnits) / timeUnitsPerSecond
        let value = turns / seconds * 60.0
        rpm = value
        return value
    }

    mutating func reset() {
        lastRevolutions = nil
        lastEventTime = nil
        rpm = nil
    }
}
