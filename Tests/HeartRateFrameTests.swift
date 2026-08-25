import XCTest
import Foundation
// `Shared/` is compiled directly into this target, so there is no app module
// to import — and no need for the app to be testability-enabled.

/// The GATT 0x2A37 frame is the one thing a head unit parses byte-for-byte.
/// Get the flags wrong and the sensor connects but shows nothing.
final class HeartRateFrameTests: XCTestCase {

    func testUInt8FrameIsTwoBytes() {
        XCTAssertEqual(HeartRateFrame.encode(bpm: 72), Data([0x00, 72]))
    }

    func testFlagsByteDeclaresNoOptionalFields() {
        let flags = HeartRateFrame.encode(bpm: 60)[0]
        XCTAssertEqual(flags & 0b0000_0001, 0, "bit0: UInt8 value format")
        XCTAssertEqual(flags & 0b0000_0110, 0, "bit1-2: sensor contact not supported")
        XCTAssertEqual(flags & 0b0000_1000, 0, "bit3: no energy expended")
        XCTAssertEqual(flags & 0b0001_0000, 0, "bit4: no RR intervals")
    }

    /// 255 is the last value that fits a byte; 256 must flip to the
    /// little-endian UInt16 form. Off-by-one here is the classic bug.
    func testUInt8ToUInt16Boundary() {
        XCTAssertEqual(HeartRateFrame.encode(bpm: 255), Data([0x00, 0xFF]))
        XCTAssertEqual(HeartRateFrame.encode(bpm: 256), Data([0x01, 0x00, 0x01]))
        XCTAssertEqual(HeartRateFrame.encode(bpm: 300), Data([0x01, 0x2C, 0x01]))
    }

    func testClamping() {
        XCTAssertEqual(HeartRateFrame.encode(bpm: -10), Data([0x00, 0x00]))
        XCTAssertEqual(HeartRateFrame.encode(bpm: 999_999), Data([0x01, 0xFF, 0xFF]))
    }

    func testBodySensorLocationIsWrist() {
        XCTAssertEqual(HeartRateFrame.bodySensorLocationWrist, Data([0x02]))
    }

    func testServiceAndCharacteristicUUIDs() {
        XCTAssertEqual(HeartRateFrame.UUIDString.heartRateService, "180D")
        XCTAssertEqual(HeartRateFrame.UUIDString.measurement, "2A37")
        XCTAssertEqual(HeartRateFrame.UUIDString.bodySensorLocation, "2A38")
    }
}
