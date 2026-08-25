import XCTest

/// Byte-level optional fields are where power meter support goes wrong: every
/// flag bit that is set moves every field after it. These vectors are built by
/// hand from the GATT specification so a wrong offset fails here rather than as
/// an implausible wattage on a bike.
final class CyclingPowerMeasurementTests: XCTestCase {

    /// Flags 0x0000, power 250 W. The minimum legal payload.
    func testMinimalPayloadIsFlagsAndPower() {
        let m = CyclingPowerMeasurement([0x00, 0x00, 0xFA, 0x00])
        XCTAssertEqual(m?.watts, 250)
        XCTAssertNil(m?.pedalPowerBalance)
        XCTAssertNil(m?.cumulativeCrankRevolutions)
        XCTAssertNil(m?.cumulativeWheelRevolutions)
    }

    /// Power is sint16. A meter that is being back-driven reports below zero.
    func testPowerIsSigned() {
        let m = CyclingPowerMeasurement([0x00, 0x00, 0xFB, 0xFF])
        XCTAssertEqual(m?.watts, -5)
    }

    /// Bit 0 present, bit 1 (reference) set: balance is the left pedal's share,
    /// in halves of a percent. 0x64 = 100 -> 50.0%.
    func testPedalPowerBalanceIsHalfPercentUnits() {
        let m = CyclingPowerMeasurement([0x03, 0x00, 0xFA, 0x00, 0x64])
        XCTAssertEqual(m?.watts, 250)
        XCTAssertEqual(m?.pedalPowerBalance ?? 0, 50.0, accuracy: 0.001)
    }

    /// Bit 0 set without bit 1: the reference is unknown, so the field is
    /// consumed for offset purposes but reported as nil rather than guessed.
    func testBalanceWithoutReferenceIsConsumedButNotReported() {
        let m = CyclingPowerMeasurement([0x01, 0x00, 0xFA, 0x00, 0x64])
        XCTAssertEqual(m?.watts, 250)
        XCTAssertNil(m?.pedalPowerBalance)
    }

    /// Bit 4 — wheel revolution data: uint32 revolutions + uint16 event time.
    func testWheelRevolutionData() {
        let m = CyclingPowerMeasurement([0x10, 0x00, 0xFA, 0x00,
                                         0x01, 0x02, 0x00, 0x00,
                                         0x00, 0x08])
        XCTAssertEqual(m?.cumulativeWheelRevolutions, 0x0201)
        XCTAssertEqual(m?.lastWheelEventTime, 0x0800)
        XCTAssertNil(m?.cumulativeCrankRevolutions)
    }

    /// Bit 5 — crank revolution data: uint16 revolutions + uint16 event time.
    func testCrankRevolutionData() {
        let m = CyclingPowerMeasurement([0x20, 0x00, 0xFA, 0x00,
                                         0x10, 0x00, 0x00, 0x04])
        XCTAssertEqual(m?.cumulativeCrankRevolutions, 16)
        XCTAssertEqual(m?.lastCrankEventTime, 1024)
    }

    /// A PowerTap P1 reports balance and crank data together. Both offsets have
    /// to shift, and this is the packet shape the pedals actually send.
    func testBalanceAndCrankTogether() {
        let m = CyclingPowerMeasurement([0x23, 0x00, 0x2C, 0x01,
                                         0x66, 0x10, 0x00, 0x00, 0x04])
        XCTAssertEqual(m?.watts, 300)
        XCTAssertEqual(m?.pedalPowerBalance ?? 0, 51.0, accuracy: 0.001)
        XCTAssertEqual(m?.cumulativeCrankRevolutions, 16)
        XCTAssertEqual(m?.lastCrankEventTime, 1024)
    }

    /// Wheel *and* crank, as a trainer with a speed estimate sends.
    func testWheelAndCrankTogether() {
        let m = CyclingPowerMeasurement([0x30, 0x00, 0xC8, 0x00,
                                         0x01, 0x00, 0x00, 0x00, 0x00, 0x08,
                                         0x10, 0x00, 0x00, 0x04])
        XCTAssertEqual(m?.watts, 200)
        XCTAssertEqual(m?.cumulativeWheelRevolutions, 1)
        XCTAssertEqual(m?.cumulativeCrankRevolutions, 16)
    }

    /// A flag promising a field the payload does not contain must return nil,
    /// not read past the end. This is the crash this initializer exists to
    /// prevent.
    func testTruncatedOptionalFieldReturnsNil() {
        XCTAssertNil(CyclingPowerMeasurement([0x20, 0x00, 0xFA, 0x00, 0x10]))
    }

    func testTooShortForPowerReturnsNil() {
        XCTAssertNil(CyclingPowerMeasurement([0x00, 0x00, 0xFA]))
        XCTAssertNil(CyclingPowerMeasurement([]))
    }
}
