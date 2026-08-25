import SwiftUI

/// Page 1 — settings and status. `HeartRateBroadcaster_watchOS_Spec.md` §2.
struct WatchStatusView: View {

    let workout: WorkoutManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.cardSpacing) {

                Text("Heart Rate Bridge")
                    .font(Theme.Typeface.sectionTitle)
                    .foregroundStyle(Theme.textSecondary)

                row(icon: "iphone",
                    title: "iPhone",
                    detail: workout.bridge.isReachable ? "Linked" : "Not reachable",
                    ok: workout.bridge.isReachable)

                row(icon: "antenna.radiowaves.left.and.right",
                    title: "Bridge",
                    detail: workout.bridge.bridgeEnabledOnPhone ? "Enabled" : "Off on iPhone",
                    ok: workout.bridge.bridgeEnabledOnPhone)

                row(icon: "heart.text.square",
                    title: "HealthKit",
                    detail: workout.state == .running ? "Streaming" : "Idle",
                    ok: workout.state == .running)

                // Only while the phone is recording. Off-session this row would
                // say "no workout" on every screen the rider ever looks at,
                // which is not news.
                if workout.bridge.sessionActiveOnPhone {
                    row(icon: sportIcon,
                        title: "Workout",
                        detail: sportLabel,
                        ok: true)
                }

                if !workout.bridge.isReachable {
                    Text("Open Heart Rate Broadcaster on iPhone. The phone does the Bluetooth broadcasting; the watch only supplies heart rate.")
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Theme.Metric.screenPadding)
            .padding(.vertical, Theme.Metric.cardSpacing)
        }
    }

    /// The sport the phone is recording, defaulting to the same indoor cycling
    /// the session itself falls back to.
    private var sportLabel: LocalizedStringKey {
        switch workout.bridge.sportOnPhone ?? .cycling {
        case .cycling: "Recording a ride"
        case .running: "Recording a run"
        case .swimming: "Recording a swim"
        }
    }

    private var sportIcon: String {
        switch workout.bridge.sportOnPhone ?? .cycling {
        case .cycling: "figure.outdoor.cycle"
        case .running: "figure.run"
        case .swimming: "figure.pool.swim"
        }
    }

    /// `icon` is an SF Symbol name and stays a String; the two prose parameters
    /// are keys, so every call site localizes without changing.
    private func row(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(ok ? Theme.accentActive : Theme.textTertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Metric.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Metric.cornerRadius))
    }
}
