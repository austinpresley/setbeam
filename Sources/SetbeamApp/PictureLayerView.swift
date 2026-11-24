import AppKit
import AVFoundation
import SwiftUI

/// One IOSurface-backed frame and its pixel-aspect-correct display size.
/// Playback builds the sample off the main actor for all monitors to share.
final class PreviewPicture: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let size: NSSize
    let displaySample: CMSampleBuffer?

    init(pixelBuffer: CVPixelBuffer, size: NSSize) {
        self.pixelBuffer = pixelBuffer
        self.size = size
        displaySample = Self.makeDisplaySample(pixelBuffer)
    }

    private static func makeDisplaySample(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
              sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let values = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(values, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

@MainActor protocol PictureLayerRenderer: AnyObject {
    var ready: Bool { get }
    var failed: Bool { get }
    func enqueue(_ sample: CMSampleBuffer)
    func clear(completion: @escaping @Sendable () -> Void)
}

extension AVSampleBufferVideoRenderer: PictureLayerRenderer {
    var ready: Bool { isReadyForMoreMediaData }
    var failed: Bool { status == .failed }
    func clear(completion: @escaping @Sendable () -> Void) {
        flush(removingDisplayedImage: true, completionHandler: completion)
    }
}

/// Mouse events pass through to the containing view.
@MainActor final class PictureLayerView: NSView {
    private let display = AVSampleBufferDisplayLayer()
    private let renderer: PictureLayerRenderer
    private weak var latest: PreviewPicture?
    private weak var accepted: PreviewPicture?
    private var windowObservers: [NSObjectProtocol] = []
    private var failureObserver: NSObjectProtocol?
    private var retry: Task<Void, Never>?
    private var blockedSince: ContinuousClock.Instant?
    private var recoveryFlushes = 0
    private var flushing = false
    private var hasEnqueued = false
    private(set) var acceptedFrames = 0

    init(gravity: AVLayerVideoGravity = .resizeAspect, renderer: PictureLayerRenderer? = nil) {
        self.renderer = renderer ?? display.sampleBufferRenderer
        super.init(frame: .zero)
        display.videoGravity = gravity
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        failureObserver = NotificationCenter.default.addObserver(forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
            object: display.sampleBufferRenderer, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.offerLatest() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func makeBackingLayer() -> CALayer { display }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ picture: PreviewPicture?) {
        latest = picture
        if picture == nil { suspendDelivery() }
        else { offerLatest() }
    }

    var isVisibleForPlayback: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }

    private func offerLatest() {
        guard isVisibleForPlayback else { suspendDelivery(); return }
        guard !flushing, let latest, let sample = latest.displaySample else { return }
        if !renderer.failed, latest === accepted { return }
        if !renderer.failed, renderer.ready {
            renderer.enqueue(sample)
            accepted = latest
            acceptedFrames += 1
            hasEnqueued = true
            resetRecovery()
            return
        }
        let now = ContinuousClock.now
        let since = blockedSince ?? now
        blockedSince = since
        guard recoveryFlushes < 2 else { return }
        if (renderer.failed && recoveryFlushes == 0) || now - since >= .milliseconds(250) {
            recoveryFlushes += 1
            blockedSince = now
            flush()
        } else if retry == nil {
            retry = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled, let self else { return }
                self.retry = nil
                self.offerLatest()
            }
        }
    }

    private func flush() {
        guard !flushing else { return }
        accepted = nil
        hasEnqueued = false
        flushing = true
        renderer.clear { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.flushing = false
                self.offerLatest()
            }
        }
    }

    private func resetRecovery() {
        retry?.cancel()
        retry = nil
        blockedSince = nil
        recoveryFlushes = 0
    }

    private func suspendDelivery() {
        resetRecovery()
        if hasEnqueued { flush() }
    }

    private func windowChanged() {
        guard isVisibleForPlayback else { suspendDelivery(); return }
        resetRecovery()
        offerLatest()
    }

    override func viewDidHide() { super.viewDidHide(); suspendDelivery() }
    override func viewDidUnhide() { super.viewDidUnhide(); windowChanged() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        suspendDelivery()
        guard let window else { return }
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification, NSWindow.willCloseNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWindow.willCloseNotification { self?.suspendDelivery() }
                    else { self?.windowChanged() }
                }
            })
        }
        windowChanged()
    }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        retry?.cancel()
    }
}

/// The aspect-fit picture for SwiftUI windows and sheets.
struct PictureView: NSViewRepresentable {
    let picture: PreviewPicture
    func makeNSView(context: Context) -> PictureLayerView { PictureLayerView() }
    func updateNSView(_ view: PictureLayerView, context: Context) { view.show(picture) }
    static func dismantleNSView(_ view: PictureLayerView, coordinator: ()) { view.show(nil) }
}
