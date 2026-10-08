import XCTest

/// FTMS inverts the sense of its first flag bit: 0 means the speed field is
/// present. Every other bit is the usual "1 means present". A parser written on
/// autopilot gets this exactly backwards and every field after it lands on the
/// wrong byte, so the inverted bit gets its own test.
final class IndoorBikeDataTests: XCTestCase {

    /// Flags 0x0000 — more data bit clear, so instantaneous speed IS present.
    func testSpeedPresentWhenBitZeroIsClear() {
        let d = IndoorBikeData([0x00, 0x00, 0x10, 0x0E])
        XCTAssertEqual(d?.speedKPH ?? 0, 36.0, accuracy: 0.001)
        XCTAssertNil(d?.cadenceRPM)
        XCTAssertNil(d?.watts)
    }

    /// Flags 0x0001 — speed absent. Nothing follows.
    func testSpeedAbsentWhenBitZeroIsSet() {
        let d = IndoorBikeData([0x01, 0x00])
        XCTAssertNotNil(d)
        XCTAssertNil(d?.speedKPH)
    }

    /// Bit 2 — instantaneous cadence, in half-rpm units. 0xB4 = 180 -> 90 rpm.
    func testCadenceIsHalfRPMUnits() {
        let d = IndoorBikeData([0x04, 0x00, 0x10, 0x0E, 0xB4, 0x00])
        XCTAssertEqual(d?.speedKPH ?? 0, 36.0, accuracy: 0.001)
        XCTAssertEqual(d?.cadenceRPM ?? 0, 90.0, accuracy: 0.001)
    }

    /// Bit 6 — instantaneous power, sint16 watts. This is the Kickr's payload.
    func testPowerWithSpeedAndCadence() {
        let d = IndoorBikeData([0x44, 0x00,
                                0x10, 0x0E,
                                0xB4, 0x00,
                                0x2C, 0x01])
        XCTAssertEqual(d?.watts, 300)
        XCTAssertEqual(d?.cadenceRPM ?? 0, 90.0, accuracy: 0.001)
    }

    /// Bits 4 (total distance, uint24) and 5 (resistance level, sint16) sit
    /// between cadence and instantaneous power, so setting them must not shift
    /// power. Distance is the one field that is not two bytes wide, which is
    /// exactly where an offset-jumping parser would go wrong.
    func testSkippedFieldsDoNotShiftPower() {
        let d = IndoorBikeData([0x74, 0x00,
                                0x10, 0x0E,
                                0xB4, 0x00,
                                0x64, 0x00, 0x00,
                                0x0A, 0x00,
                                0x2C, 0x01])
        XCTAssertEqual(d?.watts, 300)
        XCTAssertEqual(d?.cadenceRPM ?? 0, 90.0, accuracy: 0.001)
    }

    /// Bit 9 — heart rate, uint8, after the energy fields (bit 8).
    func testHeartRate() {
        let d = IndoorBikeData([0x00, 0x02, 0x10, 0x0E, 0x8E])
        XCTAssertEqual(d?.heartRate, 142)
    }

    func testTruncatedReturnsNil() {
        XCTAssertNil(IndoorBikeData([]))
        XCTAssertNil(IndoorBikeData([0x00]))
        XCTAssertNil(IndoorBikeData([0x00, 0x00, 0x10]))
        XCTAssertNil(IndoorBikeData([0x44, 0x00, 0x10, 0x0E, 0xB4, 0x00, 0x2C]))
    }

    func testSignedPowerWithoutSpeed() {
        let d = IndoorBikeData([0x41, 0x00, 0xCE, 0xFF])
        XCTAssertNotNil(d)
        XCTAssertNil(d?.speedKPH)
        XCTAssertNil(d?.cadenceRPM)
        XCTAssertNil(d?.heartRate)
        XCTAssertEqual(d?.watts, -50)
    }

    func testAllOptionalFieldsAndEveryTruncatedPrefix() {
        // All defined flags except More Data. Includes the app's two-byte
        // resistance layout, energy, and fields after heart rate.
        let bytes: [UInt8] = [
            0xFE, 0x1F,
            0x10, 0x0E,       // speed: 36 km/h
            0xB8, 0x0B,       // average speed
            0xB4, 0x00,       // cadence: 90 rpm
            0xA0, 0x00,       // average cadence
            0x64, 0x00, 0x00, // distance
            0x0A, 0x00,       // resistance (two bytes)
            0x2C, 0x01,       // power: 300 W
            0xFA, 0x00,       // average power
            0x64, 0x00, 0xC8, 0x00, 0x03, // energy
            0x8E,             // heart rate: 142 bpm
            0x32,             // metabolic equivalent
            0x3C, 0x00,       // elapsed time
            0x78, 0x00        // remaining time
        ]
        let d = IndoorBikeData(bytes)
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.speedKPH ?? 0, 36, accuracy: 0.001)
        XCTAssertEqual(d?.cadenceRPM ?? 0, 90, accuracy: 0.001)
        XCTAssertEqual(d?.watts, 300)
        XCTAssertEqual(d?.heartRate, 142)

        for length in 0..<bytes.count {
            XCTAssertNil(IndoorBikeData(Array(bytes.prefix(length))), "Prefix length \(length)")
        }
    }

    func testTruncatedFieldsAfterHeartRateReturnNil() {
        // The old parser stopped at heart rate and accepted these incomplete
        // notifications even though their flags promised additional fields.
        XCTAssertNil(IndoorBikeData([0x00, 0x04, 0x10, 0x0E]))
        XCTAssertNil(IndoorBikeData([0x00, 0x08, 0x10, 0x0E, 0x3C]))
        XCTAssertNil(IndoorBikeData([0x00, 0x10, 0x10, 0x0E, 0x78]))
    }

    func testReservedFlagsAndTrailingBytesRemainTolerated() {
        let d = IndoorBikeData([0x00, 0x80, 0x10, 0x0E, 0xAA])
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.speedKPH ?? 0, 36, accuracy: 0.001)
    }
}
