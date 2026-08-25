import SwiftUI

/// Discovery and pairing for power, cadence and trainer sensors.
///
/// Scanning stops when the screen goes away: a central scanning in the
/// background costs battery for no benefit, and the meters that matter are
/// already remembered by identifier.
///
/// The paired list is drawn from ``MeterRegistry/sources`` rather than from the
/// meters themselves, so a pair of pedals occupies one row and prints one
/// number. Sources are then split by where they sit on the bike, because a
/// question like "is the trainer reading higher than the pedals" is not
/// answerable from a single undifferentiated list.
struct PairedMetersView: View {
    let central: PowerMeterCentral
    let registry: MeterRegistry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.sectionSpacing) {
                if !registry.sources.isEmpty {
                    section("Pedals and cranks", sources(of: .cyclingPower))
                    section("Trainer", sources(of: .fitnessMachine))
                    section("Other sensors", sources(of: .speedCadence))

                    if registry.hasPowerCapableMeter {
                        SettingCard(title: "Follow the strongest",
                                    subtitle: "Mark whichever source is reading the most watts",
                                    help: "Pedals, a crank and a trainer all measure the same effort at different points in the drivetrain, so the highest reading is the one taken closest to your legs. With this on, the app starts the workout with the strongest source and moves the mark if another one is clearly and steadily ahead — not for a single spike. Choosing one by hand switches this off.") {
                            Toggle("", isOn: automaticBinding)
                                .labelsHidden()
                                .tint(Theme.accentActive)
                        }
                    }

                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4)
                }

                SectionHeading(title: "Nearby")
                Card {
                    if unpaired.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for sensors\u{2026}")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: Theme.Metric.cardSpacing) {
                            ForEach(unpaired) { found in
                                Button {
                                    registry.remember(found)
                                    central.connect(found.id)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(found.name)
                                                .font(Theme.Typeface.rowTitle)
                                                .foregroundStyle(Theme.textPrimary)
                                            Text(kindLabel(found.kind))
                                                .font(.caption)
                                                .foregroundStyle(Theme.textTertiary)
                                        }
                                        Spacer()
                                        Text("Pair")
                                            .foregroundStyle(Theme.link)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Bluetooth off is the single most common reason this screen
                // stays empty, and it is not something the app can fix silently.
                if central.availability != .ready {
                    Text(unavailableMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.accentAlert)
                        .padding(.horizontal, 4)
                }
            }
            .padding(Theme.Metric.screenPadding)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Sensors")
        .onAppear { central.startScanning() }
        .onDisappear { central.stopScanning() }
    }

    // MARK: - Sections

    /// A heading and a card, or nothing at all. An empty "Trainer" heading over
    /// an empty card says a trainer is missing; leaving the section out says
    /// only that there isn't one, which is the truth.
    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ list: [PowerSource]) -> some View {
        if !list.isEmpty {
            SectionHeading(title: title)
            Card {
                VStack(spacing: Theme.Metric.cardSpacing) {
                    ForEach(list) { source in
                        row(source)
                        if source.id != list.last?.id {
                            Divider().overlay(Theme.separator)
                        }
                    }
                }
            }
        }
    }

    private func sources(of kind: MeterKind) -> [PowerSource] {
        registry.sources.filter { $0.kind == kind }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ source: PowerSource) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.name)
                        .font(Theme.Typeface.rowTitle)
                        .foregroundStyle(Theme.textPrimary)
                    if source.isPair {
                        Text("PAIR")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                statusLine(source)
                    .font(.caption)
                    .foregroundStyle(isConnected(source) ? Theme.textSecondary : Theme.textTertiary)
                if source.isPair {
                    sideLine(source)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
            if source.measuresPower {
                Button {
                    registry.setPrimary(source.id)
                } label: {
                    badge(isPrimary: registry.primaryMeterID == source.id)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use for calories")
            }
            Button {
                // A pair is one row and two radios. Forgetting it has to take
                // both, or the surviving half reappears under Nearby as half a
                // pedal meter with no partner to be added to.
                for id in source.memberIDs {
                    central.disconnect(id)
                    registry.forget(id)
                }
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(Theme.accentAlert)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Forget")
            .padding(.leading, 8)
        }
    }

    /// A word rather than a star. Three meters and one filled star out of three
    /// reads as a rating, and invites the question of what two stars would
    /// mean; the answer is that there is no such thing, because the choice is
    /// one source and everything else standing by.
    @ViewBuilder
    private func badge(isPrimary: Bool) -> some View {
        Text(isPrimary ? "PRIMARY" : "BACKUP")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isPrimary ? Theme.background : Theme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(isPrimary ? Theme.accentActive : Color.clear)
                    .overlay {
                        Capsule().stroke(isPrimary ? Color.clear : Theme.separator, lineWidth: 1)
                    }
            }
    }

    /// Live status is read from the central rather than stored on the meter, so
    /// `PairedMeter` stays a plain persisted value with nothing in it that goes
    /// stale on disk.
    @ViewBuilder
    private func statusLine(_ source: PowerSource) -> some View {
        if !isConnected(source) {
            Text("Not connected")
        } else if let watts = registry.watts(of: source, at: Date()) {
            // The smoothed figure is shown only while the app is choosing, because
            // that is the number the choice is actually made on: three sources can
            // all read 200 W this second and still be far apart on average.
            if registry.automaticPrimary, let average = registry.smoothedWatts(for: source.id) {
                Text("\(watts) W · \(average) W average")
            } else {
                Text("\(watts) W")
            }
        } else {
            Text("Connected")
        }
    }

    /// What each pedal is putting in, under the total the row prints — so a
    /// number that looks wrong can be traced to the side producing it without
    /// unpairing anything.
    @ViewBuilder
    private func sideLine(_ source: PowerSource) -> some View {
        if case let .pedalPair(left, right) = source.shape {
            if registry.isEstimatingFromOneSide(source, at: Date()) {
                Text("One side only — doubled")
            } else {
                Text("L \(sideWatts(left)) W · R \(sideWatts(right)) W")
            }
        }
    }

    private func sideWatts(_ id: UUID) -> Int {
        registry.rawWatts(for: id) ?? 0
    }

    /// A pair counts as connected while either radio is up, because that is when
    /// it is still producing a number.
    private func isConnected(_ source: PowerSource) -> Bool {
        source.memberIDs.contains { central.connected.contains($0) }
    }

    // MARK: - Supporting copy

    /// `registry.automaticPrimary` is settable, but a `Toggle` needs a binding
    /// and the registry is a class the view only holds a reference to.
    private var automaticBinding: Binding<Bool> {
        Binding(get: { registry.automaticPrimary },
                set: { registry.automaticPrimary = $0 })
    }

    private var footnote: LocalizedStringKey {
        registry.automaticPrimary
            ? "The source marked PRIMARY drives the energy figure; the rest are recorded but stand by. Meters on different parts of the drivetrain read differently — that is the drivetrain, not an error, and the app follows the one reading highest. A left and right pedal are one source and are added together."
            : "The source marked PRIMARY drives the energy figure; the rest are recorded but stand by. Meters on different parts of the drivetrain read differently — that is the drivetrain, not an error. A left and right pedal are one source and are added together."
    }

    /// A meter already in the paired list has its own row above; showing it
    /// again under Nearby would offer to pair something that is paired.
    private var unpaired: [PairedMeter] {
        let known = Set(registry.paired.map(\.id))
        return central.discovered.filter { !known.contains($0.id) }
    }

    private var unavailableMessage: LocalizedStringKey {
        switch central.availability {
        case .off: "Bluetooth is off. Turn it on to find sensors."
        case .unauthorized: "HeartRate Broadcaster needs Bluetooth permission to find sensors."
        case .unsupported: "This device cannot connect to Bluetooth sensors."
        case .unknown, .ready: "Starting Bluetooth\u{2026}"
        }
    }

    private func kindLabel(_ kind: MeterKind) -> LocalizedStringKey {
        switch kind {
        case .cyclingPower: "Power meter"
        case .speedCadence: "Speed and cadence"
        case .fitnessMachine: "Trainer"
        }
    }
}
