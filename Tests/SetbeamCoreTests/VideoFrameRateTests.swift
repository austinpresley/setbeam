import XCTest
@testable import SetbeamCore

final class VideoFrameRateTests: XCTestCase {
    func testScreenRateCapsWithoutIncreasingTheDisplayCadence() {
        XCTAssertEqual(VideoFrameRate.fps1.captureRate(for: 60), 1)
        XCTAssertEqual(VideoFrameRate.fps30.captureRate(for: 24), 24)
        XCTAssertEqual(VideoFrameRate.source.captureRate(for: 1), 1)
        XCTAssertNil(VideoFrameRate(rawValue: 999))
    }
    func testNothingSetbeamEncodesExceeds30FPS() {
        // Two 4K60 encodes saturated the hardware encoder at about 51 fps; stills and screens need no more.
        XCTAssertEqual(VideoFrameRate.source.captureRate(for: 60), 30)
        XCTAssertEqual(VideoFrameRate.source.captureRate(for: 120), 30)
        XCTAssertTrue(VideoFrameRate.allCases.allSatisfy { $0.rawValue <= VideoFrameRate.maximum })
        XCTAssertNil(VideoFrameRate(rawValue: 60), "A saved 60 fps choice falls back to Match source")
        let matching = MediaOutputContract.audienceVideoArguments(.best, frameRate: .source)
        XCTAssertTrue(matching[matching.firstIndex(of: "-vf")! + 1].contains("*30+0.5"))
    }
}
