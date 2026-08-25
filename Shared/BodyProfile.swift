import Foundation

/// Sex as the energy equations use it, which is not the same question Health
/// asks. Both published equations were fitted on two groups; `unspecified`
/// averages them rather than assigning someone to a group they did not choose.
enum BiologicalSex: String, Codable, CaseIterable, Sendable {
    case male
    case female
    case unspecified
}

/// The four numbers energy expenditure needs.
///
/// Held in SI regardless of what the settings screen displays, so no formula
/// ever has to ask which unit it was handed. Pounds and inches are converted at
/// the text field, once.
struct BodyProfile: Codable, Equatable, Sendable {

    var massKilograms: Double
    var heightCentimetres: Double
    var dateOfBirth: Date?
    var sex: BiologicalSex

    static let unset = BodyProfile(massKilograms: 0,
                                   heightCentimetres: 0,
                                   dateOfBirth: nil,
                                   sex: .unspecified)

    /// Fractional years. The heart-rate model's age coefficient is small enough
    /// that whole years would do, but a fraction costs nothing and avoids a
    /// step change in the number on a birthday.
    func age(on date: Date) -> Double? {
        guard let dateOfBirth, date > dateOfBirth else { return nil }
        return date.timeIntervalSince(dateOfBirth) / (365.2425 * 86_400)
    }

    /// Mifflin-St Jeor resting metabolic rate, kcal/day. This is the only place
    /// height is used, and it exists so the resting share can be subtracted
    /// before anything is written to Health.
    func basalRateKcalPerDay(on date: Date) -> Double? {
        guard let age = age(on: date), isComplete else { return nil }
        let common = 10 * massKilograms + 6.25 * heightCentimetres - 5 * age
        switch sex {
        case .male: return common + 5
        case .female: return common - 161
        case .unspecified: return common + (5 - 161) / 2
        }
    }

    /// Mass and a date of birth are load-bearing; height only shifts the
    /// resting subtraction, so its absence degrades the figure rather than
    /// invalidating it.
    var isComplete: Bool {
        dateOfBirth != nil && massKilograms > 20 && massKilograms < 400
    }

    // MARK: - Units

    static func kilograms(fromPounds pounds: Double) -> Double { pounds * 0.45359237 }
    static func pounds(fromKilograms kilograms: Double) -> Double { kilograms / 0.45359237 }
    static func centimetres(fromInches inches: Double) -> Double { inches * 2.54 }
    static func inches(fromCentimetres centimetres: Double) -> Double { centimetres / 2.54 }
}
