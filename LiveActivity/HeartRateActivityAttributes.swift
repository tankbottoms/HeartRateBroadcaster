import Foundation
import ActivityKit

/// Shared contract between the app and the widget extension.
///
/// Compiled into both targets rather than imported, because a widget extension
/// is a separate process with its own binary — this file is the only thing the
/// two have in common, so it must stay free of app types.
struct HeartRateActivityAttributes: ActivityAttributes {

    /// Everything that changes during a ride.
    struct ContentState: Codable, Hashable {
        var bpm: Int?
        /// False when the source has gone quiet — the island shows a dash
        /// rather than a stale number.
        var isLive: Bool
        /// "Watch", "AirPods", "Watch + AirPods", "Test".
        var source: String
        /// How many head units are subscribed right now.
        var subscriberCount: Int
    }

    /// Fixed for the life of the activity.
    var broadcastName: String
}
