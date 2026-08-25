import SwiftUI

/// Screen lock for the watch app — one gesture, both directions.
///
/// A wrist-worn app that stops a workout on a single tap is a real problem —
/// a sleeve, a bar tape grab, or a jersey zip will end the broadcast mid-ride
/// with no warning. A one-second press anywhere lays a transparent,
/// tap-swallowing layer over the whole app; the same one-second press takes it
/// away again. Symmetry matters here: whatever state the screen is in, the way
/// out is the thing you already did to get in, which is the only instruction
/// worth remembering with gloves on.
///
/// It intentionally does *not* use `WKInterfaceDevice.enableWaterLock()`. Water
/// Lock blanks the screen and can only be cleared with a Digital Crown turn,
/// which would also hide the heart rate — the opposite of what this app is for.
/// It also cannot be released programmatically, so a hold could lock but never
/// unlock.
struct TouchLock: ViewModifier {

    /// Whether the lock arms itself when the workout starts. Mirrors the phone's
    /// "Lock Touch Screen for Watch" switch. The hold gesture works either way —
    /// this only decides the starting state, because a control that does nothing
    /// until you find a setting on another device is a control nobody finds.
    let autoArms: Bool

    /// Only lockable while there is something to protect.
    let isActive: Bool

    @State private var isLocked = false
    @State private var pressProgress: CGFloat = 0
    /// Tracks the arming edge so toggling the phone switch mid-ride does not
    /// re-lock a screen the rider has deliberately opened.
    @State private var didAutoArm = false

    private static let holdDuration: Double = 1.0

    func body(content: Content) -> some View {
        content
            // Simultaneous, so an ordinary tap still reaches Start / Stop. Only
            // a full second of contact registers, and a long press is not a
            // gesture any pocket or sleeve produces.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: Self.holdDuration)
                    .onEnded { _ in
                        guard isActive, !isLocked else { return }
                        withAnimation(.easeOut(duration: 0.2)) { isLocked = true }
                    }
            )
            .overlay { if isLocked && isActive { locked } }
            .onChange(of: isActive) { _, active in
                if active, autoArms, !didAutoArm {
                    didAutoArm = true
                    withAnimation { isLocked = true }
                } else if !active {
                    didAutoArm = false
                    isLocked = false
                }
            }
    }

    private var locked: some View {
        ZStack {
            // Nearly clear rather than opaque: the BPM underneath stays
            // readable, which is the entire point of the app.
            Theme.background.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textSecondary)
                Text("Hold to unlock")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Capsule()
                    .fill(Theme.separator)
                    .frame(width: 60, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Theme.accentActive)
                            .frame(width: 60 * pressProgress, height: 3)
                    }
            }
        }
        .contentShape(Rectangle())
        // `minimumDuration` swallows taps: a brief contact never reaches the
        // controls below, and never starts the unlock either.
        .onLongPressGesture(minimumDuration: Self.holdDuration) {
            withAnimation(.easeOut(duration: 0.2)) {
                isLocked = false
                pressProgress = 0
            }
        } onPressingChanged: { pressing in
            withAnimation(.linear(duration: pressing ? Self.holdDuration : 0.15)) {
                pressProgress = pressing ? 1 : 0
            }
        }
        .transition(.opacity)
    }
}

extension View {
    /// Hold for a second to lock the screen; hold again to unlock.
    func touchLock(autoArms: Bool, isActive: Bool) -> some View {
        modifier(TouchLock(autoArms: autoArms, isActive: isActive))
    }
}
