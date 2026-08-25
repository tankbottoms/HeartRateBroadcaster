import Foundation

/// The sports offered at Start. Deliberately three: the sport fixes the
/// HealthKit activity type, and a longer list would be a picker rather than a
/// decision.
enum WorkoutSport: String, Codable, CaseIterable, Identifiable, Sendable {
    case cycling
    case running
    case swimming

    var id: String { rawValue }

    /// The SF Symbol the phone and the watch both draw for this sport. Kept
    /// here rather than in either view so the two screens cannot drift apart.
    var glyph: String {
        switch self {
        case .cycling: return "figure.outdoor.cycle"
        case .running: return "figure.run"
        case .swimming: return "figure.pool.swim"
        }
    }

}

#if canImport(SwiftUI)
import SwiftUI

extension WorkoutSport {
    /// Short enough for a watch cell and for a metrics strip that already holds
    /// three numbers. Written as literals rather than assembled from
    /// `rawValue`, because a `LocalizedStringKey` built from a runtime string
    /// is invisible to string extraction — the words would ship untranslated.
    var label: LocalizedStringKey {
        switch self {
        case .cycling: "Cycle"
        case .running: "Run"
        case .swimming: "Swim"
        }
    }
}
#endif

#if canImport(HealthKit)
import HealthKit

extension WorkoutSport {
    var activityType: HKWorkoutActivityType {
        switch self {
        case .cycling: .cycling
        case .running: .running
        case .swimming: .swimming
        }
    }

    /// Reads back the sport from a configuration the phone sent over, so a ride
    /// the phone launched on the watch is labelled the same on both wrists and
    /// in Health. Anything outside the three the app offers becomes cycling —
    /// the phone cannot ask for a fourth, so this is the safe default rather
    /// than a case worth surfacing.
    init(activityType: HKWorkoutActivityType) {
        switch activityType {
        case .running: self = .running
        case .swimming: self = .swimming
        default: self = .cycling
        }
    }

    /// Only cycling claims to be indoor. A ride on a trainer is the common case
    /// here and an indoor session does not ask for location; a run or a swim
    /// declared indoor would mislabel almost every one of them.
    var locationType: HKWorkoutSessionLocationType {
        self == .cycling ? .indoor : .unknown
    }
}
#endif

/// A stretch of the session where nothing was being measured — the meter went
/// quiet or the link dropped. Excluded from the integral and named on the
/// summary, so a break reads as a break instead of inflating the total.
struct SignalGap: Codable, Equatable, Sendable {
    let start: Date
    let end: Date
    /// Which meter fell silent, when it was one meter rather than the link.
    let meterName: String?

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// One meter's contribution, kept even for meters that were not primary. Three
/// meters on one bike measure at three points in the drivetrain, and the offset
/// between them is only visible if all three are recorded.
struct MeterTotals: Codable, Equatable, Sendable {
    let meterID: UUID
    let meterName: String
    let kind: MeterKind
    let averageWatts: Double
    let maximumWatts: Int
    let kilojoules: Double
    let sampleCount: Int
}

/// A finished session. Everything the history, the detail screen and the crash
/// recovery need, and nothing that requires HealthKit to interpret.
struct WorkoutRecord: Codable, Equatable, Identifiable, Sendable {

    let id: UUID
    let sport: WorkoutSport
    let start: Date
    let end: Date
    let gaps: [SignalGap]

    let totalKilocalories: Double
    /// What was written to Health: total less the resting share.
    let activeKilocalories: Double
    let energySource: EnergySource

    let primaryMeterID: UUID?
    let meterTotals: [MeterTotals]

    let averageHeartRate: Int?
    let maximumHeartRate: Int?
    let averageCadence: Double?
    let averagePower: Double?
    let maximumPower: Int?
    let totalKilojoules: Double

    /// False when Health refused the write. Surfaced once on the summary; the
    /// session is still in the history either way.
    let savedToHealth: Bool
    /// False when the energy figure was produced without a full body profile,
    /// which is worth saying next to the number rather than burying.
    let profileWasComplete: Bool

    var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Seconds excluded because a meter went quiet. Reported in the summary so
    /// a short-looking ride explains itself.
    var gapDuration: TimeInterval { gaps.reduce(0) { $0 + $1.duration } }

    /// Wall time less the gaps. This is the denominator for averages and the
    /// span the integral actually covers.
    var recordedDuration: TimeInterval {
        max(0, duration - gapDuration)
    }
}
