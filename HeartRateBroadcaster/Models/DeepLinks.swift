import UIKit

/// Every route out of this app into iOS Settings or Health.
///
/// `UIApplication.openSettingsURLString` is the only documented deep link, and
/// it lands on this app's own page — where Bluetooth, Health, Live Activities,
/// notifications and Local Network all appear together. Everything else here is
/// a convenience on top of that, never a replacement for it.
enum DeepLinks {

    @MainActor
    static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        Task { _ = await UIApplication.shared.open(url) }
    }

    /// Health's own app, where *read* permission for heart rate is granted.
    ///
    /// This matters because an app cannot see, or ask again for, a read
    /// permission it has already been denied — HealthKit deliberately hides
    /// that to avoid leaking what data exists. The only fix is the user going
    /// to Health › Sharing › Apps, so send them there.
    ///
    /// `x-apple-health://` is undocumented, so the result is checked and the
    /// app's own settings page is used if it does not open. No
    /// `LSApplicationQueriesSchemes` entry is needed: only `canOpenURL` is
    /// gated by that list, and this deliberately does not call it.
    @MainActor
    static func openHealth() {
        Task {
            if let health = URL(string: "x-apple-health://"),
               await UIApplication.shared.open(health) {
                return
            }
            openAppSettings()
        }
    }
}
