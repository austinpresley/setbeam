import XCTest
@testable import SetbeamApp

final class PreviewViewportTests: XCTestCase {
    private let source = CGSize(width: 1920, height: 1080)
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 225)

    func testZoomKeepsThePointUnderThePointer() {
        var viewport = PreviewViewport()
        let pointer = CGPoint(x: 270, y: 80)
        viewport.zoom(by: 2, at: pointer, source: source, bounds: bounds)
        let rect = viewport.imageRect(source: source, bounds: bounds)
        XCTAssertEqual(rect.minX + pointer.x * 2, pointer.x, accuracy: 0.001)
        XCTAssertEqual(rect.minY + pointer.y * 2, pointer.y, accuracy: 0.001)
        XCTAssertEqual(viewport.scale, 2)
    }

    func testPanStopsAtAllPictureEdges() {
        var viewport = PreviewViewport()
        viewport.zoom(by: 3, at: CGPoint(x: bounds.midX, y: bounds.midY), source: source, bounds: bounds)
        for delta in [CGSize(width: 10000, height: 10000), CGSize(width: -10000, height: -10000)] {
            viewport.pan(by: delta, source: source, bounds: bounds)
            let rect = viewport.imageRect(source: source, bounds: bounds)
            XCTAssertLessThanOrEqual(rect.minX, bounds.minX)
            XCTAssertLessThanOrEqual(rect.minY, bounds.minY)
            XCTAssertGreaterThanOrEqual(rect.maxX, bounds.maxX)
            XCTAssertGreaterThanOrEqual(rect.maxY, bounds.maxY)
        }
    }

    func testZoomOutRestoresTheWholePictureAndClearsPan() {
        var viewport = PreviewViewport()
        viewport.zoom(by: 3, at: CGPoint(x: 50, y: 40), source: source, bounds: bounds)
        viewport.pan(by: CGSize(width: 100, height: 50), source: source, bounds: bounds)
        viewport.zoom(by: 0.01, at: .zero, source: source, bounds: bounds)
        XCTAssertEqual(viewport.scale, 1)
        XCTAssertEqual(viewport.offset, .zero)
        XCTAssertEqual(viewport.imageRect(source: source, bounds: bounds), bounds)
    }

    func testLetterboxedImageCannotPanAwayFromTheCenterOnItsShortAxis() {
        var viewport = PreviewViewport()
        let portrait = CGSize(width: 1080, height: 1920)
        viewport.zoom(by: 2, at: .zero, source: portrait, bounds: bounds)
        viewport.pan(by: CGSize(width: 10000, height: 10000), source: portrait, bounds: bounds)
        let rect = viewport.imageRect(source: portrait, bounds: bounds)
        XCTAssertEqual(rect.midX, bounds.midX, accuracy: 0.001)
        XCTAssertLessThanOrEqual(rect.minY, bounds.minY)
        XCTAssertGreaterThanOrEqual(rect.maxY, bounds.maxY)
    }

    func testResizeReclampsTheInspectionWithoutChangingZoom() {
        var viewport = PreviewViewport()
        viewport.zoom(by: 2, at: .zero, source: source, bounds: bounds)
        let smaller = CGRect(x: 0, y: 0, width: 220, height: 123.75)
        viewport.constrain(source: source, bounds: smaller)
        let rect = viewport.imageRect(source: source, bounds: smaller)
        XCTAssertEqual(viewport.scale, 2)
        XCTAssertEqual(rect.minX, smaller.minX, accuracy: 0.001)
        XCTAssertEqual(rect.minY, smaller.minY, accuracy: 0.001)
    }

    func testZoomLimitsAndInvalidInput() {
        var viewport = PreviewViewport()
        viewport.zoom(by: 100, at: .zero, source: source, bounds: bounds)
        XCTAssertEqual(viewport.scale, 6)
        for factor in [CGFloat.nan, .infinity, -1, 0] {
            viewport.zoom(by: factor, at: .zero, source: source, bounds: bounds)
            XCTAssertEqual(viewport.scale, 6)
        }
        viewport.reset()
        XCTAssertEqual(viewport.scale, 1)
        XCTAssertEqual(viewport.offset, .zero)
    }

    func testCornerResizeKeepsOppositeCornerAndAspect() {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 225)
        let resize = PreviewWindowResize(frame: frame, pointer: CGPoint(x: 499, y: 201),
            localPoint: CGPoint(x: 399, y: 224), bounds: bounds)!
        let result = resize.frame(at: CGPoint(x: 559, y: 167), minimum: CGSize(width: 220, height: 123.75))
        XCTAssertGreaterThan(result.width, frame.width)
        XCTAssertEqual(result.minX, frame.minX)
        XCTAssertEqual(result.maxY, frame.maxY, accuracy: 0.001)
        XCTAssertEqual(result.width / result.height, 16 / 9, accuracy: 0.001)
    }

    func testEdgeResizeEnforcesMinimumAndKeepsOppositeEdge() {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 225)
        let resize = PreviewWindowResize(frame: frame, pointer: CGPoint(x: 101, y: 300),
            localPoint: CGPoint(x: 1, y: 100), bounds: bounds)!
        let result = resize.frame(at: CGPoint(x: 1000, y: 300), minimum: CGSize(width: 220, height: 123.75))
        XCTAssertEqual(result.width, 220, accuracy: 0.001)
        XCTAssertEqual(result.maxX, frame.maxX, accuracy: 0.001)
        XCTAssertEqual(result.midY, frame.midY, accuracy: 0.001)
        XCTAssertNil(PreviewWindowResize(frame: frame, pointer: .zero, localPoint: CGPoint(x: 100, y: 100), bounds: bounds))
    }
}
