import SwiftUI
import AVFoundation

/// Puts the Picture in Picture source layer into the real view hierarchy.
///
/// `AVPictureInPictureController` will not start from a layer that is not
/// attached to an on-screen view, so this exists purely to give the layer a
/// home. It is deliberately tiny and invisible — the content the user sees is
/// the detached PiP window, not this.
struct PiPHostView: UIViewRepresentable {

    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> LayerHost {
        let host = LayerHost()
        host.isUserInteractionEnabled = false
        host.layer.addSublayer(layer)
        host.hosted = layer
        return host
    }

    func updateUIView(_ uiView: LayerHost, context: Context) {}

    final class LayerHost: UIView {
        var hosted: AVSampleBufferDisplayLayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }
}
