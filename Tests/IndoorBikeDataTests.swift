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
}
