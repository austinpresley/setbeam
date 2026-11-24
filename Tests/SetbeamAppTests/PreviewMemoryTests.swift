import AppKit
import AVFoundation
import Darwin
import XCTest
@testable import SetbeamApp

final class PreviewMemoryTests: XCTestCase {
    private func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw NSError(domain: NSMachErrorDomain, code: Int(status)) }
        return info.phys_footprint
    }

    /// An offscreen/slow native monitor must not retain every full-resolution frame.
    /// No capture hardware or network is needed to drive the actual display-layer call site.
    @MainActor func testStalledDisplayHasBoundedFrameMemory() async throws {
        _ = NSApplication.shared
        let view = PictureLayerView()
        view.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFrontRegardless()
        defer { view.show(nil); window.close() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(window.isVisible)
        let pictures = PreviewPicturePool()
        let packet = frame(width: 3840, height: 2160)
        let baseline = try footprint()
        var peak = baseline
        for _ in 0..<240 {
            autoreleasepool { if let picture = pictures.makePicture(packet) { view.show(picture) } }
            peak = max(peak, try footprint())
            if peak > baseline + 384 * 1024 * 1024 { break }
        }
        view.show(nil)
        print("Stalled 4K preview footprint growth: \((peak - baseline) / 1024 / 1024) MiB")
        XCTAssertLessThan(peak - baseline, 256 * 1024 * 1024,
                          "A stalled preview must drop pictures instead of retaining unbounded IOSurfaces.")
    }

    private func frame(width: Int = 320, height: Int = 180) -> PreviewPacket {
        PreviewPacket(kind: .video, flags: 0, timestamp: 0, duration: 33_333, width: width, height: height,
                      channels: 0, sampleRate: 0, aspectNumerator: 1, aspectDenominator: 1, matrix: 1,
                      payload: Data(repeating: 128, count: width * height * 3 / 2))
    }

    func testRetainedRendererBuffersStopAllocationAndReleasedBuffersResume() throws {
        let pictures = PreviewPicturePool(), packet = frame()
        // Renderers retain CVPixelBuffers, not PreviewPicture wrappers.
        var retained: [CVPixelBuffer] = []
        for _ in 0..<100 { if let picture = pictures.makePicture(packet) { retained.append(picture.pixelBuffer) } }
        XCTAssertEqual(retained.count, 8, "A consumer that never releases pictures must hit the allocation ceiling.")
        XCTAssertNil(pictures.makePicture(packet))
        retained.removeAll()
        XCTAssertNotNil(pictures.makePicture(packet), "Releasing renderer buffers must resume playback without a decoder restart.")
    }

    func testFormatChangesCannotBypassTheOutstandingBufferLimit() {
        let pictures = PreviewPicturePool()
        var retained: [CVPixelBuffer] = []
        for index in 0..<40 {
            if let picture = pictures.makePicture(frame(width: 320 + index * 2)) { retained.append(picture.pixelBuffer) }
        }
        XCTAssertLessThanOrEqual(retained.count, 8, "Changing format must not reset the budget while old renderers still own buffers.")
        retained.removeAll()
        XCTAssertNotNil(pictures.makePicture(frame(width: 640)))
    }

    func testDecoderRecoveryCannotResetTheOutstandingBufferLimit() {
        let allocations = PreviewBufferAllocations(limit: PreviewPicturePool.maximumBuffers)
        var retained: [CVPixelBuffer] = []
        for _ in 0..<40 {
            let replacementDecoder = PreviewPicturePool(allocations: allocations)
            if let picture = replacementDecoder.makePicture(frame()) { retained.append(picture.pixelBuffer) }
        }
        XCTAssertEqual(retained.count, PreviewPicturePool.maximumBuffers)
        retained.removeAll()
        XCTAssertNotNil(PreviewPicturePool(allocations: allocations).makePicture(frame()))
    }

    @MainActor func testDetachedMonitorDoesNotConsumeTheSharedBufferBudget() {
        let pictures = PreviewPicturePool(), view = PictureLayerView(), packet = frame()
        var delivered = 0
        for _ in 0..<100 {
            autoreleasepool {
                if let picture = pictures.makePicture(packet) { view.show(picture); delivered += 1 }
            }
        }
        XCTAssertEqual(delivered, 100, "An offscreen monitor must leave buffers available to the visible monitor.")
    }
}

@MainActor private final class TestPictureRenderer: PictureLayerRenderer {
    var ready = true
    var failed = false
    var samples: [CMSampleBuffer] = []
    var flushes = 0
    var onFlush: (() -> Void)?

    func enqueue(_ sample: CMSampleBuffer) { samples.append(sample) }
    func clear(completion: @escaping @Sendable () -> Void) {
        flushes += 1
        samples.removeAll()
        onFlush?()
        completion()
    }
}

@MainActor private final class VisiblePreviewTestWindow: NSWindow {
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { .visible }
}

extension PreviewMemoryTests {
    @MainActor func testEachVisibleLayerAcceptsIndependentlyAndReplaysLatestAfterFlush() async throws {
        _ = NSApplication.shared
        let window = VisiblePreviewTestWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let mainRenderer = TestPictureRenderer(), floatingRenderer = TestPictureRenderer()
        let main = PictureLayerView(renderer: mainRenderer)
        let floating = PictureLayerView(renderer: floatingRenderer)
        window.contentView = NSView(frame: .zero)
        window.contentView?.addSubview(main)
        window.contentView?.addSubview(floating)

        let pool = PreviewPicturePool()
        let first = try XCTUnwrap(pool.makePicture(frame()))
        let last = try XCTUnwrap(pool.makePicture(frame()))
        floatingRenderer.ready = false
        for view in [main, floating] { view.show(first); view.show(last) }
        XCTAssertEqual(main.acceptedFrames, 2)
        XCTAssertEqual(floating.acceptedFrames, 0)

        floatingRenderer.onFlush = { [weak floatingRenderer] in floatingRenderer?.ready = true }
        let deadline = ContinuousClock.now + .seconds(2)
        while floating.acceptedFrames == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(floatingRenderer.flushes, 1)
        XCTAssertEqual(floating.acceptedFrames, 1)
        XCTAssertTrue(floatingRenderer.samples.first === last.displaySample)
        XCTAssertEqual(mainRenderer.flushes, 0)

        floating.isHidden = true
        XCTAssertEqual(floatingRenderer.flushes, 2)
        floating.show(first)
        floating.isHidden = false
        let replay = ContinuousClock.now + .seconds(2)
        while floating.acceptedFrames < 2 && ContinuousClock.now < replay {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(floating.acceptedFrames, 2)
        XCTAssertTrue(floatingRenderer.samples.first === first.displaySample)

        floatingRenderer.ready = false
        floatingRenderer.onFlush = nil
        floating.show(last)
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertEqual(floatingRenderer.flushes, 4, "One stall must have a bounded flush budget.")
        XCTAssertEqual(floating.acceptedFrames, 2)
        window.close()
    }

    func testAspectAndColorTagsReachTheSampleAndDoNotCarryOver() throws {
        let pool = PreviewPicturePool()
        let base = frame()
        let tagged = PreviewPacket(kind: .video, flags: 1 | (9 << 8) | (16 << 16), timestamp: 0, duration: base.duration,
            width: base.width, height: base.height, channels: 0, sampleRate: 0,
            aspectNumerator: 4, aspectDenominator: 3, matrix: 9, payload: base.payload)
        try autoreleasepool {
            let picture = try XCTUnwrap(pool.makePicture(tagged))
            XCTAssertEqual(picture.size.width / picture.size.height, 64.0 / 27, accuracy: 0.001)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(picture.pixelBuffer), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(try XCTUnwrap(picture.displaySample)))
            let dimensions = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
            XCTAssertEqual(dimensions.width / dimensions.height, 64.0 / 27, accuracy: 0.001)
            XCTAssertEqual(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
                kCVImageBufferColorPrimaries_ITU_R_2020 as String)
            XCTAssertEqual(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
                kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        }
        let unknown = PreviewPacket(kind: .video, flags: 1, timestamp: 0, duration: base.duration,
            width: base.width, height: base.height, channels: 0, sampleRate: 0,
            aspectNumerator: 1, aspectDenominator: 1, matrix: 1, payload: base.payload)
        let picture = try XCTUnwrap(pool.makePicture(unknown))
        XCTAssertNil(CVBufferCopyAttachment(picture.pixelBuffer, kCVImageBufferColorPrimariesKey, nil))
        XCTAssertNil(CVBufferCopyAttachment(picture.pixelBuffer, kCVImageBufferTransferFunctionKey, nil))
    }
}
