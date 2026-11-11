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
