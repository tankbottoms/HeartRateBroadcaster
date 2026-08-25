import SwiftUI

/// Start, stop, and what the ride looks like while it runs.
///
/// The sport is chosen before Start and cannot change afterwards, because
/// HealthKit fixes the activity type when the session is created and there is
/// only one session available on the device.
struct SessionControlCard: View {
    let recorder: WorkoutRecorder
    let registry: MeterRegistry
    @Binding var chosenSport: WorkoutSport
    var onFinished: (WorkoutRecord) -> Void

    @State private var isBusy = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Metric.cardSpacing) {
                if recorder.state.isLive {
                    liveReadout
                } else {
                    Picker("Sport", selection: $chosenSport) {
                        ForEach(WorkoutSport.allCases) { sport in
                            Text(sportLabel(sport)).tag(sport)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isBusy)
                }

                Button {
                    Task { await toggle() }
                } label: {
                    Text(recorder.state.isLive ? "Stop workout" : "Start workout")
                        .font(Theme.Typeface.rowTitle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(recorder.state.isLive ? Theme.accentAlert : Theme.accentActive,
                                    in: RoundedRectangle(cornerRadius: Theme.Metric.cornerRadius))
                        .foregroundStyle(Theme.Palette.pureWhite)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                // The screenshot runner needs a handle that does not change
                // when the button's own label flips between Start and Stop.
                .accessibilityIdentifier("session-toggle")
            }
        }
        .onAppear {
            // A power meter on the bike says what this session is better than
            // whatever was picked last week.
            if !recorder.state.isLive, registry.hasPowerCapableMeter {
                chosenSport = .cycling
            }
        }
    }

    @ViewBuilder
    private var liveReadout: some View {
        HStack(alignment: .firstTextBaseline) {
            metric(value: Self.clock.string(from: recorder.elapsed) ?? "0:00", label: "Time")
            Spacer()
            metric(value: recorder.currentWatts.map { "\($0)" } ?? "--", label: "Watts")
            Spacer()
            metric(value: "\(Int(recorder.runningKilocalories.rounded()))", label: "Calories")
        }

        if recorder.energySource == .heartRate {
            Text("Estimated from heart rate — no power meter reporting.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// The strip at the top of the screen shows the same clock, so both read
    /// from one formatter rather than two configured alike by hand.
    private static let clock = WorkoutMetricsStrip.clock

    @ViewBuilder
    private func metric(value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Theme.Typeface.sectionTitle)
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func toggle() async {
        isBusy = true
        defer { isBusy = false }
        if recorder.state.isLive {
            if let record = await recorder.end() { onFinished(record) }
        } else {
            await recorder.begin(sport: chosenSport)
        }
    }

    /// The picker, the metrics strip and the watch all name the sport the same
    /// way, so the word comes from the sport itself.
    private func sportLabel(_ sport: WorkoutSport) -> LocalizedStringKey { sport.label }
}
