import Foundation

/// Every byte in and out of the virtual shifter, written to a file.
///
/// The protocol is documented in outline but not in detail, and the interesting
/// question — how a game and a shifter agree on which gear you are in — is not
/// answered anywhere we can read. It may be answered on the wire. So the whole
/// conversation is recorded verbatim: raw hex first, then our reading of it, so
/// that a frame we decode wrongly is still recoverable from the same line.
///
/// Nothing here leaves the phone. The file sits in the app's own Documents
/// directory and is retrieved over the cable.
final class BikeControlLog: @unchecked Sendable {

    static let shared = BikeControlLog()

    /// Enough to hold a long ride's worth of shifting, small enough to pull over
    /// USB without waiting. Past this the file starts again rather than growing
    /// without limit — the beginning of a session is where the handshake is, but
    /// a full disk would be worse than a lost tail.
    private static let sizeLimit = 4 * 1024 * 1024

    private let queue = DispatchQueue(label: "xyz.atsignhandle.bikecontrol.log")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private lazy var url: URL? = {
        guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else { return nil }
        return documents.appendingPathComponent("bikecontrol.log")
    }()

    var fileURL: URL? { url }

    // MARK: - Writing

    /// A plain event: a state change, a connection, a decision.
    func note(_ message: String) {
        append("\(formatter.string(from: Date()))  \(message)")
    }

    /// Bytes, with whatever sense we can make of them alongside.
    ///
    /// - Parameter direction: `in` is the game talking, `out` is this app.
    func bytes(_ data: Data, direction: String, note: String? = nil) {
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        var line = "\(formatter.string(from: Date()))  \(direction) [\(data.count)]  \(hex)"
        if let note { line += "\n                    ↳ \(note)" }
        if let reading = Self.describe(data) { line += "\n                    ↳ \(reading)" }
        append(line)
    }

    /// Our best reading of a frame, including the parts the shifter itself
    /// ignores. An unrecognised type is reported as unrecognised rather than
    /// dropped, because that is exactly the frame worth looking at later.
    private static func describe(_ data: Data) -> String? {
        guard let first = data.first else { return nil }
        let body = [UInt8](data.dropFirst())
        switch OpenBikeControl.MessageType(rawValue: first) {
        case .keepAlive:
            return "KEEPALIVE"
        case .buttonState where body.first == OpenBikeControl.Button.gearSet.rawValue:
            return "GEAR_SET: \(body.count > 1 ? String(body[1]) : "—")"
        case .buttonState:
            let pairs = stride(from: 0, to: body.count - 1, by: 2).map { i -> String in
                let button = OpenBikeControl.Button(rawValue: body[i]).map(String.init(describing:))
                    ?? String(format: "button 0x%02x", body[i])
                return "\(button) \(body[i + 1] == 0 ? "up" : "down")"
            }
            return "BUTTON_STATE: " + (pairs.isEmpty ? "none" : pairs.joined(separator: ", "))
        case .deviceStatus:
            guard body.count >= 2 else { return "DEVICE_STATUS: short" }
            return "DEVICE_STATUS: battery \(body[0])%, \(body[1] == 0 ? "disconnected" : "connected")"
        case .hapticFeedback:
            // The one frame a game sends unprompted and repeatedly. If a gear
            // number is coming back from anywhere, the odds are it is in here,
            // so all three bytes are printed as decimal as well as hex.
            let decimal = body.map(String.init).joined(separator: " ")
            return "HAPTIC: \(decimal)"
        case .appInfo:
            if let info = OpenBikeControl.parseAppInfo(data) {
                let buttons = info.supportedButtons.map(String.init(describing:)).joined(separator: ", ")
                return "APP_INFO: \(info.appID) \(info.appVersion), protocol v\(info.version), buttons [\(buttons)]"
            }
            return "APP_INFO: unparseable (truncated, or a field we read wrongly)"
        case .none:
            return String(format: "UNRECOGNISED type 0x%02x — worth a look", first)
        }
    }

    // MARK: - Reading and clearing

    /// The whole log, for showing on screen. Nil if nothing has been written.
    func contents() -> String? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func clear() {
        queue.async { [url] in
            guard let url else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func append(_ line: String) {
        queue.async { [url] in
            guard let url, let data = (line + "\n").data(using: .utf8) else { return }
            let manager = FileManager.default
            guard manager.fileExists(atPath: url.path) else {
                try? data.write(to: url, options: .atomic)
                return
            }
            if let attributes = try? manager.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? Int, size > Self.sizeLimit {
                try? manager.removeItem(at: url)
                try? data.write(to: url, options: .atomic)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
