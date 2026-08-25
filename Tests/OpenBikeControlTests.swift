import XCTest

/// The wire format is the whole contract with another vendor's app: there is no
/// handshake that would catch a byte in the wrong place, and a mis-encoded shift
/// simply does nothing while the rider presses harder. So the bytes are asserted
/// literally here rather than round-tripped through our own decoder, which would
/// agree with any mistake it shared.
final class OpenBikeControlTests: XCTestCase {

    // MARK: - Button frames

    func testButtonStateFrameIsTypeThenPairs() {
        let data = OpenBikeControl.encodeButtonState([(.shiftUp, .down), (.shiftDown, .up)])
        XCTAssertEqual([UInt8](data), [0x01, 0x01, 0x01, 0x02, 0x00])
    }

    func testEmptyButtonStateIsJustTheType() {
        XCTAssertEqual([UInt8](OpenBikeControl.encodeButtonState([])), [0x01])
    }

    /// A tap is two frames, not one frame with both edges in it. Collapsing them
    /// would read at the far end as two different buttons.
    func testTapIsPressThenReleaseAsSeparateFrames() {
        let frames = OpenBikeControl.tap(.shiftDown)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual([UInt8](frames[0]), [0x01, 0x02, 0x01])
        XCTAssertEqual([UInt8](frames[1]), [0x01, 0x02, 0x00])
    }

    func testDeviceStatusClampsBatteryToOneHundred() {
        XCTAssertEqual([UInt8](OpenBikeControl.encodeDeviceStatus(batteryPercent: 200)),
                       [0x02, 100, 0x01])
        XCTAssertEqual([UInt8](OpenBikeControl.encodeDeviceStatus(batteryPercent: 40, connected: false)),
                       [0x02, 40, 0x00])
    }

    // MARK: - App info

    private func appInfoFrame(appID: String = "MyWhoosh",
                              version: String = "1.2",
                              buttons: [UInt8] = [0x01, 0x02]) -> Data {
        var bytes: [UInt8] = [0x04, 0x01]
        bytes.append(UInt8(appID.utf8.count)); bytes += Array(appID.utf8)
        bytes.append(UInt8(version.utf8.count)); bytes += Array(version.utf8)
        bytes.append(UInt8(buttons.count)); bytes += buttons
        return Data(bytes)
    }

    func testParsesAppInfo() {
        let info = OpenBikeControl.parseAppInfo(appInfoFrame())
        XCTAssertEqual(info?.appID, "MyWhoosh")
        XCTAssertEqual(info?.appVersion, "1.2")
        XCTAssertEqual(info?.supportedButtons, [.shiftUp, .shiftDown])
        XCTAssertEqual(info?.supportsShifting, true)
    }

    /// An app that lists only buttons this shifter does not offer is connected
    /// and useless, and the UI has to be able to tell that from a healthy link.
    func testAppInfoWithoutShiftButtonsDoesNotClaimShifting() {
        let info = OpenBikeControl.parseAppInfo(appInfoFrame(buttons: [0x40, 0x41]))
        XCTAssertEqual(info?.supportedButtons, [])
        XCTAssertEqual(info?.supportsShifting, false)
    }

    /// Truncation is the ordinary case on a stream, not corruption. It must
    /// return nil rather than read past the end.
    func testTruncatedAppInfoIsRejected() {
        let full = appInfoFrame()
        for length in 1 ..< full.count {
            XCTAssertNil(OpenBikeControl.parseAppInfo(full.prefix(length)),
                         "accepted a frame \(length) of \(full.count) bytes long")
        }
        XCTAssertNotNil(OpenBikeControl.parseAppInfo(full))
    }

    func testWrongMessageTypeIsNotAppInfo() {
        XCTAssertNil(OpenBikeControl.parseAppInfo(Data([0x01, 0x01, 0x01])))
    }

    // MARK: - Framing

    func testSplitsTwoFramesFromOneChunk() {
        let chunk = appInfoFrame() + Data([0x03, 0x01, 0x00, 0x00])
        let (frames, remainder) = OpenBikeControl.split(chunk)
        XCTAssertEqual(frames.count, 2)
        XCTAssertNotNil(OpenBikeControl.parseAppInfo(frames[0]))
        XCTAssertEqual(remainder.count, 0)
    }

    /// Half a frame has to be given back, not consumed: the rest of it arrives
    /// on the next read, and a game that identifies itself across a packet
    /// boundary would otherwise never be recognised at all.
    func testHalfAFrameIsReturnedAsRemainder() {
        let full = appInfoFrame()
        let (frames, remainder) = OpenBikeControl.split(full.prefix(5))
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(remainder.count, 5)
    }

    func testUnknownMessageTypeStopsTheScan() {
        let (frames, remainder) = OpenBikeControl.split(Data([0x7F, 0x00]))
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(remainder.count, 2)
    }

    // MARK: - Keepalives

    /// MyWhoosh sends a bare zero every four seconds. Held in the buffer instead
    /// of eaten, the first one blocks every frame behind it for the rest of the
    /// ride — the shifter goes quiet and nothing says why.
    func testKeepAliveIsConsumedAndReportedAsNoFrame() {
        let (frames, remainder) = OpenBikeControl.split(Data([0x00, 0x00, 0x00]))
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(remainder.count, 0)
    }

    func testKeepAlivesDoNotHideTheFrameBehindThem() {
        let chunk = Data([0x00]) + appInfoFrame() + Data([0x00])
        let (frames, remainder) = OpenBikeControl.split(chunk)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(OpenBikeControl.parseAppInfo(frames[0])?.appID, "MyWhoosh")
        XCTAssertEqual(remainder.count, 0)
    }

    // MARK: - Absolute gear

    /// The third byte is the gear, not a button state, so there is no release
    /// frame: a release would read as a request for gear zero.
    func testGearSetIsOneFrameCarryingTheGear() {
        XCTAssertEqual([UInt8](OpenBikeControl.encodeGearSet(15)), [0x01, 0x03, 15])
    }

    func testGearSetClampsBelowOne() {
        XCTAssertEqual([UInt8](OpenBikeControl.encodeGearSet(0)), [0x01, 0x03, 1])
        XCTAssertEqual([UInt8](OpenBikeControl.encodeGearSet(-4)), [0x01, 0x03, 1])
    }

    /// The real frame MyWhoosh 5.7.0 sends, byte for byte, taken off the wire.
    /// It lists ten buttons this app has never heard of and one it needs.
    func testMyWhooshAppInfoIsUnderstood() {
        let recorded: [UInt8] = [0x04, 0x01, 0x08, 0x6d, 0x79, 0x77, 0x68, 0x6f, 0x6f, 0x73, 0x68,
                                 0x05, 0x35, 0x2e, 0x37, 0x2e, 0x30,
                                 0x0e, 0x01, 0x02, 0x03, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15,
                                 0x16, 0x17, 0x18, 0x19, 0x40]
        let info = OpenBikeControl.parseAppInfo(Data(recorded))
        XCTAssertEqual(info?.appID, "mywhoosh")
        XCTAssertEqual(info?.appVersion, "5.7.0")
        XCTAssertEqual(info?.supportsShifting, true)
        XCTAssertEqual(info?.supportedButtons.contains(.gearSet), true)
    }
}
