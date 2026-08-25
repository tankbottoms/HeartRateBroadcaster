import Foundation
import Network
import Observation

/// A virtual shifter, offered to whatever cycling app is running on the same
/// network.
///
/// The phone advertises `_openbikecontrol._tcp` over Bonjour, accepts the
/// connection the game makes back, waits to be told who the game is, and from
/// then on sends a shift every time the rider presses a button in this app. No
/// Bluetooth is involved and no Zwift or Kickr Click has to be paired: the
/// buttons on the screen *are* the shifter.
///
/// This is not a cloud service and it is not a broadcast. It listens on the
/// local network only, and only while the rider has switched it on.
@Observable
@MainActor
final class BikeControlService {

    enum State: Equatable {
        case off
        case starting
        /// Listening and advertised, nobody connected.
        case advertising(port: UInt16)
        /// A game has connected but has not identified itself. Shifts are held
        /// back until it does — the protocol says the controller speaks second.
        case connecting
        /// Ready. The name is the game's, so the rider can see they are shifting
        /// the app they think they are.
        case ready(app: String)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .off, .failed: return false
            case .starting, .advertising, .connecting, .ready: return true
            }
        }

        /// Whether a press would reach anything.
        var canShift: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    private(set) var state: State = .off

    /// The gear this app believes you are in.
    ///
    /// Believes, not knows. A Kickr Core reports power, cadence and speed and
    /// says nothing at all about virtual gears — the gear lives inside the game,
    /// and the game does not send it back. So this counts the shifts it has sent
    /// and shows the result, which is right until something else shifts too: the
    /// physical Clicks, a keyboard, a second app. `resync(to:)` exists for when
    /// that happens, and the UI says plainly that the number is local.
    private(set) var gear: Int

    /// How many virtual gears the game is configured for. Only used to stop the
    /// counter running off either end; the game clamps for real.
    var gearCount: Int {
        didSet { gear = min(gear, gearCount) }
    }

    /// The gear a game is assumed to open in.
    ///
    /// When the game accepts an absolute gear this is only a starting point, and
    /// is overwritten the moment the app states one. When the game does not —
    /// MyWhoosh does not — it is the only thing standing between the two sides
    /// and a silent disagreement, because the counter would otherwise resume
    /// wherever the last ride left it while the game had gone back to the top.
    var startingGear: Int = 15

    /// The last app-info the game sent, kept so the settings screen can say what
    /// is connected and whether it admits to shifting.
    private(set) var appInfo: OpenBikeControl.AppInfo?

    private var listener: NWListener?
    private var connection: NWConnection?
    private var inbound = Data()
    /// How far up from the preferred port we have walked. Reset on every start.
    private var portAttempt = 0
    private let maximumPortAttempts = 8
    private let queue = DispatchQueue(label: "xyz.atsignhandle.bikecontrol")
    /// Everything said in either direction, kept on disk. The gear a game thinks
    /// you are in is not documented as travelling over this link; if it does
    /// travel, this is where the evidence will be.
    private let log = BikeControlLog.shared

    init(gearCount: Int = 24, gear: Int = 12) {
        self.gearCount = gearCount
        self.gear = min(max(gear, 1), gearCount)
    }

    // MARK: - Lifecycle

    /// - Parameter name: what the game shows in its controller list. The rider's
    ///   own advertised name, so the shifter and the heart rate sensor read as
    ///   one device rather than two strangers.
    func start(name: String) {
        guard !state.isRunning else { return }
        portAttempt = 0
        state = .starting
        log.note("--- start, advertising as \"\(name)\", \(gearCount) gears, showing gear \(gear)")
        listen(name: name)
    }

    func stop() {
        if state.isRunning { log.note("--- stop") }
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        inbound.removeAll()
        appInfo = nil
        state = .off
    }

    private func listen(name: String) {
        let port = OpenBikeControl.preferredPort + UInt16(portAttempt)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            state = .failed(String(localized: "No usable port", comment: "Bike Control could not find a free network port"))
            return
        }

        let parameters = NWParameters.tcp
        // A shift is one frame of two bytes and it is wanted now, not batched
        // behind whatever else the stack was about to coalesce.
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: endpointPort)
        } catch {
            retryOrFail(name: name, error: error.localizedDescription)
            return
        }

        // Setting the service here rather than advertising by hand is what keeps
        // the SRV record honest: whatever port the listener ends up bound to is
        // the port that gets published, including after a walk.
        listener.service = NWListener.Service(name: name,
                                              type: OpenBikeControl.serviceType,
                                              domain: nil,
                                              txtRecord: Self.txtRecord(name: name))

        listener.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                switch newState {
                case .ready:
                    let bound = self.listener?.port?.rawValue ?? port
                    self.log.note("listening on port \(bound), published as \(OpenBikeControl.serviceType)")
                    if case .ready = self.state {} else if !self.state.canShift {
                        self.state = .advertising(port: bound)
                    }
                case .failed(let error), .waiting(let error):
                    self.log.note("listener on port \(port): \(error.localizedDescription)")
                    self.retryOrFail(name: name, error: error.localizedDescription)
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    /// A port in use is the ordinary case, not a failure: the reference app
    /// itself walks upward when it finds 36867 taken, and games follow the SRV
    /// record rather than assuming the number.
    private func retryOrFail(name: String, error: String) {
        listener?.cancel()
        listener = nil
        guard portAttempt < maximumPortAttempts else {
            state = .failed(error)
            return
        }
        portAttempt += 1
        listen(name: name)
    }

    private static func txtRecord(name: String) -> NWTXTRecord {
        var txt = NWTXTRecord()
        // A raw byte, not the character "1" — the field is a protocol version
        // and games read it as a number.
        txt.setEntry(.data(Data([0x01])), for: "version")
        txt.setEntry(.string(name), for: "name")
        txt.setEntry(.string(OpenBikeControl.serviceUUID), for: "service-uuids")
        txt.setEntry(.string("OpenBikeControl"), for: "manufacturer")
        txt.setEntry(.string("HeartRate Broadcaster"), for: "model")
        return txt
    }

    // MARK: - Connection

    private func accept(_ connection: NWConnection) {
        // One game at a time. A second connection is almost always the same game
        // reconnecting after a network blip, and keeping the older one would
        // leave shifts going to a socket nobody is reading.
        self.connection?.cancel()
        self.connection = connection
        inbound.removeAll()
        appInfo = nil
        state = .connecting
        log.note("connection from \(connection.endpoint)")

        connection.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                switch newState {
                case .ready:
                    // Says hello with a full battery so the game's controller
                    // list shows this as a healthy device rather than a blank.
                    self.send(OpenBikeControl.encodeDeviceStatus())
                case .failed, .cancelled:
                    self.dropConnection()
                default:
                    break
                }
            }
        }

        receive(on: connection)
        connection.start(queue: queue)
    }

    private func dropConnection() {
        if connection != nil {
            // Whatever is still in the buffer never became a frame. That is the
            // most interesting thing in the file if shifting stopped working, so
            // it is written down rather than quietly dropped.
            if !inbound.isEmpty { log.bytes(inbound, direction: "IN ", note: "unconsumed at disconnect") }
            log.note("disconnected")
        }
        connection?.cancel()
        connection = nil
        appInfo = nil
        inbound.removeAll()
        let bound = listener?.port?.rawValue ?? OpenBikeControl.preferredPort
        if state.isRunning { state = .advertising(port: bound) }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty { self.ingest(data) }
                if isComplete || error != nil {
                    self.dropConnection()
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    /// TCP is a stream: a read may hold half a frame, or three of them. What is
    /// left over stays in the buffer for the next read rather than being
    /// discarded, which is the difference between a game that identifies itself
    /// on a slow network and one that never seems to.
    private func ingest(_ data: Data) {
        // Keepalives arrive every few seconds for the length of a ride and say
        // nothing. Logging them would bury the frames that matter.
        if data.contains(where: { $0 != 0x00 }) { log.bytes(data, direction: "IN ") }
        inbound.append(data)
        let (frames, remainder) = OpenBikeControl.split(inbound)
        inbound = remainder
        if !remainder.isEmpty {
            log.note("  \(remainder.count) byte(s) held over for the next read")
        }
        for frame in frames {
            guard let info = OpenBikeControl.parseAppInfo(frame) else { continue }
            appInfo = info
            state = .ready(app: info.appID)
            log.note("ready — shifting \(info.appID), gear counter says \(gear) of \(gearCount)")
            // The game has already picked a gear of its own and will never say
            // which. So rather than guess, state one: the number on screen is
            // made true by sending it, and the two sides start agreed.
            if info.supportedButtons.contains(.gearSet) {
                sendGearSet()
            } else {
                // Nothing can be stated, so the only honest move is to assume
                // the game is where it always opens and put the counter there.
                // Resuming last ride's number instead leaves the two sides
                // disagreeing by however far that ride got, with nothing on
                // either screen to say so — which is exactly what testing found.
                let assumed = min(max(startingGear, 1), gearCount)
                if gear != assumed {
                    gear = assumed
                    log.note("counter set to the assumed opening gear \(assumed) — \(info.appID) cannot be told one")
                } else {
                    log.note("\(info.appID) does not offer gearSet — the gear cannot be stated, only counted")
                }
            }
        }
    }

    // MARK: - Shifting

    func shiftUp() {
        guard gear < gearCount else { log.note("shift up refused — already at \(gear) of \(gearCount)"); return }
        if send(tap: .shiftUp) { gear += 1; log.note("shift up — counter now \(gear)") }
    }

    func shiftDown() {
        guard gear > 1 else { log.note("shift down refused — already at 1"); return }
        if send(tap: .shiftDown) { gear -= 1; log.note("shift down — counter now \(gear)") }
    }

    /// Whether the connected game will accept an absolute gear. When it will
    /// not, the gear can still be counted — it just cannot be stated, and the
    /// two sides have to be walked into agreement by hand.
    var canSetGear: Bool {
        state.canShift && appInfo?.supportedButtons.contains(.gearSet) == true
    }

    /// Puts both sides on the same gear, by telling the game which one.
    ///
    /// This is the answer to a question the protocol does not otherwise answer:
    /// nothing reports the gear back, so agreement has to be asserted rather
    /// than discovered.
    func setGear(_ gear: Int) {
        self.gear = min(max(gear, 1), gearCount)
        sendGearSet()
    }

    private func sendGearSet() {
        guard state.canShift else { return }
        send(OpenBikeControl.encodeGearSet(gear))
        log.note("stated gear \(gear) of \(gearCount)")
    }

    /// Corrects the counter without telling the game — for a game that cannot
    /// be told. Nothing is sent: this fixes our bookkeeping, it does not move
    /// the trainer.
    func resync(to gear: Int) {
        self.gear = min(max(gear, 1), gearCount)
        log.note("counter corrected by hand to \(self.gear)")
    }

    /// - Returns: whether the frames went out, so the gear number only moves
    ///   when a shift was actually sent. A counter that advances while the game
    ///   is disconnected is worse than no counter at all — it comes back wrong
    ///   and looks right.
    @discardableResult
    private func send(tap button: OpenBikeControl.Button) -> Bool {
        guard state.canShift else { return false }
        for frame in OpenBikeControl.tap(button) { send(frame) }
        return true
    }

    private func send(_ data: Data) {
        guard let connection else {
            log.bytes(data, direction: "OUT", note: "dropped — nothing connected")
            return
        }
        log.bytes(data, direction: "OUT")
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { BikeControlLog.shared.note("send failed: \(error)") }
        })
    }
}
