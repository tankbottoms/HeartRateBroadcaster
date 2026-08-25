import SwiftUI

/// Design tokens from `HeartRateBroadcaster_Spec_v2_Updated.md` §3 and
/// `HeartRateBroadcaster_Spec.md` §3.
///
/// The iOS app is a light, monochromatic grey/white surface. The watch app is
/// always dark (watchOS convention, and the watchOS spec §4 mandates it), so
/// every token that differs by platform resolves through `Theme.isWatch`.
enum Theme {

    #if os(watchOS)
    static let isWatch = true
    #else
    static let isWatch = false
    #endif

    // MARK: - Palette (raw)

    enum Palette {
        static let pureWhite    = Color(hex: 0xFFFFFF)
        static let lightGrey    = Color(hex: 0xF5F5F5)
        static let toggleOff    = Color(hex: 0xE5E5E5)
        static let mediumGrey   = Color(hex: 0xA3A3A3)
        static let secondary    = Color(hex: 0x666666)
        static let darkGrey     = Color(hex: 0x4A4A4A)
        static let nearBlack    = Color(hex: 0x1A1A1A)

        static let green        = Color(hex: 0x34C759)   // active / broadcasting
        static let red          = Color(hex: 0xFF3B30)   // error / alert
        static let blue         = Color(hex: 0x007AFF)   // links only
    }

    // MARK: - Semantic

    /// Screen background. White on both platforms.
    ///
    /// A white watch face costs battery on OLED — watchOS convention is black
    /// for exactly that reason — but it was asked for explicitly, and the watch
    /// is only lit while the app is frontmost.
    static var background: Color { Palette.pureWhite }

    /// Card / grouped-row surface. Needs to read *against* white, so the card
    /// is the tinted surface here rather than the background.
    static var surface: Color { Palette.lightGrey }

    /// Headings and high-contrast text.
    static var textPrimary: Color { Palette.nearBlack }

    /// Supporting copy, captions, help text.
    static var textSecondary: Color { Palette.secondary }

    /// Disabled controls and inert glyphs.
    static var textTertiary: Color { Palette.mediumGrey }

    /// The large BPM readout.
    static var heartRate: Color { Palette.nearBlack }

    static var accentActive: Color { Palette.green }
    static var accentAlert: Color { Palette.red }
    static var link: Color { Palette.blue }

    static var separator: Color { Palette.toggleOff }

    // MARK: - Glyph

    /// The heart is an emoji rather than an SF Symbol, so it carries its own
    /// colour and stays red against the white background on both platforms.
    static let heartGlyph = "\u{2764}\u{FE0F}"

    // MARK: - Typography

    enum Typeface {
        /// Large BPM readout — monospaced digits so the number does not jitter
        /// as the heart rate changes.
        static var heartRate: Font {
            .system(size: Theme.isWatch ? 68 : 88, weight: .light, design: .rounded)
                .monospacedDigit()
        }

        /// The small numbers in the workout strip under the BPM readout, and
        /// the same three on the session card. Monospaced digits for the same
        /// reason the big one is: watts move every second, and a proportional
        /// figure shuffles the whole row sideways as it does.
        static var metricValue: Font {
            .system(size: Theme.isWatch ? 15 : 17, weight: .semibold, design: .rounded)
                .monospacedDigit()
        }

        static var screenTitle: Font  { .system(size: 20, weight: .semibold) }
        static var sectionTitle: Font { .system(size: 13, weight: .semibold) }
        static var rowTitle: Font     { .system(size: 16, weight: .regular) }
        static var rowDetail: Font    { .system(size: 13, weight: .regular) }
        static var caption: Font      { .system(size: 12, weight: .regular) }
    }

    // MARK: - Metrics

    enum Metric {
        static let screenPadding: CGFloat = Theme.isWatch ? 8 : 16
        static let cardPadding: CGFloat = Theme.isWatch ? 10 : 16
        static let cardSpacing: CGFloat = 12
        static let sectionSpacing: CGFloat = 24
        static let cornerRadius: CGFloat = 12
        static let statusDot: CGFloat = 8
    }
}

extension Color {
    /// `Color(hex: 0x34C759)` — keeps the palette table readable against the spec.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: 1
        )
    }
}
