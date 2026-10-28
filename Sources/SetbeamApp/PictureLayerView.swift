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
        shown = picture
        let renderer = display.sampleBufferRenderer
        guard let picture else { renderer.flush(removingDisplayedImage: true, completionHandler: nil); return }
        if renderer.status == .failed { renderer.flush() }
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
    }
}

/// The aspect-fit picture for SwiftUI windows and sheets.
struct PictureView: NSViewRepresentable {
    let picture: PreviewPicture
    func makeNSView(context: Context) -> PictureLayerView { PictureLayerView() }
    func updateNSView(_ view: PictureLayerView, context: Context) { view.show(picture) }
}
