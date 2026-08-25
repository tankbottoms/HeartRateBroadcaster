#if DEBUG
import Foundation

/// A fabricated set of sensors, for screenshots only.
///
/// The simulator has no Bluetooth radio, so a screen showing a paired trainer
/// and a pair of pedals cannot be captured on one at all — and a photograph of
/// a real phone mid-ride cannot be retaken in twenty-five languages every time
/// a string changes. This feeds the registry and the central the readings a
/// real ride produced, so the screens are still the app's own: its layout, its
/// grouping, its choice of which source counts.
///
/// The numbers are the ones a KICKR CORE 2, a SRAM Red crank and a pair of
/// PowerTap P1s actually read against each other under load. Pedals read
/// highest because they are first in the drivetrain, the crank next, the
/// trainer last — which is why the app marks the pair and not the trainer.
///
/// Compiled out of Release entirely, and switched on only by `-demoMeters 1`,
/// which nothing but a UI test passes.
@MainActor
enum DemoMeters {

    /// Fixed so a relaunch shows the same meters in the same order rather than
    /// reshuffling the list between two screenshots of the same screen.
    private static let leftPedal = UUID(uuidString: "D0D0D0D0-0000-4000-8000-000000000001")!
    private static let rightPedal = UUID(uuidString: "D0D0D0D0-0000-4000-8000-000000000002")!
    private static let crank = UUID(uuidString: "D0D0D0D0-0000-4000-8000-000000000003")!
    private static let trainer = UUID(uuidString: "D0D0D0D0-0000-4000-8000-000000000004")!

    private static let meters: [PairedMeter] = [
        PairedMeter(id: leftPedal, name: "powertap P1.L", kind: .cyclingPower),
        PairedMeter(id: rightPedal, name: "powertap P1.R", kind: .cyclingPower),
        PairedMeter(id: crank, name: "SRAM Red", kind: .cyclingPower),
        PairedMeter(id: trainer, name: "KICKR CORE 2", kind: .fitnessMachine),
    ]

    /// Watts at a steady effort. The two pedals are one rider's two legs and are
    /// deliberately unequal — a real rider is — so the row that adds them up is
    /// showing arithmetic rather than a doubled number.
    private static let baseWatts: [UUID: Int] = [
        leftPedal: 112,
        rightPedal: 104,
        crank: 208,
        trainer: 201,
    ]

    private static var ticker: Timer?
    private static var tick = 0

    static func installIfRequested(registry: MeterRegistry, central: PowerMeterCentral) {
        guard UserDefaults.standard.bool(forKey: "demoMeters"), ticker == nil else { return }

        for meter in meters { registry.remember(meter) }
        central.acceptDemoConnections(meters.map(\.id))
        emit(into: central)

        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in emit(into: central) }
        }
    }

    /// One second of readings from every meter at once, delivered the way a real
    /// notification is — through the central, so the registry and the recorder
    /// see them by their own wiring rather than by a second path that only
    /// exists in a screenshot. The wobble is what makes the instantaneous figure
    /// and the average differ on screen, which is the difference the sensors
    /// screen is explaining.
    private static func emit(into central: PowerMeterCentral) {
        tick += 1
        let wobble = [0, 3, -2, 4, -3, 1][tick % 6]
        let now = Date()

        for meter in meters {
            guard let base = baseWatts[meter.id] else { continue }
            let sample = MeterSample(meterID: meter.id,
                                     meterName: meter.name,
                                     kind: meter.kind,
                                     watts: base + wobble,
                                     cadenceRPM: 88,
                                     at: now)
            central.acceptDemoSample(sample)
        }
    }
}
#endif
