import XCTest

/// The record is the only thing that survives the session, so its round trip is
/// the thing that decides whether history exists after a relaunch.
final class WorkoutRecordTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func record() -> WorkoutRecord {
        WorkoutRecord(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            sport: .cycling,
            start: t0,
            end: t0.addingTimeInterval(3600),
            gaps: [SignalGap(start: t0.addingTimeInterval(600),
                             end: t0.addingTimeInterval(900),
                             meterName: "P1")],
            totalKilocalories: 717,
            activeKilocalories: 640,
            energySource: .power,
            primaryMeterID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            meterTotals: [MeterTotals(meterID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
                                      meterName: "P1",
                                      kind: .cyclingPower,
                                      averageWatts: 200,
                                      maximumWatts: 620,
                                      kilojoules: 720,
                                      sampleCount: 3300)],
            averageHeartRate: 148,
            maximumHeartRate: 176,
            averageCadence: 89,
            averagePower: 200,
            maximumPower: 620,
            totalKilojoules: 720,
            savedToHealth: true,
            profileWasComplete: true)
    }

    func testDurationIsEndMinusStart() {
        XCTAssertEqual(record().duration, 3600, accuracy: 0.001)
    }

    /// The integral runs over recorded time, not wall time. Five minutes at a
    /// café is not five minutes of soft-pedalling.
    func testRecordedDurationExcludesGaps() {
        XCTAssertEqual(record().recordedDuration, 3300, accuracy: 0.001)
    }

    func testGapDuration() {
        XCTAssertEqual(record().gaps.first?.duration ?? 0, 300, accuracy: 0.001)
    }

    func testCodableRoundTrip() throws {
        let original = record()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkoutRecord.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// A session that recorded nothing still has to encode and decode — an
    /// abandoned start is exactly the case the crash journal replays.
    func testEmptySessionRoundTrips() throws {
        let empty = WorkoutRecord(id: UUID(), sport: .running, start: t0, end: t0,
                                  gaps: [], totalKilocalories: 0, activeKilocalories: 0,
                                  energySource: .none, primaryMeterID: nil, meterTotals: [],
                                  averageHeartRate: nil, maximumHeartRate: nil,
                                  averageCadence: nil, averagePower: nil, maximumPower: nil,
                                  totalKilojoules: 0, savedToHealth: false,
                                  profileWasComplete: false)
        let data = try JSONEncoder().encode(empty)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutRecord.self, from: data), empty)
        XCTAssertEqual(empty.recordedDuration, 0, accuracy: 0.001)
    }

    func testMeterKindMapsToItsService() {
        XCTAssertEqual(MeterKind.cyclingPower.serviceUUIDString, "1818")
        XCTAssertEqual(MeterKind.cyclingPower.measurementUUIDString, "2A63")
        XCTAssertEqual(MeterKind.speedCadence.serviceUUIDString, "1816")
        XCTAssertEqual(MeterKind.speedCadence.measurementUUIDString, "2A5B")
        XCTAssertEqual(MeterKind.fitnessMachine.serviceUUIDString, "1826")
        XCTAssertEqual(MeterKind.fitnessMachine.measurementUUIDString, "2AD2")
    }

    func testSportsAreTheThreeOffered() {
        XCTAssertEqual(WorkoutSport.allCases, [.cycling, .running, .swimming])
    }
}
