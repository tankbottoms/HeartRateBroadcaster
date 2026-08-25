import XCTest

/// Grouping pedals is a name heuristic, and the cost of a wrong guess is a
/// rider's watts silently doubled or halved. So the cases here are mostly the
/// ones that must *not* group: names that end in a side letter by coincidence,
/// two lefts, a cadence sensor that happens to be called `Bike L`.
final class PowerSourceTests: XCTestCase {

    private func meter(_ name: String, _ kind: MeterKind = .cyclingPower) -> PairedMeter {
        PairedMeter(id: UUID(), name: name, kind: kind)
    }

    // MARK: - Reading a side off a name

    func testReadsDottedSideMarkers() {
        let left = PowerSource.pedalSide(of: "powertap P1.L")
        XCTAssertEqual(left?.base, "powertap p1")
        XCTAssertEqual(left?.side, .left)

        let right = PowerSource.pedalSide(of: "powertap P1.R")
        XCTAssertEqual(right?.base, "powertap p1")
        XCTAssertEqual(right?.side, .right)
    }

    func testReadsSpelledAndBracketedMarkers() {
        XCTAssertEqual(PowerSource.pedalSide(of: "Favero Assioma Left")?.side, .left)
        XCTAssertEqual(PowerSource.pedalSide(of: "Favero Assioma (right)")?.side, .right)
        XCTAssertEqual(PowerSource.pedalSide(of: "Garmin Rally-R")?.base, "garmin rally")
    }

    /// The reason the separator is required. `Assioma` ends in an `a`, but a
    /// name ending in a bare `l` or `r` is the real hazard, and there is at
    /// least one trainer per season named something like that.
    func testDoesNotReadASideOffAnOrdinaryName() {
        XCTAssertNil(PowerSource.pedalSide(of: "KICKR CORE 2"))
        XCTAssertNil(PowerSource.pedalSide(of: "SRAM Red"))
        XCTAssertNil(PowerSource.pedalSide(of: "Quarq DZero"))
        XCTAssertNil(PowerSource.pedalSide(of: "L"))
    }

    // MARK: - Grouping

    func testJoinsOppositePedalsIntoOneSource() {
        let left = meter("powertap P1.L")
        let right = meter("powertap P1.R")
        let sources = PowerSource.group([left, right])

        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].shape, .pedalPair(left: left.id, right: right.id))
        XCTAssertEqual(sources[0].id, left.id, "a pair is identified by its left pedal")
        XCTAssertEqual(sources[0].memberIDs, [left.id, right.id])
        XCTAssertEqual(sources[0].name, "powertap P1")
    }

    /// The pair stands where the first side stood, so a list does not reshuffle
    /// under the rider's finger when the second pedal wakes up.
    func testPairKeepsTheFirstSidesPlaceInTheList() {
        let left = meter("powertap P1.L")
        let trainer = meter("KICKR CORE 2", .fitnessMachine)
        let right = meter("powertap P1.R")
        let sources = PowerSource.group([left, trainer, right])

        XCTAssertEqual(sources.count, 2)
        XCTAssertTrue(sources[0].isPair)
        XCTAssertEqual(sources[1].name, "KICKR CORE 2")
    }

    func testDoesNotPairTwoOfTheSameSide() {
        let sources = PowerSource.group([meter("powertap P1.L"), meter("powertap P1.L")])
        XCTAssertEqual(sources.count, 2)
        XCTAssertFalse(sources.contains(where: \.isPair))
    }

    func testDoesNotPairAcrossDifferentBaseNames() {
        let sources = PowerSource.group([meter("powertap P1.L"), meter("Assioma.R")])
        XCTAssertEqual(sources.count, 2)
        XCTAssertFalse(sources.contains(where: \.isPair))
    }

    /// A speed-and-cadence sensor reports no watts, so joining one to a pedal
    /// would make a source whose total is half of itself.
    func testOnlyPowerMetersPair() {
        let sources = PowerSource.group([meter("Bike.L", .speedCadence),
                                         meter("Bike.R", .speedCadence)])
        XCTAssertEqual(sources.count, 2)
        XCTAssertFalse(sources.contains(where: \.isPair))
    }

    func testSingleMetersPassThroughUnchanged() {
        let trainer = meter("KICKR CORE 2", .fitnessMachine)
        let crank = meter("SRAM Red")
        let sources = PowerSource.group([trainer, crank])

        XCTAssertEqual(sources.map(\.id), [trainer.id, crank.id])
        XCTAssertEqual(sources.map(\.shape), [.single, .single])
        XCTAssertTrue(sources.allSatisfy(\.measuresPower))
    }
}
