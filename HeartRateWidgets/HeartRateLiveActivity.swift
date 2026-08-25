import ActivityKit
import WidgetKit
import SwiftUI

/// Dynamic Island and Lock Screen presentation of the live broadcast.
///
/// The compact leading slot is a heart, the compact trailing slot the BPM —
/// which is the whole point: glance at the phone mid-ride and see the number
/// your head unit is being sent, without unlocking anything.
struct HeartRateLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HeartRateActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.white)
                .activitySystemActionForegroundColor(Color.black)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(heartGlyph).font(.system(size: 26))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(bpmText(context))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.source)
                        Spacer()
                        Text(subscriberText(context))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Text(heartGlyph).font(.system(size: 14))
            } compactTrailing: {
                Text(bpmText(context))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            } minimal: {
                Text(heartGlyph).font(.system(size: 12))
            }
        }
    }

    private func lockScreen(_ context: ActivityViewContext<HeartRateActivityAttributes>) -> some View {
        HStack(spacing: 14) {
            Text(heartGlyph).font(.system(size: 32))
            VStack(alignment: .leading, spacing: 2) {
                Text(bpmText(context))
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Self.ink)
                Text("\(context.state.source) · \(subscriberText(context))")
                    .font(.system(size: 12))
                    .foregroundStyle(Self.inkSecondary)
            }
            Spacer()
            Text(context.attributes.broadcastName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Self.inkSecondary)
        }
        .padding(16)
        // The Lock Screen renders this in the *system's* appearance, not the
        // app's. With the background tinted white, inherited label colours go
        // white-on-white in dark mode and the card looks blank — which is
        // exactly what it did. Every colour here is therefore explicit.
        .environment(\.colorScheme, .light)
    }

    /// Fixed, not semantic: this view has a white background in both
    /// appearances, so a colour that adapts is a colour that disappears.
    private static let ink = Color(red: 0.06, green: 0.06, blue: 0.08)
    private static let inkSecondary = Color(red: 0.42, green: 0.42, blue: 0.47)

    private var heartGlyph: String { "\u{2764}\u{FE0F}" }

    private func bpmText(_ context: ActivityViewContext<HeartRateActivityAttributes>) -> String {
        guard context.state.isLive, let bpm = context.state.bpm else { return "--" }
        return "\(bpm)"
    }

    /// Returns a String rather than a key because the caller on the lock screen
    /// interpolates it into a larger sentence, and a key cannot be interpolated
    /// into another key. Inflection still applies: `String(localized:)` reads the
    /// same markup, so the count agrees in languages with three plural forms
    /// (Russian, Polish, Czech) and none in the languages that have one (Japanese,
    /// Korean, Chinese, Thai, Vietnamese).
    private func subscriberText(_ context: ActivityViewContext<HeartRateActivityAttributes>) -> String {
        let n = context.state.subscriberCount
        return n == 0
            ? String(localized: "no head unit", comment: "Live Activity, nothing is receiving heart rate")
            : String(localized: "^[\(n) head unit](inflect: true)", comment: "Live Activity, how many receivers are connected")
    }
}
