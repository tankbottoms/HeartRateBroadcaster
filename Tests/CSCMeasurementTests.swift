import XCTest

/// `0x2A5B` carries no mandatory measurement at all — a packet with a zero flag
/// byte is legal and says nothing. The parser has to distinguish "nothing to
/// report" from "malformed", because only the second one is a fault.
final class CSCMeasurementTests: XCTestCase {

    func testWheelOnly() {
        let m = CSCMeasurement([0x01,
                                0xE8, 0x03, 0x00, 0x00,
                                0x00, 0x04])
        XCTAssertEqual(m?.cumulativeWheelRevolutions, 1000)
        XCTAssertEqual(m?.lastWheelEventTime, 1024)
        XCTAssertNil(m?.cumulativeCrankRevolutions)
    }

    func testCrankOnly() {
        let m = CSCMeasurement([0x02, 0x2C, 0x01, 0x00, 0x08])
        XCTAssertEqual(m?.cumulativeCrankRevolutions, 300)
        XCTAssertEqual(m?.lastCrankEventTime, 2048)
        XCTAssertNil(m?.cumulativeWheelRevolutions)
    }

    /// Both flags set: wheel comes first, so the crank offset depends on it.
    func testWheelAndCrank() {
        let m = CSCMeasurement([0x03,
                                0xE8, 0x03, 0x00, 0x00,
                                0x00, 0x04,
                                0x2C, 0x01, 0x00, 0x08])
        XCTAssertEqual(m?.cumulativeWheelRevolutions, 1000)
        XCTAssertEqual(m?.lastWheelEventTime, 1024)
        XCTAssertEqual(m?.cumulativeCrankRevolutions, 300)
        XCTAssertEqual(m?.lastCrankEventTime, 2048)
    }

    /// A legal packet that reports nothing. Not an error.
    func testEmptyFlagsParsesWithNoFields() {
        let m = CSCMeasurement([0x00])
        XCTAssertNotNil(m)
        XCTAssertNil(m?.cumulativeWheelRevolutions)
        XCTAssertNil(m?.cumulativeCrankRevolutions)
    }

    func testTruncatedReturnsNil() {
        XCTAssertNil(CSCMeasurement([]))
        XCTAssertNil(CSCMeasurement([0x01, 0xE8, 0x03]))
        XCTAssertNil(CSCMeasurement([0x03, 0xE8, 0x03, 0x00, 0x00, 0x00, 0x04, 0x2C]))
    }
}
