import XCTest
@testable import SetbeamCore

final class CaptureModeTests: XCTestCase {
    func testActiveSizeKeepsItsHighestCadenceInsteadOfThirty() {
        let mode = CaptureMode.select(active: (1920, 1080), formats: [
            (1280, 720, [60]), (1920, 1080, [30]), (1920, 1080, [59.940060, 30]), (3840, 2160, [30])])
        XCTAssertEqual(mode, CaptureMode(width: 1920, height: 1080, frameRate: 59.940060))
        XCTAssertEqual(mode?.arguments, ["-video_size", "1920x1080", "-framerate", "59.940060"])
    }

    func testRateComesFromTheFormatFFmpegActivates() {
        // FFmpeg activates the last 1080p format, so a 60 fps range on an earlier one cannot be used.
        let mode = CaptureMode.select(active: (1920, 1080), formats: [(1920, 1080, [60]), (1920, 1080, [30])])
        XCTAssertEqual(mode?.frameRate, 30)
    }

    func testUnknownActiveFormatLeavesSelectionUnchanged() {
        XCTAssertNil(CaptureMode.select(active: (0, 0), formats: [(1920, 1080, [30])]))
        XCTAssertNil(CaptureMode.select(active: (1920, 1080), formats: [(1280, 720, [60])]))
        XCTAssertNil(CaptureMode.select(active: (1920, 1080), formats: [(1920, 1080, [])]))
    }
}
