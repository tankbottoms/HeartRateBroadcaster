import Foundation
import CoreBluetooth
import Observation

/// Advertises the iPhone as a standard BLE heart rate monitor.
///
/// **The constraint that shapes this whole class.** A backgrounded iOS app has
/// its advertised service UUIDs moved into the "overflow" area of the packet,
/// which only other iOS devices explicitly scanning for that exact UUID can
/// read. A Garmin, a Wahoo, or MyWhoosh scanning generically will never see it.
/// An *already established* GATT connection does survive backgrounding intact.
///
/// So the app must be foreground to be **discovered**, and only then can the
/// phone be locked. Everything about the UI state machine follows from that.
@Observable
@MainActor
final class BLEBroadcaster: NSObject {

    enum State: Equatable {
        case idle
        case poweredOff
        case unauthorized
        case unsupported
        case advertising
        case connected(count: Int)
        case failed(String)
    }

    /// One entry per central currently subscribed to the measurement
    /// characteristic, keyed by Core Bluetooth's identifier.
    ///
    /// This used to be an `Int` bumped in `didSubscribeTo` and decremented in
    /// `didUnsubscribeFrom`, which drifts: a central that drops off without a
    /// clean unsubscribe — or resubscribes after a reconnect, which MyWhoosh
    /// does — leaves the count permanently wrong. Identity is the only thing
    /// that stays accurate.
    private(set) var subscribers: [UUID: Subscriber] = [:]

    struct Subscriber: Identifiable, Equatable {
        let id: UUID
        /// Maximum bytes the central will accept in one notification.
        let maximumUpdateValueLength: Int
        var framesSent: Int = 0
    }

    private(set) var state: State = .idle
    private(set) var framesSent: Int = 0
    private(set) var lastFrameHex: String = "--"
    private(set) var lastFrameAt: Date?

    var subscriberCount: Int { subscribers.count }

    /// Frames per second over a rolling window. `framesSent` alone cannot tell
    /// you whether the stream is *currently* alive — a counter frozen at 4,120
    /// looks identical to one still climbing unless you sit and watch it.
    ///
    /// Once measured this is never zeroed. A field that blanks the moment the
    /// stream pauses destroys the one number you want to look at when
    /// diagnosing why it paused; "Last sent" carries the freshness instead.
    private(set) var frameRate: Double = 0

    /// Send timestamps inside the rate window, oldest first.
    ///
    /// A rolling buffer rather than a count-and-reset window: the previous
    /// version only produced a new figure once every three seconds, so the
    /// field sat visibly unchanged long enough to look broken.
    private var recentSends: [Date] = []
    private static let rateWindow: TimeInterval = 5

    /// False until a real heart rate has been handed to `update(bpm:)`.
    /// A head unit connecting before then must not be fed a fabricated 0 —
    /// it would display a bogus reading instead of "no sensor data".
    private(set) var hasValue = false

    /// Advertised name. The whole advertising packet is 31 bytes, so keep this
    /// short or head units will show it truncated.
    var advertisedName: String = AppSettings.defaultName {
        didSet { if isAdvertising { restartAdvertising() } }
    }

    private var manager: CBPeripheralManager?
    private var measurement: CBMutableCharacteristic?
    private var service: CBMutableService?
    private var serviceAdded = false
    private var isAdvertising = false
    private var wantsToAdvertise = false

    /// Last encoded frame, replayed to reads and re-sent when the transmit
    /// queue drains.
    private var latestFrame: Data = HeartRateFrame.encode(bpm: 0)
    private var hasPendingFrame = false

    /// A real heart rate strap notifies at roughly 1 Hz whether or not the
    /// reading changed. Notifying only on change — as this class first did —
    /// leaves the characteristic silent between samples, and head units treat a
    /// silent notify stream as a dead sensor: MyWhoosh and Garmin both show
    /// "--" and eventually drop the connection.
    private var keepalive: Timer?
    private static let keepaliveInterval: TimeInterval = 1.0

    // MARK: - Control

    func prepare() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(
            delegate: self,
            queue: nil,          // nil == main queue
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: "xyz.atsignhandle.hrb.peripheral"]
        )
    }

    func start() {
        wantsToAdvertise = true
        prepare()
        guard let manager, manager.state == .poweredOn else {
            // `peripheralManagerDidUpdateState` will pick this up.
            return
        }
        if serviceAdded {
            restartAdvertising()
        } else {
            addServiceIfNeeded()
        }
    }

    func stop() {
        wantsToAdvertise = false
        manager?.stopAdvertising()
        isAdvertising = false
        subscribers.removeAll()
        stopKeepalive()
        state = manager == nil ? .idle : mapped(manager!.state) ?? .idle
    }

    /// Push a new heart rate to every subscribed central.
    func update(bpm: Int) {
        latestFrame = HeartRateFrame.encode(bpm: bpm)
        lastFrameHex = latestFrame.map { String(format: "%02X", $0) }.joined(separator: " ")
        hasValue = true
        sendLatest()
        startKeepaliveIfNeeded()
    }

    /// The source went away. Stop claiming a heart rate we no longer have —
    /// the head unit should see the stream stop rather than a frozen number.
    func clearValue() {
        hasValue = false
        stopKeepalive()
        // `lastFrameHex` deliberately survives. It is a diagnostic — "what did
        // we last put on the wire" — and blanking it to "--" the instant the
        // stream pauses removes the evidence exactly when you go looking for
        // it. "Last sent" already reports how long ago that was.
    }

    // MARK: - Internals

    private func addServiceIfNeeded() {
        guard let manager, !serviceAdded else { return }

        // `value` MUST be nil here. Core Bluetooth requires a characteristic
        // constructed with a static value to be read-only; pairing one with
        // `.notify` throws at `add(service:)`. Reads are served live from
        // `didReceiveRead` instead.
        let measurement = CBMutableCharacteristic(
            type: CBUUID(string: HeartRateFrame.UUIDString.measurement),
            properties: [.notify, .read],
            value: nil,
            permissions: [.readable]
        )

        let bodyLocation = CBMutableCharacteristic(
            type: CBUUID(string: HeartRateFrame.UUIDString.bodySensorLocation),
            properties: [.read],
            value: HeartRateFrame.bodySensorLocationWrist,
            permissions: [.readable]
        )

        let service = CBMutableService(
            type: CBUUID(string: HeartRateFrame.UUIDString.heartRateService),
            primary: true
        )
        service.characteristics = [measurement, bodyLocation]

        self.measurement = measurement
        self.service = service
        manager.add(service)
    }

    private func restartAdvertising() {
        guard let manager, manager.state == .poweredOn, serviceAdded else { return }
        manager.stopAdvertising()
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: HeartRateFrame.UUIDString.heartRateService)],
            CBAdvertisementDataLocalNameKey: String(advertisedName.prefix(10))
        ])
        isAdvertising = true
        state = subscriberCount > 0 ? .connected(count: subscriberCount) : .advertising
    }

    private func startKeepaliveIfNeeded() {
        guard keepalive == nil, subscriberCount > 0, hasValue else { return }
        let timer = Timer(timeInterval: Self.keepaliveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendLatest() }
        }
        // `.common` — a plain `scheduledTimer` runs in `.default` mode only and
        // stops firing the moment the user scrolls the app, which looks exactly
        // like a dead broadcast.
        RunLoop.main.add(timer, forMode: .common)
        keepalive = timer
    }

    private func stopKeepalive() {
        keepalive?.invalidate()
        keepalive = nil
        resetRate()
    }

    private func sendLatest() {
        guard let manager, let measurement, subscriberCount > 0, hasValue else { return }
        let ok = manager.updateValue(latestFrame, for: measurement, onSubscribedCentrals: nil)
        if ok {
            framesSent += 1
            let sentAt = Date()
            lastFrameAt = sentAt
            noteRate(at: sentAt)
            // `onSubscribedCentrals: nil` fans the frame out to everyone, so
            // every known subscriber got it.
            for key in subscribers.keys { subscribers[key]?.framesSent += 1 }
            hasPendingFrame = false
        } else {
            // Transmit queue is full. Core Bluetooth will call
            // `peripheralManagerIsReadyToUpdateSubscribers` when it drains.
            hasPendingFrame = true
        }
    }

    private func noteRate(at now: Date) {
        recentSends.append(now)
        let cutoff = now.addingTimeInterval(-Self.rateWindow)
        recentSends.removeAll { $0 < cutoff }

        // n timestamps describe n-1 intervals; dividing by n would read low by
        // a full frame and never quite reach the 1.00/s a healthy stream runs at.
        guard recentSends.count >= 2, let first = recentSends.first else { return }
        let span = now.timeIntervalSince(first)
        guard span > 0 else { return }
        frameRate = Double(recentSends.count - 1) / span
    }

    /// Drops the measurement window without discarding the last measured rate —
    /// see the note on `frameRate`.
    private func resetRate() {
        recentSends.removeAll()
    }

    private func mapped(_ cbState: CBManagerState) -> State? {
        switch cbState {
        case .poweredOff:   return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported:  return .unsupported
        case .poweredOn:    return nil
        default:            return .idle
        }
    }

    fileprivate func handleStateChange(_ manager: CBPeripheralManager) {
        if let mappedState = mapped(manager.state) {
            isAdvertising = false
            serviceAdded = false
            subscribers.removeAll()
            state = mappedState
            return
        }
        // Powered on.
        if wantsToAdvertise {
            serviceAdded ? restartAdvertising() : addServiceIfNeeded()
        } else {
            state = .idle
        }
    }

    fileprivate func handleServiceAdded(_ error: Error?) {
        if let error {
            state = .failed(String(localized: "Could not publish heart rate service: \(error.localizedDescription)",
                                   comment: "Bluetooth failure, followed by the system error"))
            return
        }
        serviceAdded = true
        if wantsToAdvertise { restartAdvertising() }
    }

    fileprivate func handleSubscribe(_ central: CBCentral) {
        // Idempotent: a resubscribe from a central we already know replaces its
        // entry rather than adding a phantom second subscriber.
        let existing = subscribers[central.identifier]?.framesSent ?? 0
        subscribers[central.identifier] = Subscriber(
            id: central.identifier,
            maximumUpdateValueLength: central.maximumUpdateValueLength,
            framesSent: existing
        )
        state = .connected(count: subscribers.count)
        sendLatest()
        startKeepaliveIfNeeded()
    }

    fileprivate func handleUnsubscribe(_ central: CBCentral) {
        subscribers.removeValue(forKey: central.identifier)
        if subscribers.isEmpty { stopKeepalive() }
        state = subscribers.isEmpty
            ? (isAdvertising ? .advertising : .idle)
            : .connected(count: subscribers.count)
    }

    fileprivate func handleRead(_ manager: CBPeripheralManager, _ request: CBATTRequest) {
        guard request.characteristic.uuid == CBUUID(string: HeartRateFrame.UUIDString.measurement) else {
            manager.respond(to: request, withResult: .attributeNotFound)
            return
        }
        request.value = latestFrame
        manager.respond(to: request, withResult: .success)
    }

    fileprivate func handleReadyToUpdate() {
        if hasPendingFrame { sendLatest() }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEBroadcaster: CBPeripheralManagerDelegate {

    // The manager was created with `queue: nil`, so every callback below lands
    // on the main queue. `assumeIsolated` states that to the compiler without
    // an async hop — notify latency matters here.

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated { handleStateChange(peripheral) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       didAdd service: CBService,
                                       error: Error?) {
        MainActor.assumeIsolated { handleServiceAdded(error) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       central: CBCentral,
                                       didSubscribeTo characteristic: CBCharacteristic) {
        MainActor.assumeIsolated { handleSubscribe(central) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       central: CBCentral,
                                       didUnsubscribeFrom characteristic: CBCharacteristic) {
        MainActor.assumeIsolated { handleUnsubscribe(central) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       didReceiveRead request: CBATTRequest) {
        MainActor.assumeIsolated { handleRead(peripheral, request) }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated { handleReadyToUpdate() }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       willRestoreState dict: [String: Any]) {
        // State restoration relaunched us into the background with a live
        // connection. Adopt the restored service rather than adding a duplicate.
        MainActor.assumeIsolated {
            guard let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] else { return }
            let measurementUUID = CBUUID(string: HeartRateFrame.UUIDString.measurement)
            for restored in services {
                guard let match = restored.characteristics?.first(where: { $0.uuid == measurementUUID }) as? CBMutableCharacteristic
                else { continue }
                self.service = restored
                self.measurement = match
                self.serviceAdded = true
                self.wantsToAdvertise = true
            }
        }
    }
}
