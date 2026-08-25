import SwiftUI

/// Page 3 — start a ride from the wrist, and say what kind it is.
///
/// Until now the sport was the phone's to choose and the watch only followed.
/// That is fine when the phone is the thing you press start on, and wrong the
/// moment it is in a jersey pocket. Starting here begins the watch's own
/// session and asks the phone to record the same ride, so a workout begun on
/// either device is one workout rather than two halves of one.
///
/// Rightmost on purpose: it is the page you use once, at the start, and the
/// live readout is the one you swipe back to for the next hour.
struct WatchStartView: View {

    let workout: WorkoutManager

    /// Cycling by default. Every other sport is a deliberate choice; this one is
    /// what the app is for.
    @State private var sport: WorkoutSport = .cycling

    var body: some View {
        VStack(spacing: 6) {
            Text("Start a workout")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            picker

            control
        }
        .padding(.horizontal, Theme.Metric.screenPadding)
        .padding(.bottom, 4)
        .onAppear {
            // Follow the phone if it has an opinion, so the two screens do not
            // disagree about what is being ridden before anyone has pressed
            // anything.
            if let phoneSport = workout.bridge.sportOnPhone { sport = phoneSport }
        }
    }

    /// A wheel rather than three buttons: three buttons plus a start button is
    /// four tap targets on a screen that fits two comfortably.
    private var picker: some View {
        Picker("Sport", selection: $sport) {
            ForEach(WorkoutSport.allCases) { option in
                Label(option.label, systemImage: option.glyph).tag(option)
            }
        }
        .labelsHidden()
        .frame(height: 60)
        .disabled(workout.state.isActive)
    }

    @ViewBuilder
    private var control: some View {
        switch workout.state {
        case .idle, .failed:
            Button {
                Task { await workout.start(sport: sport) }
            } label: {
                Label("Start", systemImage: "play.fill").font(.system(size: 15))
            }
            .tint(Theme.accentActive)

        case .requestingAuthorization, .starting:
            ProgressView().padding(.vertical, 6)

        case .running, .stopping:
            // Nothing to start, and a second Stop button one swipe from the
            // first would be a way to end a ride by accident. Say what is
            // running and send them back to the readout.
            VStack(spacing: 2) {
                Text("Running")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accentActive)
                Text("Swipe left for the readout")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 6)
        }
    }
}
