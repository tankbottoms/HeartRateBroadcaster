import SwiftUI

@main
struct HeartRateBroadcasterApp: App {

    @State private var manager = HeartRateManager()

    var body: some Scene {
        WindowGroup {
            ContentView(manager: manager)
                .onAppear { manager.onAppear() }
                // The in-app language override, applied once at the root of the
                // scene. Every `LocalizedStringKey` below this — including the
                // ones inside sheets, which inherit the environment from the
                // view that presents them — resolves against it, so switching
                // language retranslates the running interface without a restart.
                .environment(\.locale, AppLanguage.locale(for: manager.settings.preferredLanguage))
                .environment(\.layoutDirection,
                             AppLanguage.layoutDirection(for: manager.settings.preferredLanguage)
                                ?? layoutDirection)
        }
    }

    /// The process-wide direction iOS set from the device language, used
    /// whenever there is no override to impose a different one.
    private var layoutDirection: LayoutDirection {
        UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }
}
