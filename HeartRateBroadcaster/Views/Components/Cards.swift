import SwiftUI

// MARK: - Section heading

struct SectionHeading: View {
    // LocalizedStringKey rather than String throughout this file. It means every
    // literal passed in by a caller is a translation unit automatically, with no
    // change at the call site, and it makes the non-literal cases fail to compile
    // instead of silently shipping English.
    let title: LocalizedStringKey
    var body: some View {
        // .textCase rather than .uppercased(): uppercasing in Swift would force
        // the key back to a String before lookup, and several languages here do
        // not uppercase the way English does. Turkish dotted/dotless i is the
        // classic trap, and Greek drops accents when uppercased.
        Text(title)
            .textCase(.uppercase)
            .font(Theme.Typeface.sectionTitle)
            .kerning(0.6)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

// MARK: - Card container

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(Theme.Metric.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Metric.cornerRadius))
    }
}

// MARK: - Prose that does not move the furniture

/// Explanatory text in a box of a fixed height, scrollable when it overflows.
///
/// Status lines are the longest strings in the app and the least predictable: a
/// row reads "Off" in one state, three wrapped lines in the next, and four of
/// them in German. Sized to their contents they push everything below them up
/// and down the screen, which is merely untidy in the settings and genuinely
/// annoying when the thing being pushed is the shift button you are reaching
/// for at threshold.
///
/// So the box is as tall as `rows` lines of its own font, always, and longer
/// text scrolls inside it rather than growing.
struct ScrollingText: View {
    let text: LocalizedStringKey
    var rows: Int = 3
    var font: Font = Theme.Typeface.caption
    var color: Color = Theme.textSecondary
    var alignment: TextAlignment = .leading

    var body: some View {
        // The hidden line is what sets the height: same font, held to exactly
        // `rows` lines with the space reserved. That makes the box as tall as
        // the system thinks that many lines are, at whatever type size the
        // rider has chosen, rather than a constant measured once on one phone.
        // It has to be widened by hand as well: an overlay is laid out at the
        // size of what it sits on, and one space is one character wide, which
        // puts the entire message in a column down the left-hand edge.
        Text(verbatim: " ")
            .font(font)
            .lineLimit(rows, reservesSpace: true)
            .frame(maxWidth: .infinity)
            .hidden()
            .overlay {
                ScrollView(.vertical) {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .multilineTextAlignment(alignment)
                        .frame(maxWidth: .infinity,
                               alignment: alignment == .center ? .center : .leading)
                }
                // No rubber-banding on text that already fits, which would read
                // as a scrollable region with nothing in it.
                .scrollBounceBehavior(.basedOnSize)
            }
    }
}

// MARK: - Live heart rate

struct HRDisplayCard: View {
    let bpm: Int?
    let isStale: Bool
    let isBeating: Bool
    /// Seconds since the last sample actually arrived. nil when nothing has.
    var sampleAge: TimeInterval? = nil
    /// Stays a String: it is a sensor name resolved at runtime, not a phrase.
    var sourceLabel: String? = nil
    /// Per-sensor detail when more than one is live. nil the rest of the time —
    /// there is nothing to reconcile with a single sensor, and an empty line
    /// under the age would just be noise.
    var reconciliation: LocalizedStringKey? = nil
    /// The workout numbers, drawn under the heart rate while a session is
    /// running. nil when there is no session: an idle strip of zeroes reads as
    /// a workout that is going badly rather than one that has not started.
    var metrics: WorkoutMetricsStrip? = nil

    var body: some View {
        Card {
            VStack(spacing: 2) {
                HStack(alignment: .center, spacing: 12) {
                    // Beats at 60/bpm, so the animation *is* the reading rather
                    // than a decorative pulse running at a fixed rate.
                    BeatingHeart(bpm: bpm, isLive: isBeating && !isStale, size: 38)
                    Text(bpm.map(String.init) ?? "--")
                        .font(Theme.Typeface.heartRate)
                        .foregroundStyle(isStale ? Theme.textTertiary : Theme.heartRate)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: bpm)
                        // For the screenshot runner, which waits for this to
                        // change and then shoots half a second later. Without a
                        // handle on the reading it has no way to know where it
                        // is in the once-a-second update, and roughly a third of
                        // the captures catch `.numericText()` mid-roll — a
                        // smeared digit, in a picture that goes on the store.
                        .accessibilityIdentifier("bpm-value")
                }
                Text("BPM")
                    .font(Theme.Typeface.rowDetail)
                    .kerning(1.5)
                    .foregroundStyle(Theme.textSecondary)

                Text(freshness)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(isStale ? Theme.accentAlert : Theme.textSecondary)
                    .padding(.top, 4)

                if let reconciliation {
                    ScrollingText(text: reconciliation,
                                  rows: 2,
                                  color: Theme.textTertiary,
                                  alignment: .center)
                        .padding(.top, 1)
                }

                if let metrics {
                    Divider()
                        .overlay(Theme.separator)
                        .padding(.top, 12)
                    metrics
                        .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    /// Says out loud whether samples are still arriving. A frozen number with no
    /// age next to it is indistinguishable from a live one.
    ///
    /// Built as three whole phrases rather than a prefix glued to a suffix. The
    /// old form concatenated "\(source) · " onto "live", which would have handed
    /// translators a fragment beginning mid-sentence and no way to move the
    /// sensor name — word order is not ours to assume across 25 languages.
    private var freshness: LocalizedStringKey {
        guard let sampleAge else { return "No samples yet" }
        let seconds = Int(sampleAge.rounded())
        guard let sourceLabel else {
            return sampleAge < 2 ? "live" : "\(seconds)s ago"
        }
        return sampleAge < 2
            ? "\(sourceLabel) · live"
            : "\(sourceLabel) · \(seconds)s ago"
    }
}

// MARK: - Live workout numbers

/// Elapsed time, watts, calories and the sport, in one row of glyph-and-number
/// cells. The same four figures the session card already shows further down the
/// screen, repeated at the top so the phone reads like the watch does: the
/// numbers you want mid-ride are all above the fold, and nobody has to scroll
/// while pedalling.
///
/// A `View` rather than a model struct handed to `HRDisplayCard`, so the card
/// stores the thing it draws and there is no parallel type to keep in step.
struct WorkoutMetricsStrip: View {
    let elapsed: TimeInterval
    /// nil when no meter is reporting. Drawn as `--`, never as `0` — a zero is
    /// a real reading that means coasting, and claiming it while the meter is
    /// simply absent is a lie the rider would act on.
    let watts: Int?
    let kilocalories: Double
    let sport: WorkoutSport

    /// Shared with `SessionControlCard`, which shows the same clock. One
    /// formatter, so the two readings cannot disagree about how to write 1:04.
    static let clock: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .positional
        f.zeroFormattingBehavior = .pad
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cell(glyph: "timer",
                 value: Self.clock.string(from: elapsed) ?? "0:00",
                 label: "Time")
            cell(glyph: "bolt.fill",
                 value: watts.map(String.init) ?? "--",
                 label: "Watts")
            cell(glyph: "flame.fill",
                 value: "\(Int(kilocalories.rounded()))",
                 label: "Calories")
            cell(glyph: sport.glyph,
                 value: nil,
                 label: sport.label)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("workout-metrics-strip")
    }

    /// The sport cell has a glyph and a word but no number, so `value` is
    /// optional and the row still lines up: every cell keeps the same three
    /// bands, and an absent number leaves its band empty rather than pulling
    /// the label up level with its neighbours' digits.
    ///
    /// Where the number is absent the glyph moves down into its band instead of
    /// staying on the icon line. A glyph alone up there reads as a cell whose
    /// number failed to arrive; sitting where the digits sit, it reads as the
    /// answer — which it is, since the word underneath is the value.
    @ViewBuilder
    private func cell(glyph: String, value: String?, label: LocalizedStringKey) -> some View {
        VStack(spacing: 2) {
            // Both bands are always drawn, so all four cells agree on where the
            // label starts however the glyph is placed within them.
            Image(systemName: glyph)
                .font(Theme.Typeface.rowDetail)
                .foregroundStyle(Theme.textTertiary)
                .opacity(value == nil ? 0 : 1)
            Text(value ?? " ")
                .font(Theme.Typeface.metricValue)
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .overlay {
                    if value == nil {
                        Image(systemName: glyph)
                            .font(Theme.Typeface.sectionTitle)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            Text(label)
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Status row

struct StatusRow<Accessory: View>: View {
    /// An SF Symbol name, not prose. Stays a String.
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    /// nil renders a neutral dot — "not applicable" rather than "broken".
    let ok: Bool?
    var hint: LocalizedStringKey? = nil
    /// Optional remedy. A row that can be fixed shows a chevron and the whole
    /// card becomes the tap target — a status that tells you something is wrong
    /// and then makes you go and find the fix yourself is half a feature.
    var action: (() -> Void)? = nil
    /// A control that belongs to this row specifically, drawn immediately before
    /// the status dot. Distinct from `action`, which is a destination — this is
    /// something you operate without leaving the screen, so it must stay outside
    /// the row's own tap target.
    @ViewBuilder var accessory: Accessory

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(Theme.Typeface.rowTitle)
                            .foregroundStyle(Theme.textPrimary)
                        Text(detail)
                            .font(Theme.Typeface.rowDetail)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    if action != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    accessory
                    Circle()
                        .fill(dotColor)
                        .frame(width: Theme.Metric.statusDot, height: Theme.Metric.statusDot)
                        // Colour changes ease rather than cut. The dots are read
                        // peripherally while riding, and an instant red is an
                        // alarm — a half-second fade reads as a state change,
                        // which is what it is.
                        .animation(.easeInOut(duration: 0.45), value: ok)
                }
                if let hint {
                    // Three lines covers every hint in English and most of them
                    // in the longer languages; the rest scroll. A hint that
                    // grows from one line to five as a sensor warms up moves
                    // every card under it, twice, for no reason the rider can
                    // see.
                    ScrollingText(text: hint, rows: 3)
                }
            }
            .contentShape(Rectangle())
        }
    }

    private var dotColor: Color {
        guard let ok else { return Theme.textTertiary }
        return ok ? Theme.accentActive : Theme.accentAlert
    }
}

extension StatusRow where Accessory == EmptyView {
    /// The common case: a row with no control of its own.
    init(icon: String,
         title: LocalizedStringKey,
         detail: LocalizedStringKey,
         ok: Bool?,
         hint: LocalizedStringKey? = nil,
         action: (() -> Void)? = nil) {
        self.init(icon: icon,
                  title: title,
                  detail: detail,
                  ok: ok,
                  hint: hint,
                  action: action,
                  accessory: { EmptyView() })
    }
}

// MARK: - Settings row with a description

struct SettingCard<Control: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var help: LocalizedStringKey? = nil
    @ViewBuilder var control: Control

    @State private var showHelp = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(title)
                                .font(Theme.Typeface.rowTitle)
                                .foregroundStyle(Theme.textPrimary)
                            if help != nil {
                                Button { showHelp = true } label: {
                                    Image(systemName: "questionmark.circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(Theme.Typeface.rowDetail)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    control
                }
            }
        }
        .alert(title, isPresented: $showHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            // `Text(help ?? "")` would be shorter, and it would put an empty
            // key in the String Catalog for all twenty-four languages to
            // translate. The alert is only ever raised from the button that
            // this optional gates, so the nil branch is unreachable anyway.
            if let help { Text(help) }
        }
    }
}

// MARK: - Pairing banner

/// The single most important piece of UI in the app. iOS hides a backgrounded
/// app's advertised service UUID in the packet's overflow area, where only
/// another Apple device explicitly scanning for that UUID can see it — a Garmin
/// or MyWhoosh scanning generically cannot. So discovery requires the foreground.
/// Once the head unit has subscribed, the GATT link survives backgrounding fine.
struct PairingBanner: View {
    let isConnected: Bool
    let peerCount: Int
    /// Connected is not the same as working. A head unit will happily sit
    /// connected to a sensor that never sends a reading, which is the single
    /// most confusing failure this app has.
    let hasData: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(tint)
            ScrollingText(text: message,
                          rows: 3,
                          font: Theme.Typeface.rowDetail,
                          color: Theme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(Theme.Metric.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.Metric.cornerRadius))
        // The banner is the largest colour field on the screen. Even with the
        // hold window keeping it from flapping, the transition between states
        // should be a fade rather than a flash.
        .animation(.easeInOut(duration: 0.45), value: hasData)
        .animation(.easeInOut(duration: 0.45), value: isConnected)
    }

    private var icon: String {
        if !isConnected { return "dot.radiowaves.left.and.right" }
        return hasData ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var tint: Color {
        if !isConnected { return Theme.textPrimary }
        return hasData ? Theme.accentActive : Theme.accentAlert
    }

    private var background: Color {
        guard isConnected else { return Theme.Palette.toggleOff }
        return (hasData ? Theme.accentActive : Theme.accentAlert).opacity(0.12)
    }

    /// The device count is inflected by the system rather than by appending an
    /// "s". English has two plural forms and gets away with concatenation;
    /// Russian, Polish, Czech and Ukrainian have three, Arabic has six, and
    /// Japanese, Korean, Chinese, Thai and Vietnamese have one and want no
    /// plural marker at all. `^[...](inflect: true)` hands that decision to the
    /// String Catalog, which stores a variant per form for each language.
    private var message: LocalizedStringKey {
        guard isConnected else {
            return "Keep this screen open until your bike computer or app finds this phone in its sensor list."
        }
        return hasData
            ? "Sending to ^[\(peerCount) device](inflect: true) — you can lock your phone now."
            : "Connected to ^[\(peerCount) device](inflect: true), but there is no heart rate to send yet. Start the watch app, or switch Heart Rate Source to Test."
    }
}
