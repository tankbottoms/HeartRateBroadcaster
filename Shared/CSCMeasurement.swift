import Foundation

/// A single `0x2A5B` Cycling Speed and Cadence Measurement notification.
///
/// Unlike Cycling Power there is no mandatory value: a packet whose flag byte
/// is zero is well formed and carries nothing. That case returns an instance
/// with two nils, because the caller's response to "no data yet" is different
/// from its response to "this meter is sending garbage".
struct CSCMeasurement: Equatable {

    let cumulativeWheelRevolutions: UInt32?
    /// 1/1024 s units — note this differs from Cycling Power's wheel time.
    let lastWheelEventTime: UInt16?

    let cumulativeCrankRevolutions: UInt16?
    /// 1/1024 s units.
    let lastCrankEventTime: UInt16?

    init?(_ data: [UInt8]) {
        var cursor = ByteCursor(data)
        guard let flags = cursor.uint8() else { return nil }

        if flags & 0x01 != 0 {
            guard let revs = cursor.uint32(), let time = cursor.uint16() else { return nil }
            cumulativeWheelRevolutions = revs
            lastWheelEventTime = time
        } else {
            cumulativeWheelRevolutions = nil
            lastWheelEventTime = nil
        }

        if flags & 0x02 != 0 {
            guard let revs = cursor.uint16(), let time = cursor.uint16() else { return nil }
            cumulativeCrankRevolutions = revs
            lastCrankEventTime = time
        } else {
            cumulativeCrankRevolutions = nil
            lastCrankEventTime = nil
        }
    }
}
