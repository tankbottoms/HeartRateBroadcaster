import Foundation

/// The OpenBikeControl wire format, as spoken over TCP after an
/// `_openbikecontrol._tcp` Bonjour rendezvous.
///
/// Written from the published protocol rather than ported from any
/// implementation: the reference app is under a non-commercial licence and this
/// one is MIT, so not a line of it is copied here. What follows is a
/// description of bytes on a wire, which is the only part that has to match.
///
/// The shape is deliberately small. A frame is a message-type byte followed by
/// that message's payload, with **no length prefix** — the transport is
/// expected to preserve write boundaries, and every message except a button
/// report is either fixed-length or carries its own field lengths.
enum OpenBikeControl {

    // MARK: - Message types

    enum MessageType: UInt8 {
        /// Game → controller. A single zero byte, sent every few seconds while
        /// nothing else is happening. Undocumented, but MyWhoosh sends one on a
        /// four-second cadence and a controller that treats it as an unreadable
        /// frame stops reading everything after it. It carries nothing; it is
        /// consumed and discarded.
        case keepAlive = 0x00
        /// Controller → game. Which buttons are down.
        case buttonState = 0x01
        /// Controller → game. Battery and link health.
        case deviceStatus = 0x02
        /// Game → controller. Buzz the shifter.
        case hapticFeedback = 0x03
        /// Game → controller. Who is connected and what it understands.
        case appInfo = 0x04
    }

    /// The buttons a shifter can report. The protocol defines a much larger set
    /// — steering, navigation, social, training and view controls — but a
    /// virtual shifter that exists to shift needs three of them, and claiming
    /// buttons the app has no UI for would advertise a controller it isn't.
    enum Button: UInt8, CaseIterable {
        case shiftUp = 0x01
        case shiftDown = 0x02
        /// Carries an absolute gear rather than a direction, in place of the
        /// state byte. This is how the two sides are made to agree: the game
        /// picks its own starting gear and never says which, so the controller
        /// states one instead of trying to discover it.
        case gearSet = 0x03
    }

    /// A button is either down or up. Sent as a whole byte, and the protocol
    /// says nothing about intermediate values, so anything non-zero reads as
    /// pressed.
    enum ButtonState: UInt8 {
        case up = 0x00
        case down = 0x01
    }

    // MARK: - Encoding

    /// `[0x01, buttonID, state, buttonID, state, …]`
    ///
    /// Every button in one frame. A frame naming no buttons is legal and means
    /// nothing is held, which is how a release is reported when several buttons
    /// were down at once.
    static func encodeButtonState(_ buttons: [(Button, ButtonState)]) -> Data {
        var data = Data([MessageType.buttonState.rawValue])
        for (button, state) in buttons {
            data.append(button.rawValue)
            data.append(state.rawValue)
        }
        return data
    }

    /// A press and a release, as two frames.
    ///
    /// Two writes rather than one: the receiving game watches for the edge, and
    /// a single frame carrying down-then-up for the same button would be read as
    /// two buttons of the same name disagreeing with each other. The caller
    /// sends these back to back with no deliberate gap — the transport's own
    /// ordering is the only thing separating them, and that is enough.
    static func tap(_ button: Button) -> [Data] {
        [encodeButtonState([(button, .down)]),
         encodeButtonState([(button, .up)])]
    }

    /// `[0x01, 0x03, gear]` — go to this gear, whatever gear you were in.
    ///
    /// One frame, with no release after it. For the two shift buttons the third
    /// byte is a state and the release matters; here the third byte is the gear
    /// itself, so a release frame would read as a request for gear zero. Gears
    /// are numbered from one and clamped to a byte.
    static func encodeGearSet(_ gear: Int) -> Data {
        Data([MessageType.buttonState.rawValue,
              Button.gearSet.rawValue,
              UInt8(min(max(gear, 1), 255))])
    }

    /// `[0x02, batteryPercent, connected]`
    ///
    /// A virtual shifter has no battery. It reports full rather than absent,
    /// because a game that draws a battery gauge would otherwise show this
    /// controller as flat and about to drop out.
    static func encodeDeviceStatus(batteryPercent: UInt8 = 100, connected: Bool = true) -> Data {
        Data([MessageType.deviceStatus.rawValue,
              min(batteryPercent, 100),
              connected ? 0x01 : 0x00])
    }

    // MARK: - Decoding

    /// What the game says about itself once it connects.
    ///
    /// Its arrival is the gate on sending anything: until it lands there is a
    /// TCP connection but nobody has said what is on the other end, and a shift
    /// sent into that silence goes nowhere.
    struct AppInfo: Equatable {
        let version: UInt8
        let appID: String
        let appVersion: String
        /// Which buttons the game will act on. A game that does not list
        /// `shiftUp` is not going to shift, and the UI can say so rather than
        /// letting the rider press a dead button for an hour.
        let supportedButtons: [Button]

        var supportsShifting: Bool {
            supportedButtons.contains(.shiftUp) && supportedButtons.contains(.shiftDown)
        }
    }

    /// `[0x04, version, appIDLen, appID…, appVersionLen, appVersion…, count, buttonIDs…]`
    ///
    /// Returns nil rather than throwing for anything malformed. This runs on
    /// bytes from another vendor's app mid-ride; the useful response to a frame
    /// we cannot read is to ignore it and keep the connection, not to tear down
    /// a working shifter over a field length.
    static func parseAppInfo(_ data: Data) -> AppInfo? {
        var bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == MessageType.appInfo.rawValue else { return nil }

        var index = 2   // past the type and the version byte

        func readString() -> String? {
            guard index < bytes.count else { return nil }
            let length = Int(bytes[index])
            index += 1
            guard index + length <= bytes.count else { return nil }
            let slice = bytes[index ..< index + length]
            index += length
            return String(decoding: slice, as: UTF8.self)
        }

        guard let appID = readString(), let appVersion = readString() else { return nil }
        guard index < bytes.count else { return nil }

        let count = Int(bytes[index])
        index += 1
        guard index + count <= bytes.count else { return nil }
        // Unknown identifiers are dropped rather than rejected: the button set
        // grows with the protocol, and a game listing a view control this app
        // has never heard of is still a game that can shift.
        let buttons = bytes[index ..< index + count].compactMap(Button.init(rawValue:))

        return AppInfo(version: bytes[1],
                       appID: appID,
                       appVersion: appVersion,
                       supportedButtons: buttons)
    }

    /// Splits a received chunk into frames.
    ///
    /// With no length prefix this cannot be done in general, and it does not have
    /// to be: everything a game sends to a controller is either fixed-length
    /// (haptic, 4 bytes) or self-describing (app info). Anything else ends the
    /// scan, and the rest of the buffer is handed back so a partial frame can be
    /// completed by the next read rather than thrown away.
    ///
    /// - Returns: the frames recognised, and whatever bytes remain.
    static func split(_ data: Data) -> (frames: [Data], remainder: Data) {
        var frames: [Data] = []
        var rest = data

        while let type = rest.first.flatMap(MessageType.init(rawValue:)) {
            let length: Int
            switch type {
            case .keepAlive:
                // Eaten, not reported. Left in the buffer it would block every
                // frame behind it, which is the whole reason it is named here.
                rest = rest.dropFirst()
                continue
            case .hapticFeedback:
                length = 4
            case .deviceStatus:
                length = 3
            case .appInfo:
                guard let end = appInfoLength(rest) else { return (frames, rest) }
                length = end
            case .buttonState:
                // A controller does not receive these. Treated as unreadable so
                // the buffer is handed on intact rather than silently eaten.
                return (frames, rest)
            }
            guard rest.count >= length else { return (frames, rest) }
            frames.append(rest.prefix(length))
            rest = rest.dropFirst(length)
        }
        return (frames, rest)
    }

    /// The length of the app-info frame at the head of `data`, or nil if it has
    /// not all arrived yet.
    private static func appInfoLength(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        var index = 2
        for _ in 0 ..< 2 {                       // appID, then appVersion
            guard index < bytes.count else { return nil }
            index += 1 + Int(bytes[index])
        }
        guard index < bytes.count else { return nil }
        index += 1 + Int(bytes[index])           // button count, then the buttons
        return index <= bytes.count ? index : nil
    }

    // MARK: - Service discovery

    /// Bonjour service type. A game looking for a shifter browses for this.
    static let serviceType = "_openbikecontrol._tcp"

    /// The port the protocol prefers. Not guaranteed: something else may hold
    /// it, and the port that ends up in the SRV record is whichever one the
    /// listener actually bound. Callers walk upward from here.
    static let preferredPort: UInt16 = 36867

    /// The BLE service a hardware shifter would expose. Sent in the TXT record
    /// because games use it to tell one kind of controller from another, even
    /// over the network transport where nothing is connecting over BLE.
    static let serviceUUID = "00000001-19CA-4651-86E5-FA29DCDD09D1"
}
