import SwiftUI
import HealthKit
import WatchKit

@main
struct HeartRateBroadcasterWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}

/// Exists for one method.
///
/// When the phone starts a ride it calls `startWatchApp(with:)`, which
/// launches this app and hands the workout configuration to the delegate — not
/// to a view, which may not have been built yet. Without this the phone could
/// tell a *running* watch app about a ride but never wake a stopped one, and
/// the rider would still have to press start on the wrist.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {

    nonisolated func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        let sport = WorkoutSport(activityType: workoutConfiguration.activityType)
        Task { @MainActor in
            // `announce: false` — the phone is already recording; this launch is
            // its doing. Asking it to start again would be a loop.
            await WorkoutManager.shared.start(sport: sport, announce: false)
        }
    }
}
