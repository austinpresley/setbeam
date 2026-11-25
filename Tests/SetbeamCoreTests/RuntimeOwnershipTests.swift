import XCTest
import Darwin
@testable import SetbeamCore

final class RuntimeOwnershipTests: XCTestCase {
    private func runtimePaths() throws -> RuntimePaths {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = ProcessInfo.processInfo.environment["SETBEAM_TEST_TOOLS"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Vendor/bin")
        let fixtures = ProcessInfo.processInfo.environment["SETBEAM_TEST_FIXTURES"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Fixtures")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffmpeg").path) else {
            throw XCTSkip("Bundled media tools are required for runtime ownership checks.")
        }
        return RuntimePaths(tools: tools, fixtures: fixtures)
    }

    private func runtime() throws -> MediaRuntime { try MediaRuntime(paths: runtimePaths()) }

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

    func testHoldCutsPausedPublisherWithoutWaitingForItsGracePeriod() async throws {
        let runtime = try runtime()
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            _ = try await runtime.startSharing()
            let readyBy = ContinuousClock.now + .seconds(15)
            while !(await runtime.snapshot()).audienceAvailable && ContinuousClock.now < readyBy {
                try await Task.sleep(for: .milliseconds(50))
            }
            let live = await runtime.snapshot()
            XCTAssertTrue(live.audienceAvailable)
            let owned = await runtime.processIDs()
            let publisher = try XCTUnwrap(owned.count == 3 ? owned.last : nil)
            guard kill(-publisher, SIGSTOP) == 0 else {
                throw SetbeamError.runtime("Could not pause the owned audience publisher.")
            }
            let cutBy = ContinuousClock.now + .milliseconds(1750)
            let hold = Task { try await runtime.setHold(true) }
            while kill(publisher, 0) == 0 && ContinuousClock.now < cutBy {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertNotEqual(kill(publisher, 0), 0, "Hold must cut a paused publisher without waiting for TERM.")
            try await hold.value
            let held = await runtime.snapshot()
            XCTAssertTrue(held.session.holding)
            XCTAssertEqual(held.guestToken, live.guestToken)
            let current = await runtime.processIDs()
            XCTAssertEqual(current.prefix(2), owned.prefix(2), "Hold must preserve the server and private publisher.")
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }

    func testAudienceRetriesInSoftwareWithoutRotatingItsLink() async throws {
        let paths = try runtimePaths()
        let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                   appropriateFor: FileManager.default.temporaryDirectory, create: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["mediamtx", "ffprobe", "setbeam-supervisor"] {
            let helper = paths.tools.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: helper.path) {
                try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(name), withDestinationURL: helper)
            }
        }
        func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let marker = directory.appendingPathComponent("hardware-attempts")
        let wrapper = directory.appendingPathComponent("ffmpeg")
        try """
        #!/bin/sh
        for option in "$@"; do
          if [ "$option" = '-hwaccel' ]; then
            printf '\\n' >> \(quoted(marker.path))
            exit 1
          fi
        done
        exec \(quoted(paths.tools.appendingPathComponent("ffmpeg").path)) "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let runtime = MediaRuntime(paths: RuntimePaths(tools: directory, fixtures: paths.fixtures))
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            let privateProcesses = await runtime.processIDs()
            let attempted = try await runtime.startSharing()
            let deadline = ContinuousClock.now + .seconds(15)
            var recovered = await runtime.snapshot()
            while !recovered.audienceAvailable && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
                recovered = await runtime.snapshot()
            }
            XCTAssertTrue(recovered.audienceAvailable)
            XCTAssertGreaterThan(recovered.audienceRevision, attempted.audienceRevision)
            XCTAssertEqual(recovered.guestToken, attempted.guestToken)
            let current = await runtime.processIDs()
            XCTAssertEqual(current.prefix(2), privateProcesses.prefix(2))
            let diagnostics = await runtime.diagnosticStatus()
            XCTAssertEqual(diagnostics["audienceVideoToolbox"] as? Bool, false)
            await runtime.setVideoSettings(quality: .light)
            XCTAssertEqual(try Data(contentsOf: marker).count, 1, "A settings restart must retain the software fallback for this input.")
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
