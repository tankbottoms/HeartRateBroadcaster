import Foundation
import SwiftUI

/// The in-app language override.
///
/// iOS has its own per-app language control in Settings, and it is the better
/// one — it restarts the app cleanly and it also relabels the notifications and
/// the Live Activity, which this cannot. But that row only appears once iOS has
/// decided the app is worth offering it for, and on a fresh install of a build
/// that has never run in another language it frequently is not there at all.
/// This exists so the twenty-five translations are reachable without hunting for
/// a row that may not have appeared yet.
///
/// The mechanism is `EnvironmentValues.locale`. SwiftUI resolves every
/// `LocalizedStringKey` against the environment locale at render time, so
/// setting it at the root of the scene retranslates the whole interface live —
/// no restart, and no call site has to pass a bundle.
///
/// What it does *not* reach: strings built with `String(localized:)` in the
/// model layer, which resolve against the system locale rather than the
/// environment. Those are the Live Activity and widget labels, and they are
/// correct to leave on the system language — they render outside this app's
/// process, next to iOS's own text.
enum AppLanguage {

    /// Code, endonym. The order is the App Store's own listing order, which is
    /// roughly by market size, and the endonyms are deliberately not translated:
    /// someone looking for their own language is looking for the word they call
    /// it, not for what the current language calls it.
    ///
    /// Kept in step with `scripts/locales.ts`, which is the source of truth for
    /// the same list on the store listing and the website.
    static let all: [(code: String, endonym: String)] = [
        ("en", "English"),
        ("de", "Deutsch"),
        ("fr", "Français"),
        ("it", "Italiano"),
        ("es", "Español (España)"),
        ("nl", "Nederlands"),
        ("ja", "日本語"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("ko", "한국어"),
        ("sv", "Svenska"),
        ("da", "Dansk"),
        ("nb", "Norsk bokmål"),
        ("fi", "Suomi"),
        ("pl", "Polski"),
        ("cs", "Čeština"),
        ("pt-BR", "Português (Brasil)"),
        ("es-MX", "Español (México)"),
        ("ru", "Русский"),
        ("uk", "Українська"),
        ("tr", "Türkçe"),
        ("ar", "العربية"),
        ("th", "ไทย"),
        ("id", "Bahasa Indonesia"),
        ("vi", "Tiếng Việt"),
    ]

    /// The languages iOS actually resolved for this launch, best match first.
    /// Used only to label the System row, so someone who has never changed the
    /// setting can see which of the twenty-five they are already reading.
    static var systemEndonym: String {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        return all.first { $0.code == preferred }?.endonym
            ?? all.first { $0.code.hasPrefix(preferred.prefix(2)) }?.endonym
            ?? preferred
    }

    /// `nil` means follow the device. Anything else is one of the codes above;
    /// an unrecognised code falls back to the device rather than to English,
    /// because a stale override should never be more disruptive than no
    /// override.
    static func locale(for code: String?) -> Locale {
        guard let code, all.contains(where: { $0.code == code }) else { return .autoupdatingCurrent }
        return Locale(identifier: code)
    }

    /// SwiftUI does not derive writing direction from the environment locale, so
    /// choosing Arabic would otherwise translate the text and leave the layout
    /// mirrored the wrong way. Only the override needs this — when following the
    /// device, iOS has already set the direction for the whole process.
    static func layoutDirection(for code: String?) -> LayoutDirection? {
        guard let code else { return nil }
        return Locale.Language(identifier: code).characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }
}
