import XCTest
@testable import SetbeamProbe

final class MediaCadenceTests: XCTestCase {
    func testFixtureJitterExplainsTheRecordedFiftyMillisecondInterval() throws {
        let jitter = try MediaCadence.fixtureJitter([0, 0.016732, 0.033333, 0.05], rate: 60)
        let maximum = MediaCadence.maximumGap(rate: 30, sourceJitter: jitter, loopAudioPadding: 0)
        XCTAssertGreaterThan(maximum, 0.050067, "A real source timestamp was 65 microseconds late")
        XCTAssertLessThan(maximum, 0.0501, "The correction is below 0.1 ms")
        XCTAssertLessThan(maximum, 2 / 30.0, "A missing outgoing frame still fails")
    }

    func testBadFixtureCannotWidenTheCadenceBound() {
        let invalid: [[Double]] = [[], [0], [0, 0], [0, -0.01], [0, 1 / 30.0], [0, Double.nan]]
        for timestamps in invalid {
            XCTAssertThrowsError(try MediaCadence.fixtureJitter(timestamps, rate: 60))
        }
    }

    func testCompletedReorderDepthExcludesOnlyTheTruncatedDecodeTail() {
        var timestamps = (0..<300).map { Double($0) / 60 }
        // A finite packet read flushes B pictures without their future references.
        timestamps[298] += 1 / 60.0
        timestamps[299] += 2 / 60.0
        let frames = MediaCadence.steadyFrames(timestamps, reorderDepth: 2)
        XCTAssertEqual(frames.first, 2)
        XCTAssertEqual(frames.last, 296 / 60.0)
        XCTAssertTrue(zip(frames.dropFirst(), frames).allSatisfy { $0 - $1 < 0.025 })
        timestamps[180] += 1 / 60.0
        let broken = MediaCadence.steadyFrames(timestamps, reorderDepth: 2)
        XCTAssertTrue(zip(broken.dropFirst(), broken).contains { $0 - $1 > 0.025 }, "An interior gap is still judged")
    }
}
