import SwiftUI
import ActivityKit
import CoreBluetooth
import HealthKit
import UserNotifications

/// One screen that answers "is this app allowed to do the thing it is failing
/// to do", with a way to fix each answer.
///
/// The permissions this app needs are spread across three different places in
/// iOS — Settings › Heart Rate Broadcaster, Health › Sharing › Apps, and the
/// system Bluetooth toggle — and a denial in any one of them produces the same
/// symptom: no heart rate. Collecting them here is the difference between a
/// two-minute fix and an evening of guessing.
struct PermissionsView: View {

    @Bindable var manager: HeartRateManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var healthRequest: HKAuthorizationRequestStatus?
    @State private var notifications: UNAuthorizationStatus?

    private let store = HKHealthStore()

    var body: some View {
        Form {
            Section {
                row(title: "Heart rate (read)",
                    value: healthReadValue,
                    ok: healthReadOK,
                    action: { DeepLinks.openHealth() })
                row(title: "Workouts (write)",
                    value: workoutShareValue,
                    ok: workoutShareOK,
                    action: { DeepLinks.openHealth() })
            } header: {
                Text("Health")
            } footer: {
                // This is the single most confusing permission in the app and
                // the reason the AirPods row can sit red forever.
                Text("HealthKit never tells an app whether a read permission was granted — a denial and an empty sensor look identical from here. If heart rate is not arriving, open Health › Sharing › Apps › Heart Rate Broadcaster and confirm Heart Rate is on.")
            }

            Section {
                row(title: "Bluetooth",
                    value: bluetoothValue,
                    ok: bluetoothOK,
                    action: { DeepLinks.openAppSettings() })
                row(title: "Broadcasting",
                    value: broadcastValue,
                    ok: broadcastOK,
                    action: nil)
            } header: {
                Text("Bluetooth")
            } footer: {
                Text("Broadcasting uses the Bluetooth peripheral role. Denying Bluetooth stops the app being visible to any head unit, regardless of the heart rate source.")
            }

            Section {
                row(title: "Live Activities",
                    value: liveActivityValue,
                    ok: liveActivityOK,
                    action: { DeepLinks.openAppSettings() })
                row(title: "Notifications",
                    value: notificationValue,
                    ok: notificationOK,
                    action: { DeepLinks.openAppSettings() })
            } header: {
                Text("Lock Screen")
            } footer: {
                Text("The Live Activity appears only while a head unit is connected and a reading is flowing. It is a connection notice, not a running feed of heart rate.")
            }

            Section {
                row(title: "Watch app",
                    value: manager.bridge.isWatchAppInstalled ? "Installed" : "Not installed",
                    ok: manager.bridge.isWatchAppInstalled,
                    action: nil)
                row(title: "Watch reachable",
                    value: manager.bridge.isReachable ? "Yes" : "No",
                    ok: manager.bridge.isReachable,
                    action: nil)
            } header: {
                Text("Watch")
            } footer: {
                Text("Heart rate permission on the watch is granted separately, on the watch, the first time its app runs.")
            }

            Section {
                Button {
                    DeepLinks.openAppSettings()
                } label: {
                    Label("Open in Settings", systemImage: "gear")
                }
                Button {
                    DeepLinks.openHealth()
                } label: {
                    Label("Open Health", systemImage: "heart.text.square")
                }
                Button {
                    Task { await manager.airPods.start() }
                } label: {
                    Label("Re-request Health access", systemImage: "arrow.clockwise")
                }
            } footer: {
                Text("iOS only shows a permission prompt the first time it is asked. After a denial, the toggles above are the only way to change the answer.")
            }
        }
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        // Coming back from Settings is exactly when these answers change, and
        // a screen that still shows the old ones is worse than no screen.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    // MARK: - Rows

    private func row(title: LocalizedStringKey, value: LocalizedStringKey, ok: Bool?, action: (() -> Void)?) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(value)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Circle()
                    .fill(dotColor(ok))
                    .frame(width: 8, height: 8)
            }
        } label: {
            if let action {
                Button(title, action: action)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textPrimary)
            } else {
                Text(title)
            }
        }
    }

    private func dotColor(_ ok: Bool?) -> Color {
        guard let ok else { return Theme.textTertiary }
        return ok ? Theme.accentActive : Theme.accentAlert
    }

    // MARK: - Values

    private var healthReadValue: LocalizedStringKey {
        switch healthRequest {
        case .none:            return "Checking…"
        case .some(.unnecessary): return "Asked"
        case .some(.shouldRequest): return "Not asked"
        default:               return "Unknown"
        }
    }

    /// Deliberately never red. "Asked" is the most iOS will admit to, and
    /// painting an unknown as a failure would send people to fix a setting that
    /// may already be correct.
    private var healthReadOK: Bool? {
        healthRequest == .unnecessary ? true : nil
    }

    private var workoutShareValue: LocalizedStringKey {
        switch store.authorizationStatus(for: HKQuantityType.workoutType()) {
        case .sharingAuthorized: return "Allowed"
        case .sharingDenied:     return "Denied"
        default:                 return "Not asked"
        }
    }

    private var workoutShareOK: Bool? {
        switch store.authorizationStatus(for: HKQuantityType.workoutType()) {
        case .sharingAuthorized: return true
        case .sharingDenied:     return false
        default:                 return nil
        }
    }

    private var bluetoothValue: LocalizedStringKey {
        switch CBManager.authorization {
        case .allowedAlways:  return "Allowed"
        case .denied:         return "Denied"
        case .restricted:     return "Restricted"
        default:              return "Not asked"
        }
    }

    private var bluetoothOK: Bool? {
        switch CBManager.authorization {
        case .allowedAlways:      return true
        case .denied, .restricted: return false
        default:                  return nil
        }
    }

    private var broadcastValue: LocalizedStringKey {
        switch manager.broadcaster.state {
        case .idle:            return "Off"
        case .poweredOff:      return "Bluetooth off"
        case .unauthorized:    return "Denied"
        case .unsupported:     return "Unsupported"
        case .advertising:     return "Advertising"
        case .connected(let n): return "^[\(n) device](inflect: true) connected"
        case .failed(let why): return .init(stringLiteral: why)
        }
    }

    private var broadcastOK: Bool? {
        switch manager.broadcaster.state {
        case .advertising, .connected: return true
        case .idle:                    return nil
        default:                       return false
        }
    }

    private var liveActivityValue: LocalizedStringKey {
        ActivityAuthorizationInfo().areActivitiesEnabled ? "Allowed" : "Off"
    }

    private var liveActivityOK: Bool? {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private var notificationValue: LocalizedStringKey {
        switch notifications {
        case .none:                  return "Checking…"
        case .some(.authorized):     return "Allowed"
        case .some(.provisional):    return "Provisional"
        case .some(.denied):         return "Denied"
        case .some(.ephemeral):      return "Temporary"
        default:                     return "Not asked"
        }
    }

    private var notificationOK: Bool? {
        switch notifications {
        case .some(.authorized), .some(.provisional), .some(.ephemeral): return true
        case .some(.denied): return false
        default:             return nil
        }
    }

    // MARK: - Refresh

    private func refresh() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        healthRequest = await healthRequestStatus()
    }

    /// The completion-handler form, wrapped by hand. It is the only way to ask
    /// about a *read* permission at all — `authorizationStatus(for:)` answers
    /// solely for types the app writes.
    private func healthRequestStatus() async -> HKAuthorizationRequestStatus? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let share: Set<HKSampleType> = [HKQuantityType.workoutType()]
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate)]
        return await withCheckedContinuation { continuation in
            store.getRequestStatusForAuthorization(toShare: share, read: read) { status, _ in
                continuation.resume(returning: status)
            }
        }
    }
}
