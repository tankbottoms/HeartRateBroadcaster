import Foundation

/// Which model produced a session's figure. Recorded on the session and shown
/// on the summary, because "700 kcal" means different things depending on
/// whether a meter measured it or a regression estimated it.
enum EnergySource: String, Codable, Sendable {
    case power
    case heartRate
    case none
}

/// Energy arithmetic. No state, no frameworks, every constant named.
enum EnergyModel {

    /// Gross mechanical efficiency for trained cycling. The measured range runs
    /// roughly 0.20 to 0.25; 0.24 sits inside it and is what makes the familiar
    /// shorthand — a kilojoule of work costs about a kilocalorie — come out.
    /// Named rather than folded into a magic multiplier so it can be argued
    /// with.
    static let grossEfficiency: Double = 0.24

    static let joulesPerKilocalorie: Double = 4184

    static func joules(watts: Double, seconds: Double) -> Double {
        watts * seconds
    }

    /// Metabolic cost of mechanical work.
    static func kilocalories(joules: Double) -> Double {
        joules / (grossEfficiency * joulesPerKilocalorie)
    }

    /// Keytel et al. (2005), kJ/min in the paper, converted to kcal/min here.
    /// Returns `nil` rather than zero when the profile cannot support it, so a
    /// missing profile is visibly missing instead of quietly reading as no
    /// effort.
    static func kilocaloriesPerMinute(heartRate: Int,
                                      profile: BodyProfile,
                                      on date: Date) -> Double? {
        guard profile.isComplete, let age = profile.age(on: date) else { return nil }
        let hr = Double(heartRate)
        let kg = profile.massKilograms

        func male() -> Double {
            (-55.0969 + 0.6309 * hr + 0.1988 * kg + 0.2017 * age) / 4.184
        }
        func female() -> Double {
            // The mass coefficient is negative in the published equation. That
            // is the paper's fit, not a transcription slip.
            (-20.4022 + 0.4472 * hr - 0.1263 * kg + 0.0740 * age) / 4.184
        }

        let value: Double
        switch profile.sex {
        case .male: value = male()
        case .female: value = female()
        case .unspecified: value = (male() + female()) / 2
        }
        // The regression is linear and crosses zero somewhere around a resting
        // heart rate. Below that it predicts negative expenditure, which is not
        // a thing.
        return max(0, value)
    }

    /// The resting share of the elapsed time, from Mifflin-St Jeor.
    static func restingKilocalories(profile: BodyProfile,
                                    seconds: Double,
                                    on date: Date) -> Double {
        guard let daily = profile.basalRateKcalPerDay(on: date) else { return 0 }
        return daily * seconds / 86_400
    }

    /// What Health means by `activeEnergyBurned`: everything above resting.
    /// Writing the gross figure instead would double-count against the move
    /// ring, which already contains the resting portion.
    static func active(total: Double,
                       profile: BodyProfile,
                       seconds: Double,
                       on date: Date) -> Double {
        max(0, total - restingKilocalories(profile: profile, seconds: seconds, on: date))
    }
}
