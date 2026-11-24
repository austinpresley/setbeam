import XCTest
import Darwin
@testable import SetbeamCore

final class ViewerAuthorizationFailureTests: XCTestCase {
    private final class FailureGate: @unchecked Sendable {
        private let lock = NSLock()
        private var step: ViewerAccessStep?
        private var audiencePID: Int32?
        private var observedAudienceRunning = false
        private var pauseCredentials = false
        private var pause: CheckedContinuation<Void, Never>?
        var waiting: Bool { lock.lock(); defer { lock.unlock() }; return pause != nil }
        var audienceRunningAtFailure: Bool {
            lock.lock(); defer { lock.unlock() }; return observedAudienceRunning
        }

        func block(_ step: ViewerAccessStep, audiencePID: Int32? = nil) {
            lock.lock(); defer { lock.unlock() }
            self.step = step; self.audiencePID = audiencePID
        }
        func allow() { lock.lock(); step = nil; lock.unlock() }
        func pauseNextCredentials() { lock.withLock { pauseCredentials = true } }
        func resumeCredentials() {
            lock.withLock {
                pauseCredentials = false
                pause?.resume(); pause = nil
            }
        }
        func check(_ step: ViewerAccessStep) async throws {
            if step == .credentials {
                await withCheckedContinuation { continuation in
                    lock.withLock {
                        if pauseCredentials && pause == nil { pause = continuation }
                        else { continuation.resume() }
                    }
                }
            }
            try lock.withLock {
                guard self.step == step else { return }
                observedAudienceRunning = audiencePID.map { kill($0, 0) == 0 } ?? false
                throw SetbeamError.runtime("Injected viewer authorization failure.")
            }
        }
    }

    private func runtime(_ gate: FailureGate) throws -> MediaRuntime {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = ProcessInfo.processInfo.environment["SETBEAM_TEST_TOOLS"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Vendor/bin")
        let fixtures = ProcessInfo.processInfo.environment["SETBEAM_TEST_FIXTURES"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Fixtures")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffmpeg").path) else {
            throw XCTSkip("Bundled media tools are required.")
        }
        return MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures), beforeSourceConfigurationStep: { _ in },
            beforeViewerAccessStep: { try await gate.check($0) })
    }

    private func waitForAudience(_ runtime: MediaRuntime) async throws -> RuntimeSnapshot {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let state = await runtime.snapshot()
            if state.sourceAvailable && state.audienceAvailable { return state }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SetbeamError.runtime("Authorization regression media did not become ready.")
    }

    private func authorizationStatus(_ playback: PlaybackDescriptor, user: String, password: String) async throws -> Int {
        var request = URLRequest(url: URL(string: playback.whepURL)!, timeoutInterval: 10)
        request.httpMethod = "POST"; request.httpBody = Data("v=0\r\n".utf8)
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(response as? HTTPURLResponse).statusCode
    }

    private func decodingReader(_ runtime: MediaRuntime, _ credential: ViewerReader) async throws -> ManagedChild {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = ProcessInfo.processInfo.environment["SETBEAM_TEST_TOOLS"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Vendor/bin")
        var address = URLComponents(string: await runtime.localRTSP("live"))!
        address.user = credential.user; address.password = credential.password
        let reader = try ManagedChild(name: "Authorization regression reader", executable: tools.appendingPathComponent("ffmpeg"),
            arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-progress", "pipe:1", "-stats_period", "0.2",
                "-rtsp_transport", "tcp", "-i", address.string!, "-f", "null", "-"], directory: FileManager.default.temporaryDirectory)
        let deadline = Date().addingTimeInterval(10)
        while reader.isRunning && reader.lastVideoFrameAt == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard reader.isRunning && reader.lastVideoFrameAt != nil else {
            reader.stop(); throw SetbeamError.runtime("The authorization regression reader did not decode video.")
        }
        return reader
    }

    private func assertPlaybackEnded(_ reader: ManagedChild, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while reader.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(reader.isRunning, "An already-decoding reader must lose media after the access failure.", file: file, line: line)
    }

    func testFailedPrivateApprovalCannotBeBypassedByImmediateStart() async throws {
        let gate = FailureGate(), runtime = try runtime(gate)
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            let deadline = Date().addingTimeInterval(15)
            while !(await runtime.snapshot()).sourceAvailable && Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            gate.block(.credentials)
            do { try await runtime.setViewerAccess(approval: true, readers: []); XCTFail("Expected the controller failure.") }
            catch SetbeamError.runtime(let message) { XCTAssertEqual(message, "Injected viewer authorization failure.") }
            gate.allow()
            // Start immediately, before any background access synchronization can retry.
            _ = try await runtime.startSharing()
            let live = try await waitForAudience(runtime)
            let status = try await authorizationStatus(live.audience, user: "guest", password: live.guestToken)
            XCTAssertEqual(status, 401, "Start must retain the requested approval policy after a private update fails.")
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }

    func testStartAppliesLatestApprovalAheadOfCoalescedAccessFollowup() async throws {
        let gate = FailureGate(), runtime = try runtime(gate)
        defer { gate.resumeCredentials() }
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            try await runtime.setViewerAccess(approval: true, readers: [])
            gate.pauseNextCredentials()
            let earlier = Task { try await runtime.setViewerAccess(approval: false, readers: []) }
            let deadline = Date().addingTimeInterval(5)
            while !gate.waiting && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(gate.waiting)
            // The gateway/UI has changed back to approval-on while the older request is pending.
            // Its coalesced follow-up has not entered the runtime queue when Start arrives.
            let start = Task { try await runtime.startSharing(approval: true) }
            gate.resumeCredentials()
            try await earlier.value
            _ = try await start.value
            let live = try await waitForAudience(runtime)
            let status = try await authorizationStatus(live.audience, user: "guest", password: live.guestToken)
            XCTAssertEqual(status, 401, "Start must apply its current approval choice instead of an older queued policy.")
            await runtime.shutdown()
        } catch { gate.resumeCredentials(); await runtime.shutdown(); throw error }
    }

    func testStopCutsDecodingWhileAuthorizationIsParkedAndDiscardsItsCompletion() async throws {
        let gate = FailureGate(), runtime = try runtime(gate)
        defer { gate.resumeCredentials() }
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            _ = try await runtime.startSharing()
            let live = try await waitForAudience(runtime), originalProcesses = await runtime.processIDs()
            let reader = try await decodingReader(runtime, ViewerReader(user: "guest", password: live.guestToken))
            defer { reader.stop() }

            gate.pauseNextCredentials()
            let auth = Task {
                try await runtime.setViewerAccess(approval: false, readers: [
                    ViewerReader(user: "viewerA", password: UUID().uuidString)
                ])
            }
            let deadline = Date().addingTimeInterval(2)
            while !gate.waiting && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(gate.waiting)
            let stoppedPromptly = expectation(description: "Stop completes before authorization is released")
            let stop = Task { await runtime.stopSharing(); stoppedPromptly.fulfill() }
            await fulfillment(of: [stoppedPromptly], timeout: 1)
            let stopped = await runtime.snapshot()
            let remaining = await runtime.processIDs()
            XCTAssertFalse(stopped.session.sharing)
            XCTAssertFalse(stopped.audienceAvailable)
            XCTAssertTrue(stopped.sourceAvailable)
            XCTAssertNotEqual(stopped.guestToken, live.guestToken)
            XCTAssertEqual(remaining, Array(originalProcesses.prefix(2)))
            try await assertPlaybackEnded(reader)

            gate.resumeCredentials()
            await stop.value
            do { try await auth.value; XCTFail("The stopped authorization completed.") }
            catch is CancellationError {}
            let afterAuthorization = await runtime.snapshot()
            XCTAssertFalse(afterAuthorization.session.sharing)
            XCTAssertEqual(afterAuthorization.guestToken, stopped.guestToken)
            _ = try await runtime.startSharing()
            let restarted = try await waitForAudience(runtime)
            let status = try await authorizationStatus(restarted.audience, user: "guest", password: live.guestToken)
            XCTAssertEqual(status, 401)
            await runtime.shutdown()
        } catch {
            gate.resumeCredentials()
            await runtime.shutdown()
            throw error
        }
    }

    func testRevocationRequiresACompleteValidatedListing() throws {
        let id = UUID()
        let item = ["id": id.uuidString, "user": "viewerA"]
        XCTAssertEqual(try MediaRuntime.validatedSessionUsers(["itemCount": 0, "pageCount": 0, "items": []]), [:])
        XCTAssertEqual(try MediaRuntime.validatedSessionUsers(["itemCount": 1, "pageCount": 1, "items": [item]]), [id: "viewerA"])
        for malformed: [String: Any] in [
            [:],
            ["itemCount": 2, "pageCount": 2, "items": [item]],
            ["itemCount": true, "pageCount": 1, "items": [item]],
            ["itemCount": 1, "pageCount": 1, "items": [["id": id.uuidString]]],
            ["itemCount": 1, "pageCount": 1, "items": [["id": "bad", "user": "viewerA"]]],
            ["itemCount": 2, "pageCount": 1, "items": [item, item]]
        ] {
            XCTAssertThrowsError(try MediaRuntime.validatedSessionUsers(malformed))
        }
    }

    func testFailedApprovalEndsSharingBeforeUnsafeMediaCanRecover() async throws {
        try await verifyApprovalFailure(at: .credentials)
    }

    func testLostAuthorizationConfirmationEndsAlreadyDecodingPlayback() async throws {
        try await verifyApprovalFailure(at: .credentialsApplied)
    }

    private func verifyApprovalFailure(at step: ViewerAccessStep) async throws {
        let gate = FailureGate(), runtime = try runtime(gate)
        var reader: ManagedChild?
        defer { reader?.stop() }
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            _ = try await runtime.startSharing()
            let live = try await waitForAudience(runtime), processes = await runtime.processIDs()
            reader = try await decodingReader(runtime, ViewerReader(user: "guest", password: live.guestToken))
            gate.block(step, audiencePID: processes.last)
            do { try await runtime.setViewerAccess(approval: true, readers: []); XCTFail("Expected the controller failure.") }
            catch SetbeamError.runtime(let message) { XCTAssertEqual(message, "Injected viewer authorization failure.") }
            XCTAssertFalse(gate.audienceRunningAtFailure, "The shared publisher must stop before enabling approval can fail.")
            try await assertPlaybackEnded(try XCTUnwrap(reader))
            let stopped = await runtime.snapshot(), remaining = await runtime.processIDs()
            XCTAssertFalse(stopped.session.sharing)
            XCTAssertFalse(stopped.audienceAvailable)
            XCTAssertTrue(stopped.sourceAvailable)
            XCTAssertTrue(stopped.guestToken != live.guestToken, "Ending sharing rotates its private code.")
            XCTAssertEqual(remaining, Array(processes.prefix(2)), "The source and private monitor server stay running.")
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let later = await runtime.snapshot()
            XCTAssertFalse(later.session.sharing, "Recovery must not reopen the unprotected audience output.")
            gate.allow()
            _ = try await runtime.startSharing()
            let resumed = try await waitForAudience(runtime)
            let oldStatus = try await authorizationStatus(resumed.audience, user: "guest", password: live.guestToken)
            let newStatus = try await authorizationStatus(resumed.audience, user: "guest", password: resumed.guestToken)
            XCTAssertEqual(oldStatus, 401)
            XCTAssertEqual(newStatus, 401, "Starting again retains approval instead of restoring the shared reader.")
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }

    func testFailedReaderDisconnectEndsSharingAndKeepsMonitoring() async throws {
        let gate = FailureGate(), runtime = try runtime(gate)
        let a = ViewerReader(user: "viewerA", password: UUID().uuidString)
        let b = ViewerReader(user: "viewerB", password: UUID().uuidString)
        var readers: [ManagedChild] = []
        defer { readers.forEach { $0.stop() } }
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            _ = try await runtime.startSharing()
            _ = try await waitForAudience(runtime)
            try await runtime.setViewerAccess(approval: true, readers: [a, b])
            let live = try await waitForAudience(runtime), processes = await runtime.processIDs()
            readers.append(try await decodingReader(runtime, a))
            readers.append(try await decodingReader(runtime, b))
            gate.block(.disconnect)
            do { try await runtime.setViewerAccess(approval: true, readers: [b]); XCTFail("Expected the disconnect failure.") }
            catch SetbeamError.runtime(let message) { XCTAssertEqual(message, "Injected viewer authorization failure.") }
            for reader in readers { try await assertPlaybackEnded(reader) }
            let stopped = await runtime.snapshot(), remaining = await runtime.processIDs()
            XCTAssertFalse(stopped.session.sharing)
            XCTAssertFalse(stopped.audienceAvailable)
            XCTAssertTrue(stopped.sourceAvailable)
            XCTAssertTrue(stopped.guestToken != live.guestToken, "Ending sharing rotates its private code.")
            XCTAssertEqual(remaining, Array(processes.prefix(2)))
            gate.allow()
            _ = try await runtime.startSharing()
            let resumed = try await waitForAudience(runtime)
            let removedStatus = try await authorizationStatus(resumed.audience, user: a.user, password: a.password)
            let previousStatus = try await authorizationStatus(resumed.audience, user: b.user, password: b.password)
            XCTAssertEqual(removedStatus, 401)
            XCTAssertEqual(previousStatus, 401, "The ended session's other credentials cannot carry into a new share.")
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }
}
