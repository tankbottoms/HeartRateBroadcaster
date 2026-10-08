import FTMS

/// The app's four-value view of a single FTMS `0x2AD2` notification.
/// Wire layout and bounds checking belong to the FTMS codec; Bluetooth and
/// source selection remain with PowerMeterCentral.
struct IndoorBikeData: Equatable {

    /// km/h.
    let speedKPH: Double?
    /// rpm.
    let cadenceRPM: Double?
    /// Watts, signed.
    let watts: Int?
    let heartRate: Int?

    init?(_ data: [UInt8]) {
        // Preserve this app's existing two-byte resistance layout explicitly.
        // The library default is a different layout; never infer it from length.
        guard let measurement = try? decodeMeasurement(
            .indoorBike,
            bytes: data,
            options: .init(resistance: .sint16Tenths)
        ), !measurement.diagnostics.truncated else { return nil }

        // Keep the existing units and optional-value contract. Reserved flags
        // and trailing bytes remain tolerated, as they were by the old parser.
        speedKPH = measurement.values[.speed].map { Double($0) / 100.0 }
        cadenceRPM = measurement.values[.cadence].map { Double($0) / 2.0 }
        watts = measurement.values[.power].map { Int($0) }
        heartRate = measurement.values[.heartRate].map { Int($0) }
    }
}
