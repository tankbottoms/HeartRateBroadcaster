import SwiftUI

struct SettingsView: View {

    @Bindable var manager: HeartRateManager
    @Environment(\.dismiss) private var dismiss

    /// "Last sent" is time-derived, so it needs its own heartbeat — otherwise it
    /// only refreshes when some other observable property happens to change.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var settings: AppSettings { manager.settings }
    private var broadcaster: BLEBroadcaster { manager.broadcaster }

    /// Sorted so rows do not shuffle as the dictionary rehashes.
    private var subscriberRows: [BLEBroadcaster.Subscriber] {
        broadcaster.subscribers.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// `--` is reserved for "never measured". Once a rate has been observed it
    /// stays on screen and is qualified as paused, because the last known rate
    /// is the useful number when you are trying to work out why sending stopped.
    private var rateLabel: String {
        guard broadcaster.frameRate > 0 else { return "--" }
        let rate = String(format: "%.2f/s", broadcaster.frameRate)
        return isSending ? rate : "\(rate) (paused)"
    }

    /// Two missed 1 Hz frames — long enough not to flicker on a single late
    /// send, short enough to notice a stall.
    private var isSending: Bool {
        guard let at = broadcaster.lastFrameAt else { return false }
        return now.timeIntervalSince(at) < 3
    }

    /// One row, one line, whatever the value.
    ///
    /// `LabeledContent` is used unstyled on purpose: the value picks up the
    /// same secondary treatment as every Yes / No / Installed elsewhere in this
    /// form, so the watch rows read as part of the same table rather than as a
    /// separate widget. Identity is a long opaque string and would otherwise
    /// wrap to three lines, so it scales down and truncates in the middle —
    /// the ends of an identifier are the part worth keeping.
    private func watchRow(_ title: LocalizedStringKey, _ value: LocalizedStringKey) -> some View {
        LabeledContent {
            Text(value)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.middle)
        } label: {
            Text(title).lineLimit(1)
        }
    }

    /// The number currently loaded into the characteristic, which is not the
    /// same question as whether it is being sent.
    private var valueLabel: String {
        guard broadcaster.hasValue, let bpm = manager.currentBPM else { return "None" }
        return "\(bpm) BPM"
    }

    private var broadcastExplanation: LocalizedStringKey {
        switch broadcaster.state {
        case .poweredOff:
            return "Bluetooth is off, so nothing is being advertised. Turn it on in Control Center."
        case .unauthorized:
            return "Bluetooth access is denied, so this phone cannot advertise. Allow it in Settings › Privacy › Bluetooth."
        case .unsupported:
            return "This device cannot act as a Bluetooth peripheral."
        case .idle:
            return "The bridge is off. Turn on Heart Rate Bridge to start advertising."
        case .failed(let why):
            return .init(stringLiteral: why)
        case .advertising:
            return "Advertising, but nothing has subscribed yet — frames stay at zero until a head unit connects. Keep the app on screen while it searches: iOS hides a backgrounded app's service UUID from generic scans."
        case .connected(let count):
            guard broadcaster.hasValue else {
                return "Connected to ^[\(count) device](inflect: true), but there is no heart rate to send, so no frames are going out. Start the watch app, put in AirPods Pro 3, or set the source to Test."
            }
            return "Sending to ^[\(count) device](inflect: true). Frame rate is measured over a rolling window — a head unit showing no heart rate while this reads about 1.0/s is a problem at the head unit, not here."
        }
    }

    private var lastSentLabel: String {
        guard let at = broadcaster.lastFrameAt else { return "Never" }
        let ago = now.timeIntervalSince(at)
        return ago < 1 ? "Just now" : String(format: "%.0fs ago", ago)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Broadcast name", text: Binding(
                        get: { settings.advertisedName },
                        set: { settings.advertisedName = String($0.prefix(10)) }
                    ))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                } header: {
                    Text("Broadcast Name")
                } footer: {
                    Text("Shown on your bike computer's sensor list. The Bluetooth advertising packet is only 31 bytes, so this is capped at 10 characters.")
                }

                Section {
                    Picker("Push Frequency", selection: Binding(
                        get: { settings.pushFrequency },
                        set: { settings.pushFrequency = $0 }
                    )) {
                        ForEach(AppSettings.PushFrequency.allCases) { Text($0.label).tag($0) }
                    }
                    if settings.pushFrequency == .fixed {
                        VStack(alignment: .leading) {
                            Text("Every \(String(format: "%.1f", settings.fixedInterval))s")
                                .font(Theme.Typeface.rowDetail)
                                .foregroundStyle(Theme.textSecondary)
                            Slider(value: Binding(
                                get: { settings.fixedInterval },
                                set: { settings.fixedInterval = $0 }
                            ), in: 0.5...5.0, step: 0.5)
                        }
                    }
                } header: {
                    Text("Transmission")
                } footer: {
                    Text("Auto forwards each reading the moment it arrives. Fixed resends the most recent reading on a steady cadence, which some older head units prefer.")
                }

                Section {
                    NavigationLink("Sensors") {
                        PairedMetersView(central: manager.central, registry: manager.meters)
                    }
                    .accessibilityIdentifier("sensors-link")
                    NavigationLink("Body") {
                        BodyProfileView(settings: settings)
                    }
                    // A handle for the screenshot runner that survives being
                    // translated into twenty-four other languages.
                    .accessibilityIdentifier("body-link")
                    NavigationLink("Workouts") {
                        WorkoutHistoryView(store: manager.workoutStore)
                    }
                } header: {
                    Text("Workouts")
                } footer: {
                    Text("Power, cadence and trainer sensors, your body details for the calorie figure, and every session you have saved.")
                }

                Section {
                    Toggle("Save Rides to Health", isOn: Binding(
                        get: { settings.savesWorkoutsToHealth },
                        set: { settings.savesWorkoutsToHealth = $0 }
                    ))
                    if settings.savesWorkoutsToHealth {
                        Toggle("Include Calories", isOn: Binding(
                            get: { settings.savesEnergyToHealth },
                            set: { settings.savesEnergyToHealth = $0 }
                        ))
                    }
                } header: {
                    Text("Apple Health")
                } footer: {
                    // The duplicate this prevents is a real one and worth naming:
                    // a ride that goes out to MyWhoosh, comes back through Strava
                    // as a FIT with the route on it, and lands in Health next to
                    // the copy this app saved is the same hour counted twice.
                    Text("""
                    Turn Save Rides off if your ride reaches Health another way — \
                    MyWhoosh publishing to Strava, and Strava writing back — so the \
                    same hour is not counted twice against your rings. \
                    Nothing else changes: the ride is still in this app's own \
                    history, and heart rate, power and shifting still go out to \
                    whatever you are riding into.

                    Power and cadence are never written to Health by this app in \
                    any case. They are in the session summary here, and in the \
                    file your cycling app records.
                    """)
                }

                Section {
                    LabeledContent("Bluetooth", value: stateLabel)
                    LabeledContent("Advertising as", value: settings.advertisedName)
                    LabeledContent("Service", value: "Heart Rate · 0x180D")
                    LabeledContent("Subscribers", value: "\(broadcaster.subscriberCount)")
                    LabeledContent("Value", value: valueLabel)
                    LabeledContent("Frames sent", value: "\(broadcaster.framesSent)")
                    LabeledContent("Frame rate", value: rateLabel)
                    LabeledContent("Last frame", value: broadcaster.lastFrameHex)
                    LabeledContent("Last sent", value: lastSentLabel)
                } header: {
                    Text("Broadcast")
                } footer: {
                    // Zeroes here are the normal reading for most of a session
                    // and used to look like the section had stopped working.
                    // Nothing is sent until a head unit subscribes *and* there
                    // is a heart rate to send, so say which of the two is
                    // missing rather than leaving a row of dashes to interpret.
                    Text(broadcastExplanation)
                }

                if !broadcaster.subscribers.isEmpty {
                    Section {
                        ForEach(subscriberRows) { sub in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sub.id.uuidString)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("\(sub.framesSent) frames · MTU \(sub.maximumUpdateValueLength) bytes")
                                    .font(Theme.Typeface.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Connected Devices")
                    } footer: {
                        Text("Identifiers are assigned by this iPhone and are stable per device. Bluetooth does not give a peripheral the central's name, so MyWhoosh appears here as an identifier rather than a label.")
                    }
                }

                // Hidden where WatchConnectivity does not exist at all — on an
                // iPad every row here reads No / Not installed forever, which
                // looks like a broken watch rather than a device that cannot
                // pair one.
                if manager.bridge.isSupported {
                    Section {
                        // Titles are unprefixed because the section is already
                        // called Watch — "Watch streaming" inside a Watch section
                        // is the redundancy that pushed these rows into wrapping.
                        watchRow("Paired", manager.bridge.isPaired ? "Yes" : "No")
                        watchRow("App", manager.bridge.isWatchAppInstalled ? "Installed" : "Not installed")
                        watchRow("Reachable", manager.bridge.isReachable ? "Yes" : "No")
                        watchRow("Streaming", manager.bridge.isWatchStreaming ? "Yes" : "No")
                        if let detail = manager.bridge.watchIdentityDetail {
                            // Assembled and localized by the bridge.
                            watchRow("Identity", .init(stringLiteral: detail))
                        }
                    } header: {
                        Text("Watch")
                    } footer: {
                        Text(manager.bridge.watchIdentityDetail == nil
                             ? "iOS does not tell an app the name or identifier of the paired watch. Identity appears here once the watch app has connected at least once."
                             : "Reported by the watch app itself.")
                    }
                }

                Section {
                    NavigationLink {
                        PermissionsView(manager: manager)
                    } label: {
                        // See the note in ContentView's toolbar: the screenshot
                        // runner needs a handle that survives translation.
                        //
                        // On the label, not on the NavigationLink. A `List` row
                        // builds its accessibility element out of the label and
                        // an identifier set on the link itself never reaches the
                        // tree — the query for it found nothing at all, in any
                        // element type, until this moved inside.
                        Label("Permissions & Access", systemImage: "checklist")
                            .accessibilityIdentifier("permissions-link")
                    }
                } footer: {
                    Text("Every permission this app needs, what it is currently set to, and a direct link to change it.")
                }

                Section {
                    LanguagePicker(settings: settings)
                } header: {
                    Text("Language")
                } footer: {
                    // iOS has its own per-app language control, but the row only
                    // appears in Settings once iOS decides to offer it and on a
                    // fresh install it often has not. This one is always here.
                    Text("Applies to this app only, and takes effect immediately. Leave it on System to follow your device. The Live Activity and notifications stay in the device language, because they are drawn by iOS rather than by this app.")
                }

                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        settings.resetToDefaults()
                        manager.applySettings()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings-done")
                }
            }
            .onDisappear { manager.applySettings() }
            .onReceive(tick) { now = $0 }
        }
    }

    /// Deliberately the same six phrases as `BridgeInfoView.stateLabel`, so the
    /// two screens share one set of translations rather than acquiring two
    /// slightly different words for the same state in twenty-four languages.
    private var stateLabel: String {
        switch manager.broadcaster.state {
        case .idle:             return String(localized: "Idle")
        case .poweredOff:       return String(localized: "Powered off")
        case .unauthorized:     return String(localized: "Unauthorized")
        case .unsupported:      return String(localized: "Unsupported")
        case .advertising:      return String(localized: "Advertising")
        case .connected(let n): return String(localized: "Connected (\(n))",
                                              comment: "Bridge status with the number of subscribed head units in parentheses")
        // Already localized where it was built.
        case .failed(let why):  return why
        }
    }
}
