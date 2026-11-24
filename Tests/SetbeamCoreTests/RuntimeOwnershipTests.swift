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

    func testLiveButUnresponsiveControllerIsReplacedAndKeepsHeldShare() async throws {
        let runtime = try runtime()
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            _ = try await runtime.startSharing()
            try await runtime.setHold(true)
            let original = await runtime.snapshot()
            let originalProcesses = await runtime.processIDs()
            let server = try XCTUnwrap(originalProcesses.first)
            XCTAssertEqual(kill(-server, SIGSTOP), 0)
            var recovered = false
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                let processes = await runtime.processIDs()
                let snapshot = await runtime.snapshot()
                if processes.first != server, snapshot.sourceAvailable, snapshot.audienceAvailable {
                    XCTAssertTrue(snapshot.session.holding)
                    XCTAssertEqual(snapshot.guestToken, original.guestToken)
                    recovered = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(recovered)
            XCTAssertNotEqual(kill(server, 0), 0, "Recovery must reap the previous process group.")
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }

    func testCancelledServerLaunchReapsItsOwnedProcess() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        for tool in ["mediamtx", "ffmpeg", "ffprobe"] {
            let script = temp.appendingPathComponent(tool)
            try "#!/bin/sh\nexec /bin/sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        let runtime = MediaRuntime(paths: RuntimePaths(tools: temp, fixtures: temp))
        let prepare = Task { try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1") }
        let deadline = Date().addingTimeInterval(2)
        var processes = await runtime.processIDs()
        while processes.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            processes = await runtime.processIDs()
        }
        prepare.cancel()
        do { _ = try await prepare.value; XCTFail("The cancelled runtime prepared.") }
        catch is CancellationError {}
        let pid = try XCTUnwrap(processes.first)
        XCTAssertNotEqual(kill(pid, 0), 0)
        let remaining = await runtime.processIDs()
        XCTAssertTrue(remaining.isEmpty)
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
