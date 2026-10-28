import XCTest
@testable import SetbeamCore

final class VideoPipeWriterTests: XCTestCase {
    func testLargeFrameDrainsWithoutWaitingForAnotherCaptureTick() async throws {
        let pipe = Pipe(), queue = DispatchQueue(label: "test.screen-pipe")
        let finished = expectation(description: "One large screen frame drains")
        let reader = DispatchGroup()
        let bytes = Data((0..<512 * 1024).map { UInt8(truncatingIfNeeded: $0) })
        let writer = VideoPipeWriter(output: pipe.fileHandleForWriting, queue: queue) { XCTFail("A reading consumer must not fail") }
        reader.enter()
        DispatchQueue.global().async {
            defer { reader.leave() }
            var received = Data()
            while received.count < bytes.count {
                guard let next = try? pipe.fileHandleForReading.read(upToCount: 4096), !next.isEmpty else { break }
                received.append(next)
            }
            XCTAssertEqual(received, bytes)
            finished.fulfill()
        }
        queue.sync { writer.append(bytes) }
        await fulfillment(of: [finished], timeout: 3)
        queue.sync { writer.close() }
        _ = reader.wait(timeout: .now() + 1)
        try pipe.fileHandleForReading.close()
    }

    func testBlockedConsumerExceedingTheBoundClosesThePipeOnce() throws {
        let pipe = Pipe(), queue = DispatchQueue(label: "test.blocked-screen-pipe")
        var failures = 0
        let writer = VideoPipeWriter(output: pipe.fileHandleForWriting, queue: queue, maximumPendingBytes: 128 * 1024) { failures += 1 }
        let frame = Data(repeating: 1, count: 96 * 1024)
        queue.sync { for _ in 0..<3 { writer.append(frame) }; writer.close() }
        XCTAssertEqual(failures, 1)
        let delivered = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertLessThan(delivered.count, 3 * frame.count)
        XCTAssertTrue(delivered.allSatisfy { $0 == 1 })
        try pipe.fileHandleForReading.close()
    }
}
