import SwiftUI
import AVKit

/// The system audio route switcher, as a glyph small enough to sit in a status
/// row next to the connection dot.
///
/// This replaces a link out to the Health app on the AirPods row. Health was
/// the wrong destination: when AirPods are connected but not reporting, what
/// actually fixes it is bouncing the audio route — switch output away and back
/// and iOS re-establishes the accessory link, at which point heart rate starts
/// flowing. Health can only show samples that already arrived.
///
/// `AVRoutePickerView` is the only supported way to present that chooser; the
/// underlying sheet is system UI and cannot be built from SwiftUI. Wrapping it
/// costs a `UIViewRepresentable`, but the alternative — deep-linking to
/// Settings — cannot target the audio route at all.
struct AudioRoutePicker: UIViewRepresentable {

    var tint: Color = Theme.textSecondary

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        // The picker draws a "route is active" highlight in its active tint.
        // Both tints are set to the same colour so the glyph does not turn
        // system blue the moment AirPods connect — this row already says
        // connected with its status dot, and two signals disagreeing in colour
        // is the flicker this screen is trying to get rid of.
        view.tintColor = UIColor(tint)
        view.activeTintColor = UIColor(tint)
        view.prioritizesVideoDevices = false
        // Fixed size: it lives inline in a row, so it must not fight the label
        // for horizontal space.
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = UIColor(tint)
        view.activeTintColor = UIColor(tint)
    }
}
