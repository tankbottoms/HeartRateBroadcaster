import CoreBluetooth
import Foundation
import Observation

/// One notification from one meter, already parsed.
///
/// Deliberately not a class and deliberately not the meter's own state: three
/// meters send at their own rates, and the recorder wants each arrival stamped
/// with the meter it came from rather than a single mutable "current power"
/// that whichever meter notified last would win.
struct MeterSample: Sendable {
    let meterID: UUID
    let meterName: String
    let kind: MeterKind
    let watts: Int?
    let cadenceRPM: Double?
    let at: Date
}

/// The Bluetooth *central* half of the app: it finds power meters, cadence
/// sensors and trainers, subscribes to their measurement characteristics, and
/// hands each notification on as a `MeterSample`.
///
/// `BLEBroadcaster` runs a `CBPeripheralManager` at the same time. Both roles
/// on one radio is ordinary; they share nothing but the hardware. The state
/// vocabulary here mirrors the broadcaster's on purpose, so a powered-off radio
/// says the same thing in both status rows instead of two different sentences
/// about the same switch.
@Observable
@MainActor
final class PowerMeterCentral: NSObject {

    enum Availability: String {
        case unknown
        case unsupported
        case unauthorized
        case off
        case ready
    }

    private(set) var availability: Availability = .unknown
    private(set) var isScanning = false

    /// Meters seen during this scan. Includes ones already paired — the
    /// settings screen shows both, distinguished by the registry.
    private(set) var discovered: [PairedMeter] = []
    private(set) var connected: Set<UUID> = []
    private(set) var latest: [UUID: MeterSample] = [:]

    /// Called on the main actor for every parsed notification.
    var onSample: ((MeterSample) -> Void)?

    private let registry: MeterRegistry
    private var manager: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var kinds: [UUID: MeterKind] = [:]
    private var crankTrackers: [UUID: CadenceTracker] = [:]

    private static let services: [CBUUID] = MeterKind.allCases.map { CBUUID(string: $0.serviceUUIDString) }

    init(registry: MeterRegistry) {
        self.registry = registry
        super.init()
        // `showPowerAlert: false` — the app already explains a powered-off
        // radio in its own status row, and a system alert on launch for a
        // feature the user may not be using is noise.
        manager = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    // MARK: - Scanning

    func startScanning() {
        guard availability == .ready else { return }
        discovered.removeAll()
        // Duplicate keys off: a meter only needs to be discovered once, and
        // leaving them on turns a busy garage into a constant stream of
        // callbacks for peripherals already in the list.
        manager.scanForPeripherals(withServices: Self.services,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
    }

    func stopScanning() {
        guard isScanning else { return }
        manager.stopScan()
        isScanning = false
    }

    /// Reconnects everything in the registry without scanning. CoreBluetooth
    /// keeps its own record of peripherals this app has seen, so a known meter
    /// can be retrieved by identifier and connected the moment it wakes.
    func reconnectKnownMeters() {
        guard availability == .ready, !registry.paired.isEmpty else { return }
        let known = manager.retrievePeripherals(withIdentifiers: registry.paired.map(\.id))
        for peripheral in known {
            peripherals[peripheral.identifier] = peripheral
            kinds[peripheral.identifier] = registry.paired.first { $0.id == peripheral.identifier }?.kind
            manager.connect(peripheral, options: nil)
        }
    }

    func connect(_ id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        manager.connect(peripheral, options: nil)
    }

    func disconnect(_ id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        manager.cancelPeripheralConnection(peripheral)
    }

    // MARK: - State

    private func mapped(_ cbState: CBManagerState) -> Availability {
        switch cbState {
        case .unsupported:  return .unsupported
        case .unauthorized: return .unauthorized
        case .poweredOff:   return .off
        case .poweredOn:    return .ready
        default:            return .unknown
        }
    }

    fileprivate func ingest(_ sample: MeterSample) {
        latest[sample.meterID] = sample
        onSample?(sample)
    }

#if DEBUG
    /// The two doors ``DemoMeters`` needs, and the reason they are here rather
    /// than in that file: `ingest` is `fileprivate`, and `connected` and
    /// `availability` are `private(set)` — deliberately, because in a shipping
    /// build only CoreBluetooth may write them. Compiled out of Release.

    /// Set once the fabricated meters are in place, and never cleared. A
    /// simulator's `CBCentralManager` reaches `.unsupported` a moment after
    /// launch, and the delegate below would then drop every connection and put
    /// the red line back — undoing this from a callback nobody called.
    private(set) var demoLatched = false

    func acceptDemoConnections(_ ids: [UUID]) {
        // A simulator's `CBCentralManager` never reaches `poweredOn`, so without
        // this the screen would carry the red "cannot connect to Bluetooth
        // sensors" line under a list of connected sensors.
        demoLatched = true
        availability = .ready
        connected.formUnion(ids)
    }

    func acceptDemoSample(_ sample: MeterSample) { ingest(sample) }
#endif
}

// MARK: - CBCentralManagerDelegate

extension PowerMeterCentral: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
#if DEBUG
            if demoLatched { return }
#endif
            availability = mapped(state)
            if availability == .ready {
                reconnectKnownMeters()
            } else {
                connected.removeAll()
                isScanning = false
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        // A trainer advertises several services; the most capable one wins,
        // because a Kickr that reports Indoor Bike Data is more useful read as
        // a trainer than as a wheel-speed sensor.
        let kind: MeterKind? = MeterKind.allCases.first { candidate in
            advertised.contains(CBUUID(string: candidate.serviceUUIDString))
        }
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        Task { @MainActor in
            guard let kind else { return }
            peripherals[id] = peripheral
            kinds[id] = kind
            let entry = PairedMeter(id: id,
                                    name: name ?? String(localized: "Unnamed meter",
                                                          comment: "Fallback title for a Bluetooth power meter that advertises no name"),
                                    kind: kind)
            if let index = discovered.firstIndex(where: { $0.id == id }) {
                discovered[index] = entry
            } else {
                discovered.append(entry)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        Task { @MainActor in
            connected.insert(id)
            crankTrackers[id] = CadenceTracker()
            peripheral.delegate = self
            peripheral.discoverServices(Self.services)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        let id = peripheral.identifier
        Task { @MainActor in
            connected.remove(id)
            crankTrackers[id]?.reset()
            // A meter that sleeps between rides disconnects constantly. Asking
            // to connect again is free and means the next pedal stroke wakes
            // the link without the user opening anything.
            if registry.paired.contains(where: { $0.id == id }) {
                central.connect(peripheral, options: nil)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension PowerMeterCentral: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            let wanted = MeterKind.allCases
                .filter { CBUUID(string: $0.serviceUUIDString) == service.uuid }
                .map { CBUUID(string: $0.measurementUUIDString) }
            peripheral.discoverCharacteristics(wanted, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        let id = peripheral.identifier
        let uuid = characteristic.uuid.uuidString.uppercased()
        let name = peripheral.name
        let now = Date()

        Task { @MainActor in
            guard let kind = kinds[id] else { return }
            let label = name ?? registry.paired.first { $0.id == id }?.name ?? "—"
            var watts: Int?
            var cadence: Double?

            switch uuid {
            case MeterKind.cyclingPower.measurementUUIDString:
                guard let m = CyclingPowerMeasurement(bytes) else { return }
                watts = m.watts
                if let revs = m.cumulativeCrankRevolutions, let time = m.lastCrankEventTime {
                    var tracker = crankTrackers[id] ?? CadenceTracker()
                    tracker.submit(revolutions: revs, eventTime: time)
                    crankTrackers[id] = tracker
                    cadence = tracker.rpm
                }
            case MeterKind.speedCadence.measurementUUIDString:
                guard let m = CSCMeasurement(bytes) else { return }
                if let revs = m.cumulativeCrankRevolutions, let time = m.lastCrankEventTime {
                    var tracker = crankTrackers[id] ?? CadenceTracker()
                    tracker.submit(revolutions: revs, eventTime: time)
                    crankTrackers[id] = tracker
                    cadence = tracker.rpm
                }
            case MeterKind.fitnessMachine.measurementUUIDString:
                guard let m = IndoorBikeData(bytes) else { return }
                watts = m.watts
                cadence = m.cadenceRPM
            default:
                return
            }

            ingest(MeterSample(meterID: id, meterName: label, kind: kind,
                               watts: watts, cadenceRPM: cadence, at: now))
        }
    }
}
