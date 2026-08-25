import Foundation

/// Keys shared by both ends of the WatchConnectivity link.
///
/// Live heart rate goes over `sendMessage` (dropped when the counterpart is
/// unreachable — a stale BPM is worse than none). Settings go over
/// `updateApplicationContext`, which coalesces to latest-wins and survives the
/// counterpart being asleep.
enum WCKey {
    /// Int — beats per minute.
    static let bpm = "bpm"
    /// Double — `Date.timeIntervalSince1970` of the sample.
    static let timestamp = "ts"
    /// Bool — watch reports whether its workout session is running.
    static let watchActive = "watchActive"

    // Watch identity, watch → phone.
    //
    // Sent with *every* payload rather than once at activation. The phone app
    // can be relaunched at any time and would then only ever see the most
    // recent application context — which, mid-ride, is a heart rate frame. A
    // hundred bytes per second is cheaper than an identity row that reads
    // "Unknown" for the rest of the session.
    /// String — `WKInterfaceDevice.name`, e.g. "Mark's Apple Watch".
    static let watchName = "watchName"
    /// String — `identifierForVendor`, stable per install of this app.
    static let watchID = "watchID"
    /// String — e.g. "Watch7,2".
    static let watchModel = "watchModel"
    /// String — watchOS version.
    static let watchSystemVersion = "watchOS"

    // Settings, phone → watch.
    static let bridgeEnabled = "bridgeEnabled"
    static let autoStart = "autoStart"
    /// Bool — lock the watch screen against accidental taps while streaming.
    static let antiMistouch = "antiMistouch"

    /// String — `WorkoutSport.rawValue`. Sent both ways: with the phone's
    /// settings so the watch labels its own session to match, and with a start
    /// request so the phone records the sport the watch was asked for.
    static let sport = "sport"
    /// Bool — a recorded workout is running on the phone.
    static let sessionActive = "sessionActive"

    // Session commands, watch → phone.
    //
    // Either end can now start a ride, so the link carries requests as well as
    // state. Sent over `sendMessage` and never queued: a start that arrives
    // after the rider has given up and pressed the button on the other device
    // would begin a second session behind their back.
    /// Bool — the watch is asking the phone to begin recording.
    static let startRequest = "startRequest"
    /// Bool — the watch is asking the phone to stop recording.
    static let stopRequest = "stopRequest"
}
