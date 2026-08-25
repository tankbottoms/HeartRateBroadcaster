import SwiftUI

/// A heart that beats at the *actual* measured rate.
///
/// The point is that the animation is diagnostic, not decorative: the period is
/// `60 / bpm`, so the pulse you see is the heart rate being broadcast. When the
/// stream goes stale the beating stops and the glyph desaturates, which makes a
/// dead source obvious at a glance instead of leaving a frozen number on screen.
struct BeatingHeart: View {

    let bpm: Int?
    /// False when the source has gone quiet — stops the animation entirely.
    let isLive: Bool
    var size: CGFloat = 34

    @State private var scale: CGFloat = 1.0
    @State private var beatTimer: Timer?

    var body: some View {
        Text(Theme.heartGlyph)
            .font(.system(size: size))
            .scaleEffect(scale)
            .saturation(isLive ? 1 : 0)
            .opacity(isLive ? 1 : 0.35)
            .animation(.easeOut(duration: 0.18), value: isLive)
            .onAppear { restart() }
            .onDisappear { stop() }
            .onChange(of: beatInterval) { _, _ in restart() }
            .onChange(of: isLive) { _, _ in restart() }
    }

    /// nil when there is nothing to beat to.
    private var beatInterval: Double? {
        guard isLive, let bpm, bpm > 0 else { return nil }
        return 60.0 / Double(bpm)
    }

    private func restart() {
        stop()
        guard let interval = beatInterval else {
            withAnimation(.easeOut(duration: 0.2)) { scale = 1.0 }
            return
        }
        beat()
        // `.common` so the beat survives scrolling; a `.default`-mode timer
        // would freeze the moment the user touches a scroll view.
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { beat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        beatTimer = timer
    }

    private func stop() {
        beatTimer?.invalidate()
        beatTimer = nil
    }

    /// Systole then diastole — a sharp contraction and a slower relaxation,
    /// which reads as a heartbeat rather than a throb.
    private func beat() {
        withAnimation(.easeOut(duration: 0.12)) { scale = 1.22 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeInOut(duration: 0.26)) { scale = 1.0 }
        }
    }
}
