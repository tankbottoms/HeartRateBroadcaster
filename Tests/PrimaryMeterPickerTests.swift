import XCTest

/// The cases that matter here are the ones a rider produces by accident and
/// nobody can produce on purpose: a meter waking up mid-effort, two meters a
/// watt apart, a coast to zero, a dropout. All of them are seconds long on a
/// bike and free here, which is the reason the picker takes its clock as an
/// argument.
final class PrimaryMeterPickerTests: XCTestCase {

    private let pedals = UUID()
    private let crank = UUID()
    private let trainer = UUID()
    private let cadenceOnly = UUID()

    private var start: Date { Date(timeIntervalSince1970: 1_000_000) }

    /// Feeds one meter the same watts once a second, which is roughly what a
    /// power meter does, so the smoothed value converges where you would expect.
    private func settle(_ picker: inout PrimaryMeterPicker,
                        _ meter: UUID,
                        watts: Int,
                        seconds: Int = 20,
                        from: Date? = nil) {
        let base = from ?? start
        for second in 0 ..< seconds {
            picker.observe(meterID: meter, watts: watts, at: base.addingTimeInterval(Double(second)))
        }
    }

    // MARK: - Taking a first choice

    func testFirstLiveMeterIsChosenImmediately() {
        var picker = PrimaryMeterPicker()
        settle(&picker, trainer, watts: 180)
        XCTAssertEqual(picker.pick(current: nil,
                                   eligible: [pedals, crank, trainer],
                                   now: start.addingTimeInterval(20)),
                       trainer)
    }

    /// No incumbency to protect means no dwell to serve: the highest of several
    /// wins on the spot.
    func testWithNoIncumbentTheHighestWinsWithoutWaiting() {
        var picker = PrimaryMeterPicker()
        settle(&picker, trainer, watts: 180)
        settle(&picker, pedals, watts: 210)
        XCTAssertEqual(picker.pick(current: nil,
                                   eligible: [pedals, trainer],
                                   now: start.addingTimeInterval(20)),
                       pedals)
    }

    /// A cadence sensor reports busily and measures no work at all. It must not
    /// be able to win by reporting, whatever it happens to be sending.
    func testIneligibleMetersCannotWin() {
        var picker = PrimaryMeterPicker()
        settle(&picker, trainer, watts: 150)
        settle(&picker, cadenceOnly, watts: 900)
        XCTAssertEqual(picker.pick(current: trainer,
                                   eligible: [trainer],
                                   now: start.addingTimeInterval(60)),
                       trainer)
    }

    // MARK: - Holding on

    func testAHigherMeterMustStayHigherBeforeItWins() {
        var picker = PrimaryMeterPicker()
        settle(&picker, trainer, watts: 200)
        settle(&picker, pedals, watts: 240)
        let now = start.addingTimeInterval(20)

        // First sight of the lead starts the clock, it does not end it.
        XCTAssertEqual(picker.pick(current: trainer, eligible: [pedals, trainer], now: now), trainer)
        XCTAssertEqual(picker.pick(current: trainer,
                                   eligible: [pedals, trainer],
                                   now: now.addingTimeInterval(PrimaryMeterPicker.dwell - 1)),
                       trainer)
        XCTAssertEqual(picker.pick(current: trainer,
                                   eligible: [pedals, trainer],
                                   now: now.addingTimeInterval(PrimaryMeterPicker.dwell)),
                       pedals)
    }

    /// A single hard pedal stroke against a trainer that has not caught up yet
    /// is not a reason to change meters mid-workout.
    func testAMomentaryLeadDoesNotWin() {
        var picker = PrimaryMeterPicker()
        settle(&picker, trainer, watts: 200)
        settle(&picker, pedals, watts: 180)
        var now = start.addingTimeInterval(20)

        picker.observe(meterID: pedals, watts: 600, at: now)
        XCTAssertEqual(picker.pick(current: trainer, eligible: [pedals, trainer], now: now), trainer)

        // And then it falls back behind, which clears the clock rather than
        // banking the seconds it was ahead.
        for _ in 0 ..< 10 {
            now = now.addingTimeInterval(1)
            picker.observe(meterID: pedals, watts: 180, at: now)
            picker.observe(meterID: trainer, watts: 200, at: now)
        }
        XCTAssertEqual(picker.pick(current: trainer, eligible: [pedals, trainer], now: now), trainer)
    }

    /// Two watts apart at 200 W is the two meters agreeing, not one of them
    /// being better.
    func testAMeterThatIsBarelyAheadDoesNotWin() {
        var picker = PrimaryMeterPicker()
        settle(&picker, trainer, watts: 200)
        settle(&picker, pedals, watts: 203)
        let now = start.addingTimeInterval(60)
        XCTAssertEqual(picker.pick(current: trainer, eligible: [pedals, trainer], now: now), trainer)
    }

    /// Five watts clears the absolute margin and fails the proportional one. At
    /// 400 W that is a rounding difference between two honest meters.
    func testTheMarginIsProportionalAsWellAsAbsolute() {
        var picker = PrimaryMeterPicker()
        settle(&picker, trainer, watts: 400)
        settle(&picker, pedals, watts: 406)
        let now = start.addingTimeInterval(60)
        XCTAssertEqual(picker.pick(current: trainer, eligible: [pedals, trainer], now: now), trainer)
    }

    /// Coasting down a hill, everything reads near zero and the ordering is
    /// whichever meter reports its zero with more conviction.
    func testNobodyWinsWhileCoasting() {
        var picker = PrimaryMeterPicker()
        settle(&picker, trainer, watts: 0)
        settle(&picker, pedals, watts: 12)
        let now = start.addingTimeInterval(60)
        XCTAssertEqual(picker.pick(current: trainer, eligible: [pedals, trainer], now: now), trainer)
    }

    // MARK: - Going quiet

    /// A meter that has dropped out cannot keep the star on the strength of the
    /// last number it said before its battery went.
    func testAStaleIncumbentIsReplacedImmediately() {
        var picker = PrimaryMeterPicker()
        settle(&picker, trainer, watts: 300)
        let later = start.addingTimeInterval(60)
        settle(&picker, pedals, watts: 150, from: later)

        XCTAssertEqual(picker.pick(current: trainer,
                                   eligible: [pedals, trainer],
                                   now: later.addingTimeInterval(20)),
                       pedals)
    }

    /// Everything quiet is a pause, not a decision. Clearing the star here would
    /// stop the energy figure the moment the rider stopped at a light.
    func testWhenEverybodyIsQuietTheChoiceIsLeftAlone() {
        var picker = PrimaryMeterPicker()
        settle(&picker, trainer, watts: 200)
        XCTAssertEqual(picker.pick(current: trainer,
                                   eligible: [pedals, trainer],
                                   now: start.addingTimeInterval(600)),
                       trainer)
    }

    /// A meter waking up starts at what it says. Starting it at zero would have
    /// it spend its first ten seconds losing on an average it never claimed.
    func testAWakingMeterIsNotPenalisedForItsFirstReading() {
        var picker = PrimaryMeterPicker()
        settle(&picker, trainer, watts: 200)
        let now = start.addingTimeInterval(20)
        picker.observe(meterID: pedals, watts: 260, at: now)
        XCTAssertEqual(picker.smoothedWattsForTest(pedals), 260)
    }

    func testForgettingAMeterRemovesItFromTheRunning() {
        var picker = PrimaryMeterPicker()
        settle(&picker, trainer, watts: 200)
        settle(&picker, pedals, watts: 300)
        picker.forget(pedals)
        XCTAssertEqual(picker.pick(current: trainer,
                                   eligible: [pedals, trainer],
                                   now: start.addingTimeInterval(60)),
                       trainer)
    }
}

private extension PrimaryMeterPicker {
    func smoothedWattsForTest(_ id: UUID) -> Int? {
        readings[id].map { Int($0.smoothedWatts.rounded()) }
    }
}
