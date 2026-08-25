import Foundation

/// The three GATT services this app subscribes to, and the one characteristic
/// on each that carries measurements.
///
/// The UUIDs are strings rather than `CBUUID` so this file — and the record
/// that names meters — stays free of CoreBluetooth and testable. The central
/// converts at the boundary.
enum MeterKind: String, Codable, CaseIterable, Sendable {
    case cyclingPower
    case speedCadence
    case fitnessMachine

    var serviceUUIDString: String {
        switch self {
        case .cyclingPower:   return "1818"
        case .speedCadence:   return "1816"
        case .fitnessMachine: return "1826"
        }
    }

    var measurementUUIDString: String {
        switch self {
        case .cyclingPower:   return "2A63"
        case .speedCadence:   return "2A5B"
        case .fitnessMachine: return "2AD2"
        }
    }

    /// Whether this kind can report watts. A speed-and-cadence sensor cannot,
    /// so it is never offered as the meter that drives the energy figure.
    var measuresPower: Bool {
        switch self {
        case .cyclingPower, .fitnessMachine: return true
        case .speedCadence: return false
        }
    }
}

/// A meter the user has chosen to keep. The identifier is CoreBluetooth's
/// per-app peripheral UUID, which is stable across launches for the same
/// device and is how a known meter is reconnected without scanning.
struct PairedMeter: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var kind: MeterKind
}
