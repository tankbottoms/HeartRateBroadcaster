import SwiftUI

/// Page 2 — the live readout. `HeartRateBroadcaster_watchOS_Spec.md` §3.
struct WatchLiveView: View {

    let workout: WorkoutManager

    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 2) {
            Spacer(minLength: 0)

            Text(workout.currentBPM.map(String.init) ?? "--")
                .font(.system(size: 62, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isStale ? Theme.textTertiary : Theme.textPrimary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            HStack(spacing: 5) {
                // Beats once per measured heartbeat — if this is still while the
                // number sits at 90, the samples have stopped arriving.
                BeatingHeart(bpm: workout.currentBPM,
                             isLive: workout.state == .running && !isStale,
                             size: 15)
                Text("BPM")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }

            Text(freshness)
                .font(.system(size: 11))
                .foregroundStyle(isStale ? Theme.accentAlert : Theme.textSecondary)

            Spacer(minLength: 0)

            control

            // Bottom centre, under the control. In the top-left corner the dot
            // sat next to the time and read as chrome; centred beneath the one
            // button on the screen it is where the eye already is after starting
            // or stopping, which is exactly when the link state is in question.
            LinkDot(label: linkLabel, color: linkColor)
        }
        .padding(.horizontal, Theme.Metric.screenPadding)
        .padding(.bottom, 4)
        .onReceive(tick) { now = $0 }
    }

    @ViewBuilder
    private var control: some View {
        switch workout.state {
        case .idle, .failed:
            Button {
                Task { await workout.start() }
            } label: {
                Label("Start", systemImage: "play.fill").font(.system(size: 15))
            }
            .tint(Theme.accentActive)

        case .requestingAuthorization, .starting:
            ProgressView().padding(.vertical, 6)

        case .running, .stopping:
            Button {
                Task { await workout.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill").font(.system(size: 15))
            }
            .tint(Color(hex: 0x555555))
            .disabled(workout.state == .stopping)
        }
    }

    private var isStale: Bool {
        guard let lastUpdate = workout.lastUpdate else { return true }
        return now.timeIntervalSince(lastUpdate) > 10
    }

    private var freshness: String {
        guard let lastUpdate = workout.lastUpdate else { return String(localized: "no samples") }
        let ago = now.timeIntervalSince(lastUpdate)
        return ago < 2
            ? String(localized: "sampling")
            : String(localized: "\(Int(ago))s ago", comment: "Seconds since the last heart rate sample")
    }

    private var linkLabel: String {
        if case .failed = workout.state { return String(localized: "Error") }
        guard workout.state == .running else { return String(localized: "Stopped") }
        return workout.bridge.isReachable ? String(localized: "Linked") : String(localized: "No iPhone")
    }

    /// Green only when heart rate is genuinely reaching the phone. Anything
    /// else is deliberately not green, so the dot can be trusted on its own.
    private var linkColor: Color {
        if case .failed = workout.state { return Theme.accentAlert }
        guard workout.state == .running else { return Theme.textTertiary }
        return workout.bridge.isReachable ? Theme.accentActive : Theme.accentAlert
    }
}
