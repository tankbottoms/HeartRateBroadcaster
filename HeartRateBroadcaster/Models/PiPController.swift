import Foundation
import AVFoundation
import AVKit
import UIKit
import CoreMedia
import CoreVideo
import Observation

/// Floating heart-rate window that survives leaving the app.
///
/// There is no "text in a PiP window" API — Picture in Picture on iOS only
/// knows how to show video. So this draws the BPM into a `CVPixelBuffer` once a
/// second, wraps it as a `CMSampleBuffer`, and feeds it to an
/// `AVSampleBufferDisplayLayer`, which `AVPictureInPictureController` will host
/// (`initWithContentSource:` is iOS 15+). From the system's point of view this
/// is a live video stream that happens to be a number.
///
/// Requires the `audio` background mode — PiP is gated on it even when there is
/// no audio, because the system treats a detached window as continued playback.
@Observable
@MainActor
final class PiPController: NSObject {

    private(set) var isActive = false
    private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    private(set) var lastError: String?

    /// Handed to a `UIViewRepresentable` so the layer lives in the real view
    /// hierarchy — a detached layer will not start PiP.
    let displayLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        return layer
    }()

    private var controller: AVPictureInPictureController?
    private var renderTimer: Timer?

    /// Last thing we were told to draw.
    private var bpm: Int?
    private var isLive = false
    private var subtitle = ""

    // 16:9 keeps the PiP window a familiar shape; the digits are large enough
    // to read at the smallest size the system will shrink it to.
    private static let width = 480
    private static let height = 270

    private var formatDescription: CMFormatDescription?
    private var pixelBufferPool: CVPixelBufferPool?

    // MARK: - Lifecycle

    func start() {
        guard isSupported else {
            lastError = String(localized: "Picture in Picture is not supported on this device.")
            return
        }
        guard controller == nil else { return }

        // Without an active playback session the system tears PiP down the
        // instant the app backgrounds — which is the only time it is useful.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            lastError = error.localizedDescription
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        controller = pip

        startRendering()
    }

    func stop() {
        stopRendering()
        controller?.stopPictureInPicture()
        controller = nil
        isActive = false
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Asks the system to detach the window now. Only legal from a user action
    /// while the app is foreground.
    func present() {
        guard let controller else {
            start()
            self.controller?.startPictureInPicture()
            return
        }
        controller.startPictureInPicture()
    }

    func update(bpm: Int?, isLive: Bool, subtitle: String) {
        self.bpm = bpm
        self.isLive = isLive
        self.subtitle = subtitle
    }

    // MARK: - Rendering

    private func startRendering() {
        guard renderTimer == nil else { return }
        // 1 Hz matches the broadcast cadence. A faster frame rate would burn
        // battery redrawing a number that has not changed.
        // `[weak self]` — the controller owns the timer, so a strong capture
        // here is a retain cycle that keeps the controller, its display layer
        // and its pixel buffer pool alive for the life of the process.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
        renderFrame()
    }

    private func stopRendering() {
        renderTimer?.invalidate()
        renderTimer = nil
    }

    private func renderFrame() {
        guard let pixelBuffer = makePixelBuffer() else { return }
        draw(into: pixelBuffer)
        guard let sample = makeSampleBuffer(from: pixelBuffer) else { return }

        // The renderer refuses new buffers after certain errors until it is
        // flushed; recover rather than freeze on screen.
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        renderer.enqueue(sample)
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        if pixelBufferPool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.width,
                kCVPixelBufferHeightKey as String: Self.height,
                // PiP composites through the GPU; without an IOSurface backing
                // the layer silently drops every frame.
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            pixelBufferPool = pool
        }
        guard let pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &buffer)
        return buffer
    }

    private func draw(into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: base,
                width: Self.width,
                height: Self.height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return }

        // A CGContext drawn straight onto a pixel buffer has a bottom-left
        // origin, but UIKit text drawing assumes top-left. Without this flip
        // every glyph comes out upside down and mirrored.
        context.translateBy(x: 0, y: CGFloat(Self.height))
        context.scaleBy(x: 1, y: -1)

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        // White, to match the rest of the app.
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: Self.width, height: Self.height))

        let value = (isLive && bpm != nil) ? "\(bpm!)" : "--"
        let heart = "\u{2764}\u{FE0F}"

        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 108, weight: .semibold),
            .foregroundColor: UIColor.black
        ]
        let heartAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 64)
        ]
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 22, weight: .medium),
            .foregroundColor: UIColor.darkGray
        ]

        let valueSize = value.size(withAttributes: valueAttrs)
        let heartSize = heart.size(withAttributes: heartAttrs)
        let gap: CGFloat = 18
        let rowWidth = heartSize.width + gap + valueSize.width
        let rowX = (CGFloat(Self.width) - rowWidth) / 2
        let rowY: CGFloat = 52

        heart.draw(at: CGPoint(x: rowX, y: rowY + (valueSize.height - heartSize.height) / 2),
                   withAttributes: heartAttrs)
        value.draw(at: CGPoint(x: rowX + heartSize.width + gap, y: rowY),
                   withAttributes: valueAttrs)

        let caption = subtitle.isEmpty ? "BPM" : "BPM · \(subtitle)"
        let captionSize = caption.size(withAttributes: subtitleAttrs)
        caption.draw(at: CGPoint(x: (CGFloat(Self.width) - captionSize.width) / 2,
                                 y: rowY + valueSize.height + 8),
                     withAttributes: subtitleAttrs)
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        if formatDescription == nil {
            var description: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &description
            )
            formatDescription = description
        }
        guard let formatDescription else { return nil }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 1),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        return sample
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                setPlaying playing: Bool) {
        // Live stream — there is nothing to pause. Swallow the request so the
        // play/pause button does not freeze the number on screen.
    }

    /// An infinite range is how you tell the system this is live: it hides the
    /// scrubber instead of drawing a timeline this content does not have.
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPController: AVPictureInPictureControllerDelegate {

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Task { @MainActor in self.isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Task { @MainActor in self.isActive = false }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.isActive = false
            self.lastError = error.localizedDescription
        }
    }
}
