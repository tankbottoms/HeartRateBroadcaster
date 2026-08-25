import Foundation
import WatchConnectivity
import Observation

/// iPhone end of the WatchConnectivity link.
@Observable
@MainActor
final class PhoneSessionBridge: NSObject {

    private(set) var isSupported = WCSession.isSupported()
    private(set) var isPaired = false
    private(set) var isWatchAppInstalled = false
    private(set) var isReachable = false
    /// The watch has told us its workout session is running.
    private(set) var isWatchStreaming = false

    /// Identity of the watch actually sending, as reported by the watch app.
    /// `WCSession` on iOS exposes no name or identifier for the paired watch,
    /// so this only becomes non-nil once the watch app has spoken to us.
    private(set) var watchName: String?
    private(set) var watchID: String?
    private(set) var watchModel: String?
    private(set) var watchSystemVersion: String?

    /// One line for the "Watch paired" row: name, OS, and the identifier this
    /// app sees it by.
    ///
    /// `watchModel` is deliberately left out. `WKInterfaceDevice.model` returns
    /// the literal string "Apple Watch" on every watch ever made, so printing it
    /// next to a watchOS version says nothing the version did not already say
    /// and costs a third of a line that the identifier needs.
    var watchIdentityDetail: String? {
        guard let watchID else { return nil }
        var parts: [String] = []
        if let watchName { parts.append(watchName) }
        if let watchSystemVersion { parts.append("watchOS \(watchSystemVersion)") }
        parts.append("ID \(watchID.prefix(8))")
        return parts.joined(separator: " · ")
    }

    /// Called on the main actor for each heart rate the watch pushes.
    var onHeartRate: ((Int, Date) -> Void)?

    /// The watch has pressed Start or Stop and is asking the phone to record
    /// the ride. `true` with the sport it chose, `false` to end it.
    var onSessionCommand: ((Bool, WorkoutSport?) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Settings phone → watch. `updateApplicationContext` coalesces to
    /// latest-wins and is delivered even if the watch app is asleep, which is
    /// exactly the semantics settings want (and exactly wrong for live BPM).
    func push(settings: [String: Any]) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        try? session.updateApplicationContext(settings)
    }

    fileprivate func refreshReachability() {
        let session = WCSession.default
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
        if !session.isReachable { isWatchStreaming = false }
    }

    fileprivate func ingest(_ message: [String: Any]) {
        if let name = message[WCKey.watchName] as? String { watchName = name }
        if let id = message[WCKey.watchID] as? String { watchID = id }
        if let model = message[WCKey.watchModel] as? String { watchModel = model }
        if let version = message[WCKey.watchSystemVersion] as? String { watchSystemVersion = version }
        if let active = message[WCKey.watchActive] as? Bool {
            isWatchStreaming = active
        }
        // Commands, not state: acted on every time they arrive rather than on a
        // change, because two rides in a row are two identical starts.
        if message[WCKey.startRequest] as? Bool == true {
            let sport = (message[WCKey.sport] as? String).flatMap(WorkoutSport.init(rawValue:))
            onSessionCommand?(true, sport)
        }
        if message[WCKey.stopRequest] as? Bool == true {
            onSessionCommand?(false, nil)
        }
        guard let bpm = message[WCKey.bpm] as? Int else { return }
        let date = (message[WCKey.timestamp] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        onHeartRate?(bpm, date)
    }
}

// MARK: - WCSessionDelegate

extension PhoneSessionBridge: WCSessionDelegate {

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in refreshReachability() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in refreshReachability() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in refreshReachability() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in ingest(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in ingest(context) }
    }

    // Required on iOS so the session can be handed to a newly paired watch.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}
