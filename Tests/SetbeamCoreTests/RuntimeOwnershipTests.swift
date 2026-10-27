import XCTest
import Darwin
@testable import SetbeamCore

final class RuntimeOwnershipTests: XCTestCase {
    private func runtime() throws -> MediaRuntime {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = ProcessInfo.processInfo.environment["SETBEAM_TEST_TOOLS"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Vendor/bin")
        let fixtures = ProcessInfo.processInfo.environment["SETBEAM_TEST_FIXTURES"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Fixtures")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffmpeg").path) else {
            throw XCTSkip("Bundled media tools are required for runtime ownership checks.")
        }
        return MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
    }

    func testSourceRecoversWithoutStatusReads() async throws {
        let runtime = try runtime()
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            let deadline = Date().addingTimeInterval(15)
            while !(await runtime.snapshot()).sourceAvailable && Date() < deadline {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            let ready = await runtime.snapshot()
            XCTAssertTrue(ready.sourceAvailable)
            _ = try await runtime.startSharing()
            try await runtime.setHold(true)
            let credential = await runtime.snapshot().guestToken
            let beforeFailure = await runtime.processIDs()
            let input = try XCTUnwrap(beforeFailure.dropFirst().first)
            XCTAssertEqual(kill(input, SIGKILL), 0)
            // Deliberately do not call snapshot, diagnostics, or subscribe to updates.
            try await Task.sleep(nanoseconds: 6_000_000_000)
            let processes = await runtime.processIDs()
            XCTAssertFalse(processes.contains(input), "The engine must replace a failed source without a UI status request.")
            let recovered = await runtime.snapshot()
            XCTAssertTrue(recovered.sourceAvailable)
            XCTAssertEqual(recovered.guestToken, credential)
            let status = await runtime.diagnosticStatus()
            XCTAssertEqual(status["holding"] as? Bool, true)
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }

    func testShutdownCancelsRecovery() async throws {
        let runtime = try runtime()
        _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
        let processes = await runtime.processIDs()
        if let server = processes.first { kill(server, SIGKILL) }
        await runtime.shutdown()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let remaining = await runtime.processIDs()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(processes.allSatisfy { kill($0, 0) != 0 })
        let ended = await runtime.snapshot()
        XCTAssertFalse(ended.sourceAvailable)
        XCTAssertFalse(ended.audienceAvailable)
    }
}
