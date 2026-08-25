import XCTest

/// The profile is the only place a wrong number silently rescales every kcal
/// figure the app will ever produce, so the conversions and the basal rate are
/// pinned against hand-computed values.
final class BodyProfileTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_780_000_000) // 2026-06-08

    private func profile(sex: BiologicalSex = .male,
                         kg: Double = 80,
                         cm: Double = 180,
                         born: TimeInterval = 0) -> BodyProfile {
        BodyProfile(massKilograms: kg,
                    heightCentimetres: cm,
                    dateOfBirth: Date(timeIntervalSince1970: born),
                    sex: sex)
    }

    func testAgeInWholeYears() {
        // Born 1970-01-01, reference 2026-06-08: 56 years and change.
        let age = profile().age(on: reference)
        XCTAssertEqual(age ?? 0, 56.4, accuracy: 0.2)
    }

    func testAgeIsNilWithoutDateOfBirth() {
        let p = BodyProfile(massKilograms: 80, heightCentimetres: 180,
                            dateOfBirth: nil, sex: .male)
        XCTAssertNil(p.age(on: reference))
        XCTAssertNil(p.basalRateKcalPerDay(on: reference))
        XCTAssertFalse(p.isComplete)
    }

    /// Mifflin-St Jeor, male: 10*80 + 6.25*180 - 5*age + 5.
    func testMaleBasalRate() {
        let p = profile()
        let age = p.age(on: reference) ?? 0
        let expected = 10 * 80 + 6.25 * 180 - 5 * age + 5
        XCTAssertEqual(p.basalRateKcalPerDay(on: reference) ?? 0, expected, accuracy: 0.001)
    }

    /// Female: the same expression with -161 instead of +5.
    func testFemaleBasalRate() {
        let p = profile(sex: .female, kg: 62, cm: 168)
        let age = p.age(on: reference) ?? 0
        let expected = 10 * 62 + 6.25 * 168 - 5 * age - 161
        XCTAssertEqual(p.basalRateKcalPerDay(on: reference) ?? 0, expected, accuracy: 0.001)
    }

    /// Unspecified averages the two constants rather than picking one, which is
    /// the only honest option when Health reports "other" or "not set".
    func testUnspecifiedAveragesTheConstants() {
        let p = profile(sex: .unspecified)
        let male = profile(sex: .male).basalRateKcalPerDay(on: reference) ?? 0
        let female = profile(sex: .female).basalRateKcalPerDay(on: reference) ?? 0
        XCTAssertEqual(p.basalRateKcalPerDay(on: reference) ?? 0,
                       (male + female) / 2, accuracy: 0.001)
    }

    func testCompletenessRequiresPlausibleMass() {
        XCTAssertTrue(profile().isComplete)
        XCTAssertFalse(profile(kg: 0).isComplete)
        XCTAssertFalse(profile(kg: 700).isComplete)
    }

    func testUnsetIsNotComplete() {
        XCTAssertFalse(BodyProfile.unset.isComplete)
    }

    func testMassConversionRoundTrips() {
        XCTAssertEqual(BodyProfile.kilograms(fromPounds: 176.37), 80, accuracy: 0.01)
        XCTAssertEqual(BodyProfile.pounds(fromKilograms: 80), 176.37, accuracy: 0.01)
    }

    func testHeightConversionRoundTrips() {
        XCTAssertEqual(BodyProfile.centimetres(fromInches: 70.866), 180, accuracy: 0.01)
        XCTAssertEqual(BodyProfile.inches(fromCentimetres: 180), 70.866, accuracy: 0.01)
    }

    func testCodableRoundTrip() throws {
        let p = profile(sex: .female)
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(BodyProfile.self, from: data), p)
    }
}
