import XCTest

/// A 16-bit event clock at 1/1024 s wraps every 64 seconds, so a ride of any
/// length crosses it repeatedly. Treating the wrap as an anomaly produces a
/// cadence spike once a minute; treating it as arithmetic produces a number.
final class CadenceTrackerTests: XCTestCase {

    func testFirstSampleHasNoPredecessor() {
        var t = CadenceTracker()
        XCTAssertNil(t.submit(revolutions: 100, eventTime: 1024))
        XCTAssertNil(t.rpm)
    }

    /// One revolution per second is 60 rpm.
    func testSteadyCadence() {
        var t = CadenceTracker()
        _ = t.submit(revolutions: 100, eventTime: 1024)
        XCTAssertEqual(t.submit(revolutions: 101, eventTime: 2048) ?? 0, 60.0, accuracy: 0.001)
    }

    /// 90 rpm: 3 revolutions in 2 seconds.
    func testNinetyRPM() {
        var t = CadenceTracker()
        _ = t.submit(revolutions: 0, eventTime: 0)
        XCTAssertEqual(t.submit(revolutions: 3, eventTime: 2048) ?? 0, 90.0, accuracy: 0.001)
    }

    /// The event clock wraps mid-interval. 65535 -> 511 is 1024 units, one
    /// second, not a jump backwards.
    func testEventTimeRollover() {
        var t = CadenceTracker()
        _ = t.submit(revolutions: 100, eventTime: 65535)
        XCTAssertEqual(t.submit(revolutions: 101, eventTime: 1023) ?? 0, 60.0, accuracy: 0.001)
    }

    /// The revolution counter wraps. 65535 -> 0 is one revolution.
    func testRevolutionRollover() {
        var t = CadenceTracker()
        _ = t.submit(revolutions: 65535, eventTime: 1024)
        XCTAssertEqual(t.submit(revolutions: 0, eventTime: 2048) ?? 0, 60.0, accuracy: 0.001)
    }

    /// A stopped crank keeps reporting the same event time. No time has passed,
    /// so there is nothing to divide by — hold the previous value rather than
    /// dividing by zero or claiming a cadence of infinity.
    func testStalledCrankHoldsPreviousValue() {
        var t = CadenceTracker()
        _ = t.submit(revolutions: 100, eventTime: 1024)
        _ = t.submit(revolutions: 101, eventTime: 2048)
        XCTAssertNil(t.submit(revolutions: 101, eventTime: 2048))
        XCTAssertEqual(t.rpm ?? 0, 60.0, accuracy: 0.001)
    }

    /// Time passes with no new revolutions: the rider is coasting, and zero is
    /// the true answer, not a missing one.
    func testCoastingIsZeroNotNil() {
        var t = CadenceTracker()
        _ = t.submit(revolutions: 100, eventTime: 1024)
        XCTAssertEqual(t.submit(revolutions: 100, eventTime: 3072) ?? -1, 0.0, accuracy: 0.001)
    }

    /// Reset drops the predecessor, so the next sample starts a fresh pair.
    func testResetClearsHistory() {
        var t = CadenceTracker()
        _ = t.submit(revolutions: 100, eventTime: 1024)
        t.reset()
        XCTAssertNil(t.submit(revolutions: 101, eventTime: 2048))
    }

    /// Cycling Power's wheel times are 1/2048 s, so the unit is a parameter.
    func testAlternateTimeBase() {
        var t = CadenceTracker(timeUnitsPerSecond: 2048)
        _ = t.submit(revolutions: 0, eventTime: 0)
        XCTAssertEqual(t.submit(revolutions: 1, eventTime: 2048) ?? 0, 60.0, accuracy: 0.001)
    }
}
