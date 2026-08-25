import Foundation

/// A single `0x2A63` Cycling Power Measurement notification.
///
/// Everything after the mandatory power field is optional and positional: the
/// flag word says which fields are present, and each present field pushes the
/// next one along. A cursor that refuses to read past the end is the whole
/// point — a malformed packet from a meter with firmware of its own opinions
/// must produce `nil`, not a trap in the Bluetooth callback.
struct CyclingPowerMeasurement: Equatable {

    /// Instantaneous power in watts. Signed: a meter being back-driven, or one
    /// zeroing itself, legitimately reports below zero.
    let watts: Int

    /// Share of power attributed to the left pedal, 0...100, and only when the
    /// packet says the reference is the left pedal. A balance whose reference
    /// is unknown is worse than no balance at all.
    let pedalPowerBalance: Double?

    let cumulativeWheelRevolutions: UInt32?
    /// 1/2048 s units.
    let lastWheelEventTime: UInt16?

    let cumulativeCrankRevolutions: UInt16?
    /// 1/1024 s units.
    let lastCrankEventTime: UInt16?

    init?(_ data: [UInt8]) {
        var cursor = ByteCursor(data)
        guard let flags = cursor.uint16() else { return nil }
        guard let power = cursor.int16() else { return nil }
        watts = Int(power)

        // Bit 0 present, bit 1 reference. The field is consumed either way, or
        // every subsequent offset would be wrong.
        if flags & 0x0001 != 0 {
            guard let raw = cursor.uint8() else { return nil }
            pedalPowerBalance = (flags & 0x0002 != 0) ? Double(raw) / 2.0 : nil
        } else {
            pedalPowerBalance = nil
        }

        // Bit 2 accumulated torque, bit 3 its source. Not used here, but the
        // uint16 still has to be stepped over.
        if flags & 0x0004 != 0 {
            guard cursor.uint16() != nil else { return nil }
        }

        if flags & 0x0010 != 0 {
            guard let revs = cursor.uint32(), let time = cursor.uint16() else { return nil }
            cumulativeWheelRevolutions = revs
            lastWheelEventTime = time
        } else {
            cumulativeWheelRevolutions = nil
            lastWheelEventTime = nil
        }

        if flags & 0x0020 != 0 {
            guard let revs = cursor.uint16(), let time = cursor.uint16() else { return nil }
            cumulativeCrankRevolutions = revs
            lastCrankEventTime = time
        } else {
            cumulativeCrankRevolutions = nil
            lastCrankEventTime = nil
        }
    }
}

/// Little-endian reader that returns `nil` rather than reading past the end.
///
/// Shared by all three measurement parsers. Every GATT characteristic in this
/// feature is little-endian with positional optional fields, so the same
/// discipline applies to each and there is no reason to write it three times.
struct ByteCursor {
    private let bytes: [UInt8]
    private var index: Int = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    private mutating func take(_ count: Int) -> [UInt8]? {
        guard index + count <= bytes.count else { return nil }
        defer { index += count }
        return Array(bytes[index ..< index + count])
    }

    mutating func uint8() -> UInt8? { take(1)?[0] }

    mutating func uint16() -> UInt16? {
        guard let b = take(2) else { return nil }
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    mutating func int16() -> Int16? {
        guard let raw = uint16() else { return nil }
        return Int16(bitPattern: raw)
    }

    mutating func uint24() -> UInt32? {
        guard let b = take(3) else { return nil }
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16
    }

    mutating func uint32() -> UInt32? {
        guard let b = take(4) else { return nil }
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }
}
