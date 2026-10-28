import XCTest
@testable import SetbeamCore

final class LowRateInputTests: XCTestCase {
    func testOneFPSNetworkInputWithAudioAcquiresItsPicture() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let environment = ProcessInfo.processInfo.environment
        let tools = environment["SETBEAM_TEST_TOOLS"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Vendor/bin")
        let fixtures = environment["SETBEAM_TEST_FIXTURES"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Fixtures")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffmpeg").path) else {
            throw XCTSkip("Bundled media tools are required for low-rate input checks.")
        }
        let sender = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        let receiver = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        func ready(_ engine: MediaRuntime, audience: Bool = false) async throws {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let value = await engine.snapshot()
                if value.sourceAvailable && (!audience || value.audienceAvailable) { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw SetbeamError.runtime("1 fps input did not acquire its picture: \(await engine.diagnosticStatus())")
        }
        do {
            await sender.setVideoSettings(frameRate: .fps1)
            _ = try await sender.prepare(source: .sample, viewerAddress: "127.0.0.1")
            try await ready(sender)
            _ = try await sender.startSharing()
            try await ready(sender, audience: true)
            _ = try await receiver.prepare(source: .network(await sender.localRTSP("live")), viewerAddress: "127.0.0.1")
            try await ready(receiver)
            let picture = await receiver.snapshot()
            XCTAssertTrue(picture.sourceHasAudio)
            await receiver.setVideoSettings(frameRate: .fps30)
            _ = try await receiver.startSharing()
            try await ready(receiver, audience: true)
            await receiver.shutdown(); await sender.shutdown()
        } catch { await receiver.shutdown(); await sender.shutdown(); throw error }
    }
}
