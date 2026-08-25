import Foundation

/// A single FTMS `0x2AD2` Indoor Bike Data notification.
///
/// Only four values are wanted, but every field before them has to be stepped
/// over, so the whole layout is walked in order. The first flag bit is
/// inverted — "More Data" set means instantaneous speed is *absent* — which is
/// the specification's own wording and the reason this parser reads
/// deliberately rather than jumping to offsets.
struct IndoorBikeData: Equatable {

    /// km/h.
    let speedKPH: Double?
    /// rpm.
    let cadenceRPM: Double?
    /// Watts, signed.
    let watts: Int?
    let heartRate: Int?

    init?(_ data: [UInt8]) {
        var cursor = ByteCursor(data)
        guard let flags = cursor.uint16() else { return nil }

        // Bit 0 inverted: clear means present.
        if flags & 0x0001 == 0 {
            guard let raw = cursor.uint16() else { return nil }
            speedKPH = Double(raw) / 100.0
        } else {
            speedKPH = nil
        }

        // Bit 1 average speed.
        if flags & 0x0002 != 0 { guard cursor.uint16() != nil else { return nil } }

        if flags & 0x0004 != 0 {
            guard let raw = cursor.uint16() else { return nil }
            cadenceRPM = Double(raw) / 2.0
        } else {
            cadenceRPM = nil
        }

        // Bit 3 average cadence.
        if flags & 0x0008 != 0 { guard cursor.uint16() != nil else { return nil } }
        // Bit 4 total distance, uint24.
        if flags & 0x0010 != 0 { guard cursor.uint24() != nil else { return nil } }
        // Bit 5 resistance level, sint16.
        if flags & 0x0020 != 0 { guard cursor.uint16() != nil else { return nil } }

        if flags & 0x0040 != 0 {
            guard let raw = cursor.int16() else { return nil }
            watts = Int(raw)
        } else {
            watts = nil
        }

        // Bit 7 average power.
        if flags & 0x0080 != 0 { guard cursor.uint16() != nil else { return nil } }
        // Bit 8 expended energy: total (uint16), per hour (uint16), per minute (uint8).
        if flags & 0x0100 != 0 {
            guard cursor.uint16() != nil, cursor.uint16() != nil, cursor.uint8() != nil else { return nil }
        }

        if flags & 0x0200 != 0 {
            guard let raw = cursor.uint8() else { return nil }
            heartRate = Int(raw)
        } else {
            heartRate = nil
        }
    }
}
