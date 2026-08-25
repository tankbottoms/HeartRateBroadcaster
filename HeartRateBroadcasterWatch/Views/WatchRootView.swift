import SwiftUI

/// Three swipeable pages. `HeartRateBroadcaster_watchOS_Spec.md` §2–3 asked for
/// two — status first, live BPM second — and the start page joins them on the
/// right, where a page you visit once a ride belongs.
struct WatchRootView: View {

    /// The shared instance rather than one of its own: the phone can launch this
    /// app straight into a workout, and that session is created by the
    /// application delegate before this view exists.
    private var workout = WorkoutManager.shared
    @State private var page = 1   // land on the live readout; it's why you opened the app

    var body: some View {
        TabView(selection: $page) {
            WatchStatusView(workout: workout).tag(0)
            WatchLiveView(workout: workout).tag(1)
            WatchStartView(workout: workout).tag(2)
        }
        .tabViewStyle(.page)
        .background(Theme.background)
        // Lockable only while a workout is actually running — a locked screen
        // with nothing to protect would just be in the way. The phone switch
        // decides whether it locks itself on start; the hold gesture is always
        // available once running.
        .touchLock(autoArms: workout.bridge.antiMistouchOnPhone,
                   isActive: workout.state == .running)
    }
}

#Preview { WatchRootView() }
