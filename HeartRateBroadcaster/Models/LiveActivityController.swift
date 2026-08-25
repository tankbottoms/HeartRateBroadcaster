import Foundation
import ActivityKit
import Observation

/// Drives the Dynamic Island / Lock Screen Live Activity.
///
/// The value of this feature is specifically that it shows what the *head unit*
/// is receiving, not what the watch measured — so it is fed from the fused,
/// post-arbitration number and the live subscriber count, the same two facts
/// that decide whether the ride is actually being recorded.
@Observable
@MainActor
final class LiveActivityController {

    private(set) var isActive = false
    private(set) var lastError: String?

    private var activity: Activity<HeartRateActivityAttributes>?

    /// ActivityKit throttles updates; pushing at the 1 Hz sample rate wastes
    /// budget and the island cannot animate that fast anyway.
    private var lastPush = Date.distantPast
    private static let pushInterval: TimeInterval = 2.0

    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Re-attaches to an activity left behind by a previous launch.
    ///
    /// ActivityKit outlives the process. Without this, relaunching the app
    /// finds `activity == nil`, requests a second one, and the Lock Screen
    /// accumulates a stack of cards that nothing in this process can update or
    /// dismiss. Only the newest is kept; the rest are ended immediately.
    init() {
        let existing = Activity<HeartRateActivityAttributes>.activities
        guard let adopted = existing.last else { return }
        activity = adopted
        isActive = true
        for stray in existing.dropLast() {
            Task { await stray.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func start(broadcastName: String, state: HeartRateActivityAttributes.ContentState) {
        guard activity == nil else {
            update(state, force: true)
            return
        }
        guard isSupported else {
            lastError = String(localized: "Live Activities are turned off for this app in Settings › Heart Rate Broadcaster.")
            return
        }
        do {
            activity = try Activity.request(
                attributes: HeartRateActivityAttributes(broadcastName: broadcastName),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(60)),
                pushType: nil
            )
            isActive = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            isActive = false
        }
    }

    func update(_ state: HeartRateActivityAttributes.ContentState, force: Bool = false) {
        guard let activity else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastPush) >= Self.pushInterval else { return }
        lastPush = now
        Task {
            await activity.update(
                ActivityContent(state: state, staleDate: now.addingTimeInterval(60))
            )
        }
    }

    func stop() {
        guard let activity else { return }
        self.activity = nil
        isActive = false
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
