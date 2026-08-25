import SwiftUI

/// Connection state as a single dot, with the words on demand.
///
/// The watch screen is small enough that a permanent "Linked" label competes
/// with the number you are actually there to read. Colour alone answers the
/// only question that matters at a glance — green means the phone is receiving
/// — and a tap spells it out for the few seconds you care about the detail.
struct LinkDot: View {

    let label: String
    let color: Color

    @State private var isExpanded = false
    /// Bumped on every tap so a second tap restarts the countdown rather than
    /// inheriting the remainder of the first one.
    @State private var revealID = 0

    private static let visibleFor: Duration = .seconds(3)

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            if isExpanded {
                Text(label)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        // A 7pt circle is far too small to hit on a wrist, so the tap target is
        // padded well beyond what is drawn. The padding is symmetric because the
        // dot is centred — a trailing-only inset would push it visibly off
        // centre while the label is hidden, which is nearly all the time.
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            revealID += 1
            withAnimation(.easeOut(duration: 0.18)) { isExpanded = true }
        }
        .task(id: revealID) {
            guard isExpanded else { return }
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { isExpanded = false }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }
}
