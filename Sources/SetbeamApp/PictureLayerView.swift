import AppKit
import AVFoundation
import SwiftUI

/// One decoded picture: an IOSurface-backed NV12 pixel buffer and its display size, including
/// pixel aspect. Windows composite it on the GPU instead of converting 4K frames to RGB on the CPU.
final class PreviewPicture: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let size: NSSize
    init(pixelBuffer: CVPixelBuffer, size: NSSize) { self.pixelBuffer = pixelBuffer; self.size = size }
}

/// Shows each picture as soon as it is handed over. PreviewPlayback has already applied its timing.
/// Mouse events pass through to the containing view.
@MainActor final class PictureLayerView: NSView {
    private let display = AVSampleBufferDisplayLayer()
    private weak var shown: PreviewPicture?
    private var windowObservers: [NSObjectProtocol] = []

    init(gravity: AVLayerVideoGravity = .resizeAspect) {
        super.init(frame: .zero)
        display.videoGravity = gravity
        wantsLayer = true; layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func makeBackingLayer() -> CALayer { display }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ picture: PreviewPicture?) {
        guard picture !== shown || picture == nil else { return }
        let renderer = display.sampleBufferRenderer
        guard let picture else { shown = nil; renderer.flush(removingDisplayedImage: true, completionHandler: nil); return }
        // A closed/minimized monitor can remain subscribed to the shared feed. It must release
        // its queued surfaces instead of consuming the other monitor's allocation budget.
        guard let window, window.isVisible, !window.isMiniaturized, !isHiddenOrHasHiddenAncestor else {
            shown = nil; renderer.flush(removingDisplayedImage: true, completionHandler: nil); return
        }
        if renderer.status == .failed { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: picture.pixelBuffer, formatDescriptionOut: &format) == noErr,
              let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: picture.pixelBuffer, formatDescription: format,
              sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let values = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(values, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        renderer.enqueue(sample)
        shown = picture
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver); windowObservers.removeAll()
        guard let window else { show(nil); return }
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                // Also flush on returning to view: a stalled renderer may already own all
                // available surfaces, so it cannot rely on a newly allocated frame to reset it.
                MainActor.assumeIsolated { self?.show(nil) }
            })
        }
    }
    deinit { windowObservers.forEach(NotificationCenter.default.removeObserver) }
}

/// The aspect-fit picture for SwiftUI windows and sheets.
struct PictureView: NSViewRepresentable {
    let picture: PreviewPicture
    func makeNSView(context: Context) -> PictureLayerView { PictureLayerView() }
    func updateNSView(_ view: PictureLayerView, context: Context) { view.show(picture) }
    static func dismantleNSView(_ view: PictureLayerView, coordinator: ()) { view.show(nil) }
}
