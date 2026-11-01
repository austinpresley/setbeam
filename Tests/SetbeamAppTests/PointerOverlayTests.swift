import XCTest
import SwiftUI
import SetbeamCore
@testable import SetbeamApp

@MainActor final class PointerOverlayTests: XCTestCase {
    private func pointer(_ number: Int, remaining: TimeInterval, x: Double = 0.5, y: Double = 0.5) -> SharedPointer {
        SharedPointer(number: number, label: "P\(number)", color: .blue, x: x, y: y, remaining: remaining)
    }

    func testNativePointersExpireLocallyWithoutAnotherUpdate() async throws {
        let model = PointerPresenceModel()
        let now = Date()
        model.show([pointer(1, remaining: 0.15), pointer(2, remaining: 3)], now: now)
        XCTAssertEqual(model.items.map(\.id), [1, 2])
        model.prune(now: now.addingTimeInterval(0.2))
        XCTAssertEqual(model.items.map(\.id), [2])
        // The scheduled expiry also runs on its own.
        model.show([pointer(3, remaining: 0.1)])
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(model.items.isEmpty)
        model.show([pointer(4, remaining: 3)]); model.clear()
        XCTAssertTrue(model.items.isEmpty)
    }

    func testReleasedModelLeavesNoRunningExpiry() async throws {
        weak var released: PointerPresenceModel?
        do {
            let model = PointerPresenceModel()
            model.show([pointer(1, remaining: 0.2)])
            released = model
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(released, "The pending expiry does not retain the overlay model")
    }

    func testMappingUsesTheVisiblePictureNotTheLetterboxedView() {
        // A 4:3 picture in the 16:9 main monitor is pillarboxed.
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let picture = PointerMapping.fit(CGSize(width: 1440, height: 1080), in: bounds)
        XCTAssertEqual(picture, CGRect(x: 200, y: 0, width: 1200, height: 900))
        XCTAssertEqual(PointerMapping.point(x: 0, y: 0, in: picture), CGPoint(x: 200, y: 0))
        XCTAssertEqual(PointerMapping.point(x: 1, y: 1, in: picture), CGPoint(x: 1400, y: 900))
        // A tall portrait source is letterboxed horizontally too; the center stays the center.
        let portrait = PointerMapping.fit(CGSize(width: 1080, height: 1920), in: bounds)
        XCTAssertEqual(PointerMapping.point(x: 0.5, y: 0.5, in: portrait), CGPoint(x: 800, y: 450))
        XCTAssertEqual(portrait.height, 900); XCTAssertEqual(portrait.width, 506.25, accuracy: 0.01)
        XCTAssertEqual(PointerMapping.fit(.zero, in: bounds), .zero)
    }

    /// The floating overlay covers the zoomed image rectangle. Zooming at a viewer's pointer keeps
    /// that pointer over the same screen point, and panning moves it exactly with the picture.
    func testFloatingZoomAndPanKeepPointersOnTheSamePictureDetail() {
        let source = CGSize(width: 2560, height: 1080), bounds = CGRect(x: 0, y: 0, width: 640, height: 270)
        var viewport = PreviewViewport()
        let detail = (x: 0.8, y: 0.3)
        let before = PointerMapping.point(x: detail.x, y: detail.y, in: viewport.imageRect(source: source, bounds: bounds))
        viewport.zoom(by: 2.5, at: before, source: source, bounds: bounds)
        let zoomed = PointerMapping.point(x: detail.x, y: detail.y, in: viewport.imageRect(source: source, bounds: bounds))
        XCTAssertEqual(zoomed.x, before.x, accuracy: 0.001); XCTAssertEqual(zoomed.y, before.y, accuracy: 0.001)
        viewport.pan(by: CGSize(width: -30, height: 12), source: source, bounds: bounds)
        let panned = PointerMapping.point(x: detail.x, y: detail.y, in: viewport.imageRect(source: source, bounds: bounds))
        XCTAssertEqual(panned.x, zoomed.x - 30, accuracy: 0.001); XCTAssertEqual(panned.y, zoomed.y + 12, accuracy: 0.001)
        // A detail outside the zoomed view maps outside the visible bounds and is clipped, not clamped.
        let corner = PointerMapping.point(x: 0, y: 0, in: viewport.imageRect(source: source, bounds: bounds))
        XCTAssertFalse(bounds.contains(corner))
        viewport.reset()
        XCTAssertEqual(PointerMapping.point(x: 0.5, y: 0.5, in: viewport.imageRect(source: source, bounds: bounds)), CGPoint(x: 320, y: 135))
    }

    /// The arrow's tip marks the shared point. A label flipped near the right or bottom edge must
    /// not move the arrow.
    func testArrowTipStaysOnThePointWhenTheLabelFlips() throws {
        for flip in [false, true] {
            let canvas = ZStack(alignment: .topLeading) {
                Color.black
                PointerMark(label: "A long participant name", color: .yellow, flipX: flip, flipY: flip).position(x: 100, y: 100)
            }.frame(width: 200, height: 200)
            let renderer = ImageRenderer(content: canvas)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            func pixel(_ x: Int, _ y: Int) throws -> [UInt8] {
                var value = [UInt8](repeating: 0, count: 4)
                let context = try XCTUnwrap(CGContext(data: &value, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: -x, y: -(image.height - y - 1), width: image.width, height: image.height))
                return value
            }
            // Just inside the tip, five points right and nine down from the shared point, is the arrow's fill.
            let tip = try pixel(105, 109)
            XCTAssertGreaterThan(tip[0], 200, "flip \(flip)"); XCTAssertGreaterThan(tip[1], 160, "flip \(flip)"); XCTAssertLessThan(tip[2], 90, "flip \(flip)")
            // Thirty points right of the tip is outside the arrow and outside either label placement.
            let beside = try pixel(130, 105)
            XCTAssertLessThan(Int(beside[0]) + Int(beside[1]) + Int(beside[2]), 60, "flip \(flip): nothing drawn beside the tip")
        }
    }
}
