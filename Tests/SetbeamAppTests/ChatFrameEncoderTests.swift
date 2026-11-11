import XCTest
import CoreVideo
import ImageIO
import SetbeamCore
@testable import SetbeamApp

final class ChatFrameEncoderTests: XCTestCase {
    func testDetailed4KFrameBecomesABoundedChatJPEG() async throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        let bytes = CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel)
        let pointer = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 12345
        for index in stride(from: 0, to: bytes, by: 4) {
            seed = seed &* 1664525 &+ 1013904223
            pointer[index] = UInt8(truncatingIfNeeded: seed); pointer[index + 1] = UInt8(truncatingIfNeeded: seed >> 8)
            pointer[index + 2] = UInt8(truncatingIfNeeded: seed >> 16); pointer[index + 3] = 255
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let picture = PreviewPicture(pixelBuffer: pixel, size: NSSize(width: 3840, height: 2160))
        let encoded = await Task.detached { ChatFrameEncoder.encode(picture) }.value
        let data = try XCTUnwrap(encoded)
        XCTAssertLessThanOrEqual(data.count, 131_072)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelWidth as String] as! Int, 960)
        let gateway = ViewerGateway(assets: [:])
        gateway.update(ViewerSession(token: "fixture", title: "Fixture", sample: true, state: .live, playback: PlaybackDescriptor(origin: "http://127.0.0.1", path: "live", user: "guest", password: "fixture"), revision: 1))
        gateway.setChatFramePermission(true)
        try gateway.postChat(text: "4K detail", replyTo: nil, frame: data, revision: 1, token: "fixture", name: "DigiTech", color: .orange, requestID: UUID().uuidString)
        XCTAssertTrue(gateway.chatMessages.first!.hasFrame)
    }
    func testSecuredWiFiDraftCannotSaveWithoutPassword() {
        XCTAssertFalse(ViewingWiFiDraft(ssid: "Secured", password: "").canSave)
        XCTAssertTrue(ViewingWiFiDraft(ssid: "Open", password: "", openNetwork: true).canSave)
        XCTAssertTrue(ViewingWiFiDraft(ssid: "Secured", password: "fixture-password").canSave)
    }
}
