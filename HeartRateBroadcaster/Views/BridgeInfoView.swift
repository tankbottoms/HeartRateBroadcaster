import SwiftUI
import UIKit

/// Everything the app knows about the link, on one screen.
///
/// Settings has some of this, but Settings is where you go to *change*
/// something. When a head unit will not see the phone, or sees it and shows no
/// heart rate, the question is not "what should I set" but "what is actually
/// true right now" — so the bridge row opens this instead: the GATT service it
/// publishes, every subscriber, both sensor paths, and the device and build
/// identifiers you would otherwise have to ask the user to read out.
struct BridgeInfoView: View {

    let manager: HeartRateManager
    @Environment(\.dismiss) private var dismiss

    /// Ages have to be recomputed, not observed — nothing changes when a value
    /// merely gets older.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var broadcaster: BLEBroadcaster { manager.broadcaster }
    private var bridge: PhoneSessionBridge { manager.bridge }
    private var settings: AppSettings { manager.settings }

    var body: some View {
        NavigationStack {
            Form {
                serviceSection
                subscriberSection
                transmissionSection
                sourceSection
                watchSection
                deviceSection
            }
            .navigationTitle("Bridge Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onReceive(tick) { now = $0 }
        }
    }

    // MARK: - Sections

    private var serviceSection: some View {
        Section {
            row("Status", stateLabel)
            row("Advertised name", broadcaster.advertisedName)
            row("Service", "Heart Rate · 0x180D")
            row("Characteristic", "Measurement · 0x2A37")
            row("Frames sent", "\(broadcaster.framesSent)")
            row("Frame rate", rateLabel)
            row("Last frame", broadcaster.lastFrameHex)
            row("Last sent", lastSentLabel)
        } header: {
            Text("Bluetooth Service")
        } footer: {
            Text("This phone appears to head units as a standard Bluetooth heart rate monitor. iOS moves the advertised service UUID into the packet overflow area when the app is backgrounded, so a head unit can only *discover* this phone while the app is on screen — an established connection survives backgrounding.")
        }
    }

    @ViewBuilder
    private var subscriberSection: some View {
        Section {
            if broadcaster.subscribers.isEmpty {
                Text("Nothing connected")
                    .foregroundStyle(Theme.textSecondary)
            } else {
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
            }
        } header: {
            Text("Connected Devices")
        } footer: {
            Text("Bluetooth gives a peripheral no way to read a central's name — the connection carries an identifier and a maximum packet size and nothing else. A head unit therefore appears here as a UUID assigned by this iPhone, stable for that device.")
        }
    }

    private var transmissionSection: some View {
        Section {
            row("Mode", settings.pushFrequency.label)
            row("Cadence", String(format: "%.2fs", manager.pushCadence))
            row("Hold window", String(format: "%.1fs", manager.holdWindow))
            row("Confidence", "\(manager.confidence)")
            row("Current value", manager.currentBPM.map { "\($0) BPM" } ?? String(localized: "None"))
            row("Sample age", sampleAgeLabel)
        } header: {
            Text("Transmission")
        } footer: {
            Text("The hold window is how long the last reading stays live after its source goes quiet, before the app calls it a problem. It is sized from the push cadence and grows with each consecutive good sample, so a single dropped beat cannot turn the status red.")
        }
    }

    private var sourceSection: some View {
        Section {
            row("Selected", settings.source.shortLabel)
            row("Resolved", manager.sourceLabel)
            row("AirPods", airPodsLabel)
            if let delta = manager.fusion.disagreement {
                row("Sensor gap", "\(delta) BPM")
            }
        } header: {
            Text("Sources")
        } footer: {
            Text("AirPods Pro 3 report heart rate only while a workout session is running on this iPhone, and presence is inferred from the audio route because iOS publishes no list of connected accessories.")
        }
    }

    private var watchSection: some View {
        Section {
            row("Paired", bridge.isPaired ? String(localized: "Yes") : String(localized: "No"))
            row("App", bridge.isWatchAppInstalled ? String(localized: "Installed") : String(localized: "Not installed"))
            row("Reachable", bridge.isReachable ? String(localized: "Yes") : String(localized: "No"))
            row("Streaming", bridge.isWatchStreaming ? String(localized: "Yes") : String(localized: "No"))
            if let name = bridge.watchName { row("Name", name) }
            if let system = bridge.watchSystemVersion { row("watchOS", system) }
            if let id = bridge.watchID { row("Identifier", id) }
        } header: {
            Text("Watch")
        } footer: {
            Text("iOS does not tell an app the name or identifier of the paired watch. These values are reported by the watch app itself and appear once it has connected at least once.")
        }
    }

    private var deviceSection: some View {
        Section {
            row("Device", UIDevice.current.model)
            row("iOS", UIDevice.current.systemVersion)
            row("App", appName)
            row("Bundle", Bundle.main.bundleIdentifier ?? "—")
            row("Version", shortVersion)
            row("Build", kBuildTag)
            row("Commit", kGitSHA)
        } header: {
            Text("Device & App")
        } footer: {
            Text("Quote the build and commit when reporting a problem — they identify the exact source this app was built from.")
        }
    }

    // MARK: - Row

    /// One line per fact whatever the length. Long identifiers scale down and
    /// truncate in the middle, because the ends of an identifier are the part
    /// worth reading.
    /// The title is a key; the value is not. This screen's values are facts
    /// rather than prose — hex frames, UUIDs, OS versions, a git SHA — and the
    /// handful that *are* prose are localized where they are built, below.
    /// Typing the value as a key here would force `.init(stringLiteral:)` onto
    /// fourteen call sites that are passing a genuine runtime string.
    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent {
            Text(value)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.middle)
        } label: {
            Text(title).lineLimit(1)
        }
    }

    // MARK: - Derived labels

    private var subscriberRows: [BLEBroadcaster.Subscriber] {
        broadcaster.subscribers.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private var stateLabel: String {
        switch broadcaster.state {
        case .idle:             return String(localized: "Idle")
        case .poweredOff:       return String(localized: "Bluetooth off")
        case .unauthorized:     return String(localized: "Unauthorized")
        case .unsupported:      return String(localized: "Unsupported")
        case .connected(let n): return String(localized: "Connected (\(n))",
                                              comment: "Bridge status with the number of subscribed head units in parentheses")
        case .advertising:      return String(localized: "Advertising")
        case .failed(let why):  return why
        }
    }

    private var isSending: Bool {
        guard let at = broadcaster.lastFrameAt else { return false }
        return now.timeIntervalSince(at) < max(3, manager.pushCadence * 3)
    }

    private var rateLabel: String {
        guard broadcaster.frameRate > 0 else { return "--" }
        let rate = String(format: "%.2f/s", broadcaster.frameRate)
        return isSending
            ? rate
            : String(localized: "\(rate) (paused)",
                     comment: "Frame rate followed by a note that sending has stalled")
    }

    private var lastSentLabel: String { ago(broadcaster.lastFrameAt, whenNever: String(localized: "Never")) }

    private var sampleAgeLabel: String { ago(manager.lastUpdate, whenNever: String(localized: "No samples yet")) }

    /// Both age rows phrase elapsed time identically, so they share one
    /// translation instead of drifting apart in twenty-four languages.
    private func ago(_ at: Date?, whenNever: String) -> String {
        guard let at else { return whenNever }
        let seconds = now.timeIntervalSince(at)
        guard seconds >= 1 else { return String(localized: "Just now") }
        return String(localized: "\(Int(seconds))s ago",
                      comment: "Elapsed seconds since something last happened")
    }

    private var airPodsLabel: String {
        switch manager.airPods.progress {
        case .stopped:                    return String(localized: "Not running")
        // Already localized where the failure is understood.
        case .unavailable(let why):       return why
        case .failed(let why):            return why
        case .requestingPermission:       return String(localized: "Requesting permission")
        case .startingSession:            return String(localized: "Starting session")
        case .connecting(let name):       return String(localized: "\(name) — starting",
                                                        comment: "AirPods model name, then that a session is starting")
        case .waitingForAirPods:          return String(localized: "None on the audio route")
        case .waitingForSample(let name): return String(localized: "\(name) — no sample yet",
                                                        comment: "AirPods model name, then that no reading has arrived")
        case .live(let bpm, let name):    return String(localized: "\(name) · \(bpm) BPM",
                                                        comment: "AirPods model name, then the current heart rate")
        }
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "HeartRate Broadcaster"
    }

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
