import SwiftUI

/// The language row, shared by About and Settings so the two cannot drift.
///
/// Bound to an optional: `nil` is "follow the device", which is the default and
/// the row people should mostly leave alone. Choosing anything else takes effect
/// on selection — see `AppLanguage` for why no restart is needed.
///
/// The endonyms are not translated and not sorted alphabetically. They stay in
/// the app's own listing order so the list is identical in every language, which
/// matters when the reason you are here is that the interface is currently in a
/// language you cannot read.
struct LanguagePicker: View {

    @Bindable var settings: AppSettings

    var body: some View {
        Picker(selection: $settings.preferredLanguage) {
            Text("System (\(AppLanguage.systemEndonym))").tag(String?.none)
            ForEach(AppLanguage.all, id: \.code) { lang in
                Text(verbatim: lang.endonym).tag(String?.some(lang.code))
            }
        } label: {
            Text("Language")
        }
        .accessibilityIdentifier("language-picker")
    }
}
