import XCTest

/// The efficiency divisor is a choice, not a fact, so it is asserted here at
/// the value the design fixed. If someone changes it, this test is where they
/// find out how much every historical figure moves.
final class EnergyModelTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_780_000_000)

    private var subject: BodyProfile {
        BodyProfile(massKilograms: 80, heightCentimetres: 180,
                    dateOfBirth: Date(timeIntervalSince1970: 0), sex: .male)
    }

    func testEfficiencyIsTwentyFourPercent() {
        XCTAssertEqual(EnergyModel.grossEfficiency, 0.24, accuracy: 0.0001)
    }

    /// 200 W for 3600 s is 720 kJ of work. At 24% that is about 717 kcal, which
    /// is where "a kilojoule costs about a kilocalorie" comes from.
    func testWorkToKilocalories() {
        let j = EnergyModel.joules(watts: 200, seconds: 3600)
        XCTAssertEqual(j, 720_000, accuracy: 0.001)
        XCTAssertEqual(EnergyModel.kilocalories(joules: j), 717.0, accuracy: 1.0)
    }

    func testZeroWattsIsZeroJoules() {
        XCTAssertEqual(EnergyModel.joules(watts: 0, seconds: 10), 0, accuracy: 0.0001)
    }

    /// Keytel male: (-55.0969 + 0.6309*HR + 0.1988*kg + 0.2017*age) / 4.184.
    func testKeytelMale() {
        let age = subject.age(on: reference) ?? 0
        let expected = (-55.0969 + 0.6309 * 150 + 0.1988 * 80 + 0.2017 * age) / 4.184
        let actual = EnergyModel.kilocaloriesPerMinute(heartRate: 150,
                                                       profile: subject, on: reference)
        XCTAssertEqual(actual ?? 0, expected, accuracy: 0.0001)
    }

    /// Keytel female: note the mass coefficient is negative in the published
    /// equation. That is not a transcription error and the test records it.
    func testKeytelFemale() {
        var p = subject
        p.sex = .female
        let age = p.age(on: reference) ?? 0
        let expected = (-20.4022 + 0.4472 * 150 - 0.1263 * 80 + 0.0740 * age) / 4.184
        XCTAssertEqual(EnergyModel.kilocaloriesPerMinute(heartRate: 150, profile: p, on: reference) ?? 0,
                       expected, accuracy: 0.0001)
    }

    func testUnspecifiedAveragesBothModels() {
        var male = subject; male.sex = .male
        var female = subject; female.sex = .female
        var other = subject; other.sex = .unspecified
        let m = EnergyModel.kilocaloriesPerMinute(heartRate: 150, profile: male, on: reference) ?? 0
        let f = EnergyModel.kilocaloriesPerMinute(heartRate: 150, profile: female, on: reference) ?? 0
        let o = EnergyModel.kilocaloriesPerMinute(heartRate: 150, profile: other, on: reference) ?? 0
        XCTAssertEqual(o, (m + f) / 2, accuracy: 0.0001)
    }

    /// Far enough below a resting rate the regression goes negative. Energy
    /// expenditure does not. For this subject the line crosses zero at about
    /// 44 bpm, so 30 is unambiguously on the far side of it.
    func testLowHeartRateClampsAtZero() {
        let v = EnergyModel.kilocaloriesPerMinute(heartRate: 30, profile: subject, on: reference)
        XCTAssertEqual(v ?? -1, 0, accuracy: 0.0001)
        // The clamp must hold everywhere below the crossing, not just at the
        // one value above.
        for hr in 20...44 {
            XCTAssertGreaterThanOrEqual(
                EnergyModel.kilocaloriesPerMinute(heartRate: hr, profile: subject, on: reference) ?? 0,
                0)
        }
    }

    func testIncompleteProfileYieldsNoHeartRateEstimate() {
        XCTAssertNil(EnergyModel.kilocaloriesPerMinute(heartRate: 150,
                                                        profile: .unset, on: reference))
    }

    /// An hour of basal rate is a day's rate divided by 24.
    func testRestingIsProRataFromBasalRate() {
        let daily = subject.basalRateKcalPerDay(on: reference) ?? 0
        XCTAssertEqual(EnergyModel.restingKilocalories(profile: subject, seconds: 3600, on: reference),
                       daily / 24, accuracy: 0.001)
    }

    func testActiveSubtractsRestingAndClamps() {
        let resting = EnergyModel.restingKilocalories(profile: subject, seconds: 3600, on: reference)
        XCTAssertEqual(EnergyModel.active(total: 717, profile: subject, seconds: 3600, on: reference),
                       717 - resting, accuracy: 0.001)
        XCTAssertEqual(EnergyModel.active(total: 5, profile: subject, seconds: 3600, on: reference),
                       0, accuracy: 0.001)
    }

    /// Without a profile there is no resting rate to subtract, so the total is
    /// reported unchanged rather than silently reduced by a guess.
    func testActiveWithoutProfileIsTheTotal() {
        XCTAssertEqual(EnergyModel.active(total: 400, profile: .unset, seconds: 3600, on: reference),
                       400, accuracy: 0.001)
    }
}
