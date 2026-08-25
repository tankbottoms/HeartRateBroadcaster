import Foundation
import WatchConnectivity
import Observation
import WatchKit

/// Watch end of the WatchConnectivity link.
@Observable
@MainActor
final class WatchSessionBridge: NSObject {

    private(set) var isReachable = false
    /// Mirrors the phone's Heart Rate Bridge toggle, for display on the watch.
    private(set) var bridgeEnabledOnPhone = true
    /// Mirrors the phone's Watch Anti-mistouch toggle.
    private(set) var antiMistouchOnPhone = false
    /// The sport the phone's recorder is set to. `nil` until the phone has
    /// pushed a context — the watch then labels its own session to match
    /// rather than filing every ride as indoor cycling.
    private(set) var sportOnPhone: WorkoutSport?
    /// Whether a recorded workout is running on the phone. Displayed on the
    /// status page so a rider who started on the watch can see that the phone
    /// is (or is not) the thing keeping the record.
    private(set) var sessionActiveOnPhone = false

    /// Identity of this watch, merged into every outgoing payload so the phone
    /// can name the device it is actually receiving from — useful when more
    /// than one watch has been paired to the phone over its life.
    private let identity: [String: Any] = {
        let device = WKInterfaceDevice.current()
        var info = utsname()
        uname(&info)
        let model = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return [
            WCKey.watchName: device.name,
            WCKey.watchID: device.identifierForVendor?.uuidString ?? "unknown",
            WCKey.watchModel: model,
            WCKey.watchSystemVersion: device.systemVersion
        ]
    }()

    /// Called when the phone's recorder starts or stops, with the sport it is
    /// recording. The watch follows it: a ride begun on the phone should not
    /// need a second press on the wrist.
    var onPhoneSessionChanged: ((Bool, WorkoutSport?) -> Void)?

    /// Application-context updates are rate limited by the system, so the
    /// unreachable fallback path is throttled rather than fired per sample.
    private var lastContextPush = Date.distantPast
    private static let contextThrottle: TimeInterval = 2

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Live heart rate is only worth anything immediately. When the phone is
    /// unreachable the sample is dropped rather than queued — `transferUserInfo`
    /// would deliver a backlog of stale readings minutes later.
    func send(bpm: Int, at date: Date) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        var payload = identity
        payload[WCKey.bpm] = bpm
        payload[WCKey.timestamp] = date.timeIntervalSince1970
        payload[WCKey.watchActive] = true

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else if Date().timeIntervalSince(lastContextPush) > Self.contextThrottle {
            // Latest-wins fallback: gets the current value across as soon as the
            // phone app wakes, without a queue of stale samples behind it.
            try? session.updateApplicationContext(payload)
            lastContextPush = Date()
        }
    }

    func sendStreamingStopped() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        var payload = identity
        payload[WCKey.watchActive] = false
        session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
    }

    /// Announce the watch to the phone without a heart rate attached, so the
    /// phone's "Watch paired" row can name the device before a workout starts.
    func sendIdentity() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(identity, replyHandler: nil, errorHandler: nil)
    }

    /// Asks the phone to begin recording the ride the watch just started.
    ///
    /// Best effort by design. If the phone is out of reach the watch still has
    /// its own session and still has the heart rate; what is lost is the
    /// recorded workout, and the status page already says whether the phone is
    /// keeping one. Queueing the request instead would start a workout on the
    /// phone whenever it next woke up, which could be hours later.
    func requestSessionStart(sport: WorkoutSport) {
        var payload = identity
        payload[WCKey.startRequest] = true
        payload[WCKey.sport] = sport.rawValue
        sendCommand(payload)
    }

    func requestSessionStop() {
        var payload = identity
        payload[WCKey.stopRequest] = true
        sendCommand(payload)
    }

    private func sendCommand(_ payload: [String: Any]) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
    }

    fileprivate func refresh() {
        let wasReachable = isReachable
        isReachable = WCSession.default.isReachable
        if isReachable && !wasReachable { sendIdentity() }
    }

    fileprivate func ingest(context: [String: Any]) {
        if let enabled = context[WCKey.bridgeEnabled] as? Bool {
            bridgeEnabledOnPhone = enabled
        }
        if let lock = context[WCKey.antiMistouch] as? Bool {
            antiMistouchOnPhone = lock
        }
        if let raw = context[WCKey.sport] as? String,
           let sport = WorkoutSport(rawValue: raw) {
            sportOnPhone = sport
        }
        if let active = context[WCKey.sessionActive] as? Bool {
            // Only on a change. The phone re-pushes its whole settings context
            // whenever any toggle moves, so acting on every delivery would try
            // to start an already-running session several times a ride.
            let changed = active != sessionActiveOnPhone
            sessionActiveOnPhone = active
            if changed { onPhoneSessionChanged?(active, sportOnPhone) }
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionBridge: WCSessionDelegate {

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in refresh() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in refresh() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in ingest(context: context) }
    }
}
