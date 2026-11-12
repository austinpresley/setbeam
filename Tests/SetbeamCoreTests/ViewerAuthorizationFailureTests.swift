import XCTest
import Darwin
@testable import SetbeamCore

final class ViewerAuthorizationFailureTests: XCTestCase {
    private final class FailureGate: @unchecked Sendable {
        private let lock = NSLock()
        private var step: ViewerAccessStep?
        private var audiencePID: Int32?
        private var observedAudienceRunning = false
        var audienceRunningAtFailure: Bool {
            lock.lock(); defer { lock.unlock() }; return observedAudienceRunning
        }

        func block(_ step: ViewerAccessStep, audiencePID: Int32? = nil) {
            lock.lock(); defer { lock.unlock() }
            self.step = step; self.audiencePID = audiencePID
        }
        func allow() { lock.lock(); step = nil; lock.unlock() }
        func check(_ step: ViewerAccessStep) throws {
            lock.lock(); defer { lock.unlock() }
            guard self.step == step else { return }
            observedAudienceRunning = audiencePID.map { kill($0, 0) == 0 } ?? false
            throw SetbeamError.runtime("Injected viewer authorization failure.")
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
            beforeViewerAccessStep: { try gate.check($0) })
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

    func testFailedApprovalEndsSharingBeforeUnsafeMediaCanRecover() async throws {
        let gate = FailureGate(), runtime = try runtime(gate)
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            _ = try await runtime.startSharing()
            let live = try await waitForAudience(runtime), processes = await runtime.processIDs()
            gate.block(.credentials, audiencePID: processes.last)
            do { try await runtime.setViewerAccess(approval: true, readers: []); XCTFail("Expected the controller failure.") }
            catch SetbeamError.runtime(let message) { XCTAssertEqual(message, "Injected viewer authorization failure.") }
            XCTAssertFalse(gate.audienceRunningAtFailure, "The shared publisher must stop before enabling approval can fail.")
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
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            _ = try await runtime.startSharing()
            _ = try await waitForAudience(runtime)
            try await runtime.setViewerAccess(approval: true, readers: [a, b])
            let live = try await waitForAudience(runtime), processes = await runtime.processIDs()
            gate.block(.disconnect)
            do { try await runtime.setViewerAccess(approval: true, readers: [b]); XCTFail("Expected the disconnect failure.") }
            catch SetbeamError.runtime(let message) { XCTAssertEqual(message, "Injected viewer authorization failure.") }
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
