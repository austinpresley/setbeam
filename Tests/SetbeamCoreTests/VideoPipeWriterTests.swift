import XCTest
import Darwin
@testable import SetbeamCore

final class VideoPipeWriterTests: XCTestCase {
    private func footprint() throws -> UInt64 {
        var usage = rusage_info_v0()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V0, $0) }
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return usage.ri_phys_footprint
    }

    func testDrainedFramesDoNotAccumulateInTheDataBackingStorage() throws {
        let queue = DispatchQueue(label: "test.screen-pipe-memory")
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        let writer = VideoPipeWriter(output: output, queue: queue) { XCTFail("A writable sink must not fail") }
        defer { queue.sync { writer.close() } }
        let frame = Data(repeating: 128, count: 64 * 1024)
        let requested = ProcessInfo.processInfo.environment["SETBEAM_MEMORY_PIPE_FRAMES"].flatMap(Int.init) ?? 10_000
        let frameCount = max(10_000, min(2_000_000, requested))
        let baseline = try footprint()
        var peak = baseline, sent = 0
        // The pending byte count is zero after every append. Its backing allocation must also
        // stay bounded, regardless of the cumulative number of bytes sent during a shoot.
        try queue.sync {
            for index in 0..<frameCount {
                writer.append(frame); sent += 1
                if index % 128 == 0 { peak = max(peak, try footprint()) }
                if peak > baseline + 192 * 1024 * 1024 { break }
            }
        }
        print("Drained screen pipe: \(sent) frames, \(sent * frame.count / 1024 / 1024) MiB sent, footprint growth \((peak - baseline) / 1024 / 1024) MiB")
        XCTAssertLessThan(peak - baseline, 32 * 1024 * 1024,
                          "Drained screen frames must not remain in Data's consumed prefix.")
    }

    func testAppendingDuringAPartialWritePreservesEveryByteInOrder() async throws {
        let pipe = Pipe(), queue = DispatchQueue(label: "test.screen-pipe-partial")
        let first = Data(repeating: 37, count: 512 * 1024), second = Data(repeating: 91, count: 128 * 1024)
        let writer = VideoPipeWriter(output: pipe.fileHandleForWriting, queue: queue) { XCTFail("The combined frames fit the pending-byte limit") }
        defer { queue.sync { writer.close() }; try? pipe.fileHandleForReading.close() }
        // No reader yet: the first frame partially writes, then the second append compacts its tail.
        queue.sync { writer.append(first); writer.append(second) }
        let received = expectation(description: "Both frames drain after tail compaction")
        DispatchQueue.global().async {
            var actual = Data()
            while actual.count < first.count + second.count {
                guard let next = try? pipe.fileHandleForReading.read(upToCount: 4096), !next.isEmpty else { break }
                actual.append(next)
            }
            XCTAssertEqual(actual, first + second)
            received.fulfill()
        }
        await fulfillment(of: [received], timeout: 3)
    }

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
