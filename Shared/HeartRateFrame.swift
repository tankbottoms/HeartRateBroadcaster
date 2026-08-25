import Foundation

/// Encoder for the Bluetooth SIG **Heart Rate Measurement** characteristic
/// (`0x2A37`) inside the **Heart Rate Service** (`0x180D`).
///
/// Layout, per the SIG spec:
///
/// ```
/// byte 0   flags
///          bit 0     value format   0 = UInt8, 1 = UInt16
///          bit 1-2   sensor contact 00 = not supported
///          bit 3     energy expended present
///          bit 4     RR-interval present
///          bit 5-7   reserved
/// byte 1..  heart rate  (UInt8, or UInt16 little-endian when bit 0 is set)
/// ```
///
/// Every optional field is omitted. Head units tolerate their absence
/// universally; they do *not* all tolerate a malformed flags byte.
enum HeartRateFrame {

    /// Bluetooth UUIDs, as 16-bit shorthand. `CBUUID(string:)` accepts these.
    enum UUIDString {
        static let heartRateService  = "180D"
        static let measurement       = "2A37"
        static let bodySensorLocation = "2A38"
        static let deviceInformation = "180A"
        static let manufacturerName  = "2A29"
    }

    /// `0x2A38` Body Sensor Location. `0x02` = Wrist.
    /// Some head-unit firmware filters on this characteristic being present.
    static let bodySensorLocationWrist = Data([0x02])

    static func encode(bpm: Int) -> Data {
        let clamped = max(0, min(bpm, 65535))
        if clamped <= 255 {
            return Data([0x00, UInt8(clamped)])
        }
        return Data([0x01, UInt8(clamped & 0xFF), UInt8((clamped >> 8) & 0xFF)])
    }
}
