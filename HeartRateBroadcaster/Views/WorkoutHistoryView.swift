import SwiftUI

/// Every saved session, newest first. Deleting removes the app's copy; a
/// workout already written to Health stays there, which is the behaviour people
/// expect from anything that writes to Health.
struct WorkoutHistoryView: View {
    let store: WorkoutStore

    var body: some View {
        List {
            if store.records.isEmpty {
                Text("No workouts yet.")
                    .foregroundStyle(Theme.textTertiary)
                    .listRowBackground(Theme.surface)
            }
            ForEach(store.records) { record in
                NavigationLink {
                    SessionSummaryView(record: record)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.start.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(Theme.textPrimary)
                            Text(Self.clock.string(from: record.recordedDuration) ?? "")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Text("\(Int(record.activeKilocalories.rounded())) kcal")
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .onDelete { offsets in
                offsets.map { store.records[$0].id }.forEach(store.delete)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Workouts")
    }

    private static let clock: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f
    }()
}
