import XCTest

/// The arbiter is the only thing standing between two sensors and a head unit
/// that must see exactly one. Written as a pure value type specifically so it
/// can be pinned down here without a watch, AirPods, or a Bluetooth radio.
final class HeartRateFusionTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testSingleSourcePassesThroughUntouched() {
        var fusion = HeartRateFusion()
        fusion.submit(142, from: .watch, at: t0)
        XCTAssertEqual(fusion.fuse(now: t0), 142)
        XCTAssertEqual(fusion.decidedBy, [.watch])
        XCTAssertNil(fusion.disagreement)
    }

    func testNoSourcesYieldsNil() {
        var fusion = HeartRateFusion()
        XCTAssertNil(fusion.fuse(now: t0))
    }

    func testAgreeingSourcesAverage() {
        var fusion = HeartRateFusion()
        fusion.submit(140, from: .watch, at: t0)
        fusion.submit(146, from: .airPods, at: t0)
        XCTAssertEqual(fusion.fuse(now: t0), 143)
        XCTAssertEqual(fusion.decidedBy, [.watch, .airPods])
        XCTAssertEqual(fusion.disagreement, 6)
        XCTAssertFalse(fusion.didRejectOutlier)
    }

    func testAverageRoundsHalfUp() {
        var fusion = HeartRateFusion()
        fusion.submit(140, from: .watch, at: t0)
        fusion.submit(141, from: .airPods, at: t0)
        XCTAssertEqual(fusion.fuse(now: t0), 141)
    }

    /// A PPG sensor that loses skin contact reads high, so with no history to
    /// compare against the lower reading is the safer one to trust.
    func testDisagreementWithoutHistoryPrefersLower() {
        var fusion = HeartRateFusion()
        fusion.submit(135, from: .watch, at: t0)
        fusion.submit(198, from: .airPods, at: t0)
        XCTAssertEqual(fusion.fuse(now: t0), 135)
        XCTAssertTrue(fusion.didRejectOutlier)
        XCTAssertEqual(fusion.disagreement, 63)
    }

    func testDisagreementWithHistoryKeepsTheReadingNearTheTrend() {
        var fusion = HeartRateFusion()
        // Establish a trend around 150 from one sensor.
        fusion.submit(150, from: .watch, at: t0)
        XCTAssertEqual(fusion.fuse(now: t0), 150)

        // Now AirPods drops out to 90 while the watch stays at 152. The watch
        // is closer to what we already believe, so it wins — even though it is
        // the higher of the two.
        let t1 = t0.addingTimeInterval(1)
        fusion.submit(152, from: .watch, at: t1)
        fusion.submit(90, from: .airPods, at: t1)
        XCTAssertEqual(fusion.fuse(now: t1), 152)
        XCTAssertTrue(fusion.didRejectOutlier)
    }

    func testStaleReadingIsPruned() {
        var fusion = HeartRateFusion()
        fusion.submit(120, from: .airPods, at: t0)
        fusion.submit(160, from: .watch, at: t0.addingTimeInterval(10))

        // 10s later the AirPods reading is well past maxAge (5s), so it must
        // not drag the average down.
        XCTAssertEqual(fusion.fuse(now: t0.addingTimeInterval(10)), 160)
        XCTAssertEqual(fusion.decidedBy, [.watch])
    }

    func testAllStaleYieldsNil() {
        var fusion = HeartRateFusion()
        fusion.submit(120, from: .watch, at: t0)
        XCTAssertNil(fusion.fuse(now: t0.addingTimeInterval(30)))
    }

    /// Slew limiting only applies with two sensors live — a single sensor is
    /// the ground truth and must never be second-guessed.
    func testSlewLimitAppliesOnlyWithTwoSources() {
        var fusion = HeartRateFusion()
        fusion.submit(100, from: .watch, at: t0)
        XCTAssertEqual(fusion.fuse(now: t0), 100)

        let t1 = t0.addingTimeInterval(1)
        fusion.submit(180, from: .watch, at: t1)
        XCTAssertEqual(fusion.fuse(now: t1), 180, "one sensor passes through unclamped")
    }

    func testClearRemovesOneSource() {
        var fusion = HeartRateFusion()
        fusion.submit(140, from: .watch, at: t0)
        fusion.submit(146, from: .airPods, at: t0)
        fusion.clear(.airPods)
        XCTAssertEqual(fusion.fuse(now: t0), 140)
        XCTAssertEqual(fusion.decidedBy, [.watch])
    }

    func testResetClearsEverything() {
        var fusion = HeartRateFusion()
        fusion.submit(140, from: .watch, at: t0)
        _ = fusion.fuse(now: t0)
        fusion.reset()
        XCTAssertNil(fusion.output)
        XCTAssertNil(fusion.fuse(now: t0))
    }
}
