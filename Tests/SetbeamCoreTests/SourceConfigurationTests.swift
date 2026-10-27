import XCTest
@testable import SetbeamCore

final class SourceConfigurationTests: XCTestCase {
    private final class FailureGate: @unchecked Sendable {
        private let lock = NSLock()
        private var blocked = true
        let step: SourceConfigurationStep
        init(_ step: SourceConfigurationStep) { self.step = step }
        func check(_ candidate: SourceConfigurationStep) throws {
            lock.lock(); let fails = blocked && candidate == step; lock.unlock()
            if fails { throw SetbeamError.runtime("Injected source configuration failure.") }
        }
        func allow() { lock.lock(); blocked = false; lock.unlock() }
    }

    func testFailedControllerUpdatesCannotShowThePreviousNetworkSourceUnderNewIdentity() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = ProcessInfo.processInfo.environment["SETBEAM_TEST_TOOLS"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Vendor/bin")
        let fixtures = ProcessInfo.processInfo.environment["SETBEAM_TEST_FIXTURES"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Fixtures")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffmpeg").path) else { throw XCTSkip("Bundled tools are required.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Setbeam-configuration-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // The previous input is a visibly different, constant bundled holding picture.
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("Hold.mp4"), to: temporary.appendingPathComponent("Demo.mp4"))
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("Hold.mp4"), to: temporary.appendingPathComponent("Hold.mp4"))
        let previous = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: temporary))
        let replacement = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        func waitFor(_ runtime: MediaRuntime, _ predicate: (RuntimeSnapshot) -> Bool) async throws -> RuntimeSnapshot {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                let value = await runtime.snapshot()
                if predicate(value) { return value }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw SetbeamError.runtime("Source configuration regression fixture timed out. \(await runtime.diagnosticStatus())")
        }
        do {
            _ = try await previous.prepare(source: .sample, viewerAddress: "127.0.0.1")
            _ = try await replacement.prepare(source: .sample, viewerAddress: "127.0.0.1")
            _ = try await waitFor(previous) { $0.sourceAvailable }
            _ = try await waitFor(replacement) { $0.sourceAvailable }
            for step in [SourceConfigurationStep.credentials, .path] {
                let gate = FailureGate(step)
                let receiver = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures), beforeSourceConfigurationStep: { try gate.check($0) })
                do {
                    _ = try await receiver.prepare(source: .network(await previous.localRTSP()), viewerAddress: "127.0.0.1")
                    _ = try await waitFor(receiver) { $0.sourceAvailable }
                    let originalPicture = temporary.appendingPathComponent("previous-\(step).jpg")
                    try await receiver.saveFrame(to: originalPicture)
                    _ = try await receiver.startSharing(); try await receiver.setHold(true)
                    let held = try await waitFor(receiver) { $0.audienceAvailable }
                    let heldProcesses = await receiver.processIDs()
                    let newSource = VideoSource.network(await replacement.localRTSP())
                    do {
                        _ = try await receiver.replaceSource(newSource)
                        XCTFail("The injected controller failure was not exercised.")
                    } catch SetbeamError.runtime(let message) {
                        XCTAssertEqual(message, "Injected source configuration failure.")
                    }
                    // Let autonomous recovery attempt the still-failing configuration.
                    // The old network feed remains healthy throughout this interval.
                    try await Task.sleep(nanoseconds: 4_000_000_000)
                    let pending = await receiver.snapshot(), pendingProcesses = await receiver.processIDs()
                    XCTAssertEqual(pending.source, newSource)
                    XCTAssertFalse(pending.sourceAvailable)
                    XCTAssertNil(pending.lastFrameAt)
                    XCTAssertTrue(pending.audienceAvailable)
                    XCTAssertEqual(pending.guestToken, held.guestToken)
                    XCTAssertEqual(pendingProcesses, [heldProcesses.first!, heldProcesses.last!], "No source publisher may read the old path until configuration succeeds.")
                    let previousStillLive = await previous.snapshot()
                    XCTAssertTrue(previousStillLive.sourceAvailable)
                    gate.allow()
                    let recovered = try await waitFor(receiver) { $0.sourceAvailable && $0.audienceAvailable }
                    XCTAssertEqual(recovered.source, newSource)
                    XCTAssertEqual(recovered.guestToken, held.guestToken)
                    let replacementPicture = temporary.appendingPathComponent("replacement-\(step).jpg")
                    try await receiver.saveFrame(to: replacementPicture)
                    XCTAssertNotEqual(try Data(contentsOf: originalPicture), try Data(contentsOf: replacementPicture))
                    let recoveredProcesses = await receiver.processIDs()
                    XCTAssertEqual(recoveredProcesses.first, heldProcesses.first)
                    XCTAssertEqual(recoveredProcesses.last, heldProcesses.last)
                    await receiver.shutdown()
                } catch { await receiver.shutdown(); throw error }
            }
            await previous.shutdown(); await replacement.shutdown()
        } catch { await previous.shutdown(); await replacement.shutdown(); throw error }
    }
}
