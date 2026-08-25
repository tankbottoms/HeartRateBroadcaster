import SwiftUI

/// What the ride came to. Shown once when a session ends and again from
/// history.
///
/// Gaps and an incomplete body profile are stated in words rather than hidden,
/// because a calorie figure the user cannot audit is worse than one with a
/// caveat attached.
struct SessionSummaryView: View {
    let record: WorkoutRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.sectionSpacing) {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        // `verbatim` — a bare number is not a phrase, and
                        // extracting "%lld" as a translation unit asks
                        // twenty-four translators to retype a placeholder.
                        Text(verbatim: "\(Int(record.activeKilocalories.rounded()))")
                            .font(Theme.Typeface.heartRate)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Active calories")
                            .foregroundStyle(Theme.textSecondary)
                        Text("\(Int(record.totalKilocalories.rounded())) total, including resting")
                            .font(.footnote)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                Card {
                    VStack(spacing: Theme.Metric.cardSpacing) {
                        row("Duration", Self.clock.string(from: record.recordedDuration) ?? "--")
                        row("Sport", sportLabel)
                        if let watts = record.averagePower {
                            row("Average power", "\(Int(watts.rounded())) W")
                        }
                        if let peak = record.maximumPower {
                            row("Peak power", "\(peak) W")
                        }
                        if let bpm = record.averageHeartRate {
                            row("Average heart rate", "\(bpm) bpm")
                        }
                        if let cadence = record.averageCadence {
                            row("Average cadence", "\(Int(cadence.rounded())) rpm")
                        }
                        if record.totalKilojoules > 0 {
                            row("Work", "\(Int(record.totalKilojoules.rounded())) kJ")
                        }
                    }
                }

                if record.meterTotals.count > 1 {
                    SectionHeading(title: "Sensors")
                    Card {
                        VStack(spacing: Theme.Metric.cardSpacing) {
                            ForEach(record.meterTotals, id: \.meterID) { totals in
                                HStack {
                                    Text(totals.meterName)
                                        .foregroundStyle(Theme.textSecondary)
                                    if totals.meterID == record.primaryMeterID {
                                        Text("(counted)")
                                            .font(.caption)
                                            .foregroundStyle(Theme.accentActive)
                                    }
                                    Spacer()
                                    Text("\(Int(totals.averageWatts.rounded())) W")
                                        .foregroundStyle(Theme.textPrimary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                    Text("Sensors read differently because they measure at different points in the drivetrain.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4)
                }

                // Loose red sentences under the numbers read as errors. Inside a
                // titled card they read as what they are: the conditions the
                // figure above was measured under.
                if hasNotes {
                    SectionHeading(title: "Notes")
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Metric.cardSpacing) {
                            if !record.gaps.isEmpty {
                                note("exclamationmark.triangle",
                                     "\(record.gaps.count) dropouts, \(Int(record.gapDuration.rounded())) seconds excluded",
                                     tint: Theme.accentAlert)
                            }
                            if !record.profileWasComplete {
                                note("person.crop.circle.badge.questionmark",
                                     "Rough estimate — fill in your body details for a better figure.",
                                     tint: Theme.accentAlert)
                            }
                            if record.savedToHealth {
                                note("heart.text.square",
                                     "Saved to Health.",
                                     tint: Theme.textTertiary)
                            }
                        }
                    }
                }
            }
            .padding(Theme.Metric.screenPadding)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(record.start.formatted(date: .abbreviated, time: .shortened))
    }

    private var hasNotes: Bool {
        !record.gaps.isEmpty || !record.profileWasComplete || record.savedToHealth
    }

    /// One line of the Notes card. The icon carries the severity so the colour
    /// is not the only thing saying "this one is a caveat".
    private func note(_ icon: String, _ text: LocalizedStringKey, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .font(.footnote)
                .foregroundStyle(tint == Theme.accentAlert ? Theme.textSecondary : Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let clock: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .positional
        f.zeroFormattingBehavior = .pad
        return f
    }()

    private var sportLabel: String {
        switch record.sport {
        case .cycling: String(localized: "Cycle")
        case .running: String(localized: "Run")
        case .swimming: String(localized: "Swim")
        }
    }

    @ViewBuilder
    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).foregroundStyle(Theme.textPrimary).monospacedDigit()
        }
    }
}
