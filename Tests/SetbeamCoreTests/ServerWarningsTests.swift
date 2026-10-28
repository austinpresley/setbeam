import XCTest
@testable import SetbeamCore

final class ServerWarningsTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    func testWarningsAreRecordedAcrossChunksWithoutTimestampsOrInformation() {
        let warnings = ServerWarnings(interval: 10)
        XCTAssertEqual(warnings.consume("2026/10/27 20:38:11 INF [RTSP] [session 26d6ea2a] created\n2026/10/27 20:38:11 WAR [RTSP] [ses", now: start), [])
        XCTAssertEqual(warnings.consume("sion 26d6ea2a] reader is too slow, discarding 548 frames\n", now: start),
                       [.init(message: "WAR [RTSP] [session 26d6ea2a] reader is too slow, discarding 548 frames", repeats: 0)])
        XCTAssertEqual(warnings.consume("2026/10/27 20:38:12 ERR [path local] 202 processing errors, last was: invalid FU-A packet (non-starting)\n", now: start),
                       [.init(message: "ERR [path local] 202 processing errors, last was: invalid FU-A packet (non-starting)", repeats: 0)])
    }

    func testRepeatsOfOneKindAreSummarizedOncePerInterval() {
        let warnings = ServerWarnings(interval: 10)
        func line(_ session: String, _ count: Int) -> String { "2026/10/27 20:38:11 WAR [RTSP] [session \(session)] reader is too slow, discarding \(count) frames\n" }
        XCTAssertEqual(warnings.consume(line("26d6ea2a", 1), now: start).count, 1)
        // Another session's discards are the same kind of warning.
        XCTAssertEqual(warnings.consume(line("a8a08d8e", 2) + line("26d6ea2a", 3), now: start.addingTimeInterval(1)), [])
        XCTAssertEqual(warnings.due(now: start.addingTimeInterval(9)), [])
        XCTAssertEqual(warnings.due(now: start.addingTimeInterval(10)),
                       [.init(message: "WAR [RTSP] [session 26d6ea2a] reader is too slow, discarding 3 frames", repeats: 2)])
        XCTAssertEqual(warnings.due(now: start.addingTimeInterval(30)), [])
        // A later line carries the repeats it summarizes when the interval has already elapsed.
        XCTAssertEqual(warnings.consume(line("26d6ea2a", 4), now: start.addingTimeInterval(31)).count, 1)
        XCTAssertEqual(warnings.consume(line("26d6ea2a", 5), now: start.addingTimeInterval(32)), [])
        XCTAssertEqual(warnings.consume(line("26d6ea2a", 6), now: start.addingTimeInterval(42)),
                       [.init(message: "WAR [RTSP] [session 26d6ea2a] reader is too slow, discarding 6 frames", repeats: 1)])
    }

    func testAnUnterminatedFloodIsBounded() {
        let warnings = ServerWarnings(interval: 10)
        XCTAssertEqual(warnings.consume(String(repeating: "x", count: 100_000), now: start), [])
        XCTAssertEqual(warnings.consume("\n2026/10/27 20:38:11 WAR [RTSP] short\n", now: start), [.init(message: "WAR [RTSP] short", repeats: 0)])
    }
}
