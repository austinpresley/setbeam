import CoreMedia
import CoreVideo
import ImageIO
import XCTest
@testable import SetbeamCore

final class PresenterCursorTests: XCTestCase {
    private let identity = MacWindowIdentity(windowID: 42, processID: 9, processStart: 100)

    func testCursorMapsToRetinaPixelsInsideTheFittedPicture() throws {
        let frame = try XCTUnwrap(PresenterCursorFrame(
            screen: CGRect(x: -1040, y: 40, width: 800, height: 600),
            contentInPoints: CGRect(x: 50, y: 0, width: 400, height: 300),
            scale: 2, imageSize: CGSize(width: 1000, height: 600), cursor: CGPoint(x: -840, y: 490)))
        XCTAssertEqual(frame.center, CGPoint(x: 300, y: 450))
        XCTAssertEqual(frame.content, CGRect(x: 100, y: 0, width: 800, height: 600))
        XCTAssertTrue(frame.acceptsCurrentCursor(CGPoint(x: -839.5, y: 490), now: .invalid))
        XCTAssertFalse(frame.acceptsCurrentCursor(CGPoint(x: -841.5, y: 490), now: .invalid))
        XCTAssertFalse(frame.acceptsCurrentCursor(CGPoint(x: 12, y: 490), now: .invalid))
    }

    func testCursorOutsideTheDisplayOrWithInvalidContentGeometryIsSuppressed() {
        let screen = CGRect(x: 800, y: -600, width: 800, height: 600)
        let image = CGSize(width: 1600, height: 1200)
        let center = CGPoint(x: 1200, y: -300)
        for cursor in [CGPoint(x: 799, y: -300), CGPoint(x: 1200, y: 1), CGPoint(x: CGFloat.nan, y: -20)] {
            XCTAssertNil(PresenterCursorFrame(screen: screen, contentInPoints: CGRect(origin: .zero, size: screen.size),
                                              scale: 2, imageSize: image, cursor: cursor))
        }
        for content in [CGRect.zero, CGRect(x: 50, y: 0, width: 800, height: 600),
                        CGRect(x: 0, y: 0, width: 800, height: 550), CGRect(x: 0, y: 0, width: -800, height: 600)] {
            XCTAssertNil(PresenterCursorFrame(screen: screen, contentInPoints: content, scale: 2, imageSize: image, cursor: center))
        }
    }

    func testWindowMustBeTheExactTopWindowAtTheCursorInTheFrameGeometry() throws {
        typealias Window = PresenterCursorSource.Window
        let screen = CGRect(x: -730, y: -350, width: 600, height: 400)
        let cursor = CGPoint(x: -520, y: -180)
        let image = CGSize(width: 800, height: 600)
        let frame = try XCTUnwrap(PresenterCursorFrame(screen: screen,
            contentInPoints: CGRect(x: 0, y: 25, width: 600, height: 400), scale: 1, imageSize: image, cursor: cursor, isWindow: true))
        let window = Window(id: 42, owner: 9, bounds: screen)
        func owns(_ window: Window, hits: (Int, Int) = (42, 42)) -> Bool {
            PresenterCursorSource.ownsWindowCursor(identity, frame: frame, at: cursor, in: window, hits: hits)
        }
        XCTAssertTrue(owns(window))
        XCTAssertFalse(owns(window, hits: (43, 42)))
        XCTAssertFalse(owns(window, hits: (42, 43)))
        XCTAssertFalse(owns(window, hits: (0, 42)))
        XCTAssertFalse(owns(Window(id: 42, owner: 15, bounds: screen)))
        XCTAssertFalse(owns(Window(id: 42, owner: 9, bounds: screen, alpha: 0.8)))

        let moved = CGRect(x: -725, y: -360, width: 700, height: 450)
        let resized = Window(id: 42, owner: 9, bounds: moved)
        XCTAssertFalse(owns(resized))
        let newFrame = try XCTUnwrap(PresenterCursorFrame(screen: moved,
            contentInPoints: CGRect(x: 0, y: 0, width: 700, height: 450), scale: 1, imageSize: image, cursor: cursor, isWindow: true))
        XCTAssertTrue(PresenterCursorSource.ownsWindowCursor(identity, frame: newFrame, at: cursor, in: resized, hits: (42, 42)))
        XCTAssertEqual(newFrame.center, CGPoint(x: 205, y: 180))
    }

    func testDisplaySuppressesCursorOverExcludedWindows() throws {
        let area = CGRect(x: 0, y: 0, width: 800, height: 600)
        let cursor = CGPoint(x: 300, y: 250)
        let frame = try XCTUnwrap(PresenterCursorFrame(screen: area, contentInPoints: area,
                                                      scale: 1, imageSize: area.size, cursor: cursor))
        let source = PresenterCursorSource.display(1, uuid: UUID().uuidString, excluded: [100])
        XCTAssertTrue(source.ownsDisplayCursor(frame, at: cursor, windows: [.init(id: 1, owner: 9, bounds: area)]))
        XCTAssertFalse(source.ownsDisplayCursor(frame, at: cursor, windows: [.init(id: 1, owner: 100, bounds: area)]))
    }

    func testCursorCanMoveWithinAFreshPictureButMustStillBeOwned() throws {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let captured = CMTime(value: 100, timescale: 100)
        let fresh = CMTime(value: 103, timescale: 100)
        let oneSecondLater = CMTime(value: 200, timescale: 100)
        let frame = try XCTUnwrap(PresenterCursorFrame(screen: screen, contentInPoints: screen, scale: 1,
            imageSize: screen.size, cursor: CGPoint(x: 200, y: 200), isWindow: true, displayTime: captured))
        let window = PresenterCursorSource.Window(id: 42, owner: 9, bounds: screen)
        let moved = CGPoint(x: 300, y: 300)
        func owns(_ cursor: CGPoint, now: CMTime, hits: (Int, Int) = (42, 42)) -> Bool {
            PresenterCursorSource.ownsWindowCursor(identity, frame: frame, at: cursor, in: window, hits: hits, now: now)
        }
        XCTAssertTrue(owns(moved, now: fresh))
        XCTAssertFalse(owns(moved, now: fresh, hits: (55, 42)))
        XCTAssertFalse(owns(moved, now: oneSecondLater))
        XCTAssertTrue(owns(frame.cursor, now: oneSecondLater))
    }

    func testRingAddsContrastWithoutChangingCursorPixelsLetterboxOrChroma() throws {
        let image = CGSize(width: 128, height: 128)
        let area = CGRect(x: 0, y: 0, width: 80, height: 80)
        let compositor = PresenterCursorHighlight(width: 128, height: 128)
        let clip = CGRect(x: 24, y: 24, width: 80, height: 80)
        let frame = try XCTUnwrap(PresenterCursorFrame(screen: area, contentInPoints: clip, scale: 1,
                                                      imageSize: image, cursor: CGPoint(x: 25, y: 5), isWindow: true))
        for background: UInt8 in [16, 235] {
            let clean = try pixel(width: 128, height: 128, luma: background, chroma: 92)
            let marked = try XCTUnwrap(compositor.draw(frame, on: clean))
            let raw = bytes(clean), composited = bytes(marked)
            XCTAssertEqual(raw[0], [UInt8](repeating: background, count: 128 * 128))
            XCTAssertEqual(raw[1], composited[1])
            let center = Int(frame.center.y) * 128 + Int(frame.center.x)
            XCTAssertEqual(composited[0][center], background)
            let changed = composited[0].indices.filter { composited[0][$0] != background }
            XCTAssertGreaterThan(changed.count, 20)
            for index in changed {
                let point = CGPoint(x: CGFloat(index % 128) + 0.5, y: CGFloat(index / 128) + 0.5)
                XCTAssertTrue(clip.contains(point))
                XCTAssertTrue(PresenterCursorFrame.awayFromCorners(point, in: clip, dx: 24, dy: 24))
                XCTAssertEqual(composited[0][index], background == 16 ? 235 : 16)
            }
        }
    }

    func testRingCopiesStayBoundedAndSurviveTheOneFPSCaptureEncode() throws {
        let width = 640, height = 480
        let screen = CGRect(x: 0, y: 0, width: width, height: height)
        let frame = try XCTUnwrap(PresenterCursorFrame(screen: screen, contentInPoints: screen, scale: 1,
                                                      imageSize: screen.size, cursor: CGPoint(x: 320, y: 240)))
        let compositor = PresenterCursorHighlight(width: width, height: height)
        let dark = try pixel(width: width, height: height, luma: 16)
        let light = try pixel(width: width, height: height, luma: 235)
        let copies = try [dark, light, dark].map { try XCTUnwrap(compositor.draw(frame, on: $0)) }
        XCTAssertNil(compositor.draw(frame, on: dark), "Exhaustion falls back to the original picture.")

        let tools = ProcessInfo.processInfo.environment["SETBEAM_TEST_TOOLS"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Vendor/bin")
        let ffmpeg = tools.appendingPathComponent("ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { throw XCTSkip("Bundled FFmpeg is required to check the encoded ring.") }
        let queue = DispatchQueue(label: "test.presenter-cursor.encoder")
        var units = Data()
        let encoder = try ScreenEncoder(width: width, height: height, fps: 1, queue: queue) { units.append($0) }
        queue.sync { encoder.encode(copies[0]); encoder.encode(copies[1]) }
        encoder.flush()
        queue.sync { encoder.invalidate() }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let h264 = directory.appendingPathComponent("cursor.h264")
        try units.write(to: h264)
        let decoder = Process()
        decoder.executableURL = ffmpeg
        decoder.arguments = ["-nostdin", "-v", "error", "-i", h264.path, "-fps_mode", "passthrough",
                             "-c:v", "png", "-pix_fmt", "gray", directory.path + "/cursor-%d.png"]
        try decoder.run()
        decoder.waitUntilExit()
        XCTAssertEqual(decoder.terminationStatus, 0)
        let pngs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        XCTAssertEqual(pngs.count, 2)
        for (index, url) in pngs.enumerated() {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, width)
            XCTAssertEqual(image.height, height)
            XCTAssertEqual(image.bitsPerPixel, 8)
            let pixels = try XCTUnwrap(image.dataProvider?.data) as Data
            let center = 240 * image.bytesPerRow + 320
            let fill = Int(pixels[center])
            let stroke = Int(pixels[center + (index == 0 ? 10 : 11)])
            XCTAssertGreaterThan(index == 0 ? stroke - fill : fill - stroke, 130)
        }
    }

    private func pixel(width: Int, height: Int, luma: UInt8, chroma: UInt8 = 128) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value), kCVReturnSuccess)
        let buffer = try XCTUnwrap(value)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for (plane, level) in [luma, chroma].enumerated() {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            memset(base, Int32(level), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        return buffer
    }

    private func bytes(_ buffer: CVPixelBuffer) -> [[UInt8]] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return (0..<2).map { plane in
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
            return (0..<CVPixelBufferGetHeightOfPlane(buffer, plane)).flatMap { row in
                Array(UnsafeBufferPointer(start: base.advanced(by: row * stride), count: CVPixelBufferGetWidth(buffer)))
            }
        }
    }
}
