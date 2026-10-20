import Foundation
import CryptoKit
import SetbeamCore

@main struct SetbeamProbe {
    static func main() async {
        do {
            let values = CommandLine.arguments
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            func option(_ name: String, fallback: URL) -> URL {
                guard let index = values.firstIndex(of: name), index + 1 < values.count else { return fallback }
                return URL(fileURLWithPath: values[index + 1], isDirectory: true)
            }
            let tools = option("--tools", fallback: root.appendingPathComponent("Vendor/bin"))
            let fixtures = option("--fixtures", fallback: root.appendingPathComponent("Fixtures"))
            let output = root.appendingPathComponent("build/probe", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let runtime = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
            do {
                _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
                var ready = false
                for _ in 0..<80 {
                    if await runtime.snapshot().sourceAvailable { ready = true; break }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                guard ready else { throw SetbeamError.runtime("Sample media did not become available.") }
                print("PASS: bundled sample video is flowing")
                let localURL = await runtime.localRTSP()
                let streams = try await run(tools: tools, args: ["-v", "error", "-rtsp_transport", "tcp", "-show_streams", "-of", "json", localURL], directory: output, executable: "ffprobe")
                let descriptions = String(decoding: streams, as: UTF8.self)
                guard descriptions.contains("h264"), descriptions.contains("opus") else { throw SetbeamError.runtime("Expected H.264 and Opus media tracks.") }
                print("PASS: H.264 video and Opus audio confirmed")
                let network = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
                do {
                    _ = try await network.prepare(source: .network(localURL), viewerAddress: "127.0.0.1")
                    var received = false
                    for _ in 0..<60 {
                        if await network.snapshot().sourceAvailable { received = true; break }
                        try await Task.sleep(nanoseconds: 200_000_000)
                    }
                    guard received else { throw SetbeamError.runtime("Full-URL RTSP adapter did not receive its upstream input.") }
                    try await network.saveFrame(to: output.appendingPathComponent("network-input.jpg"))
                    await network.shutdown()
                } catch { await network.shutdown(); throw error }
                guard await runtime.snapshot().sourceAvailable else { throw SetbeamError.runtime("Closing a network receiver interrupted its source.") }
                print("PASS: full-URL RTSP input including credentials and a dynamic port receives real video")
                let control = await runtime.controlOrigin()
                let (_, response) = try await URLSession.shared.data(from: URL(string: control + "/v3/config/global/get")!)
                guard (response as? HTTPURLResponse)?.statusCode == 401 else { throw SetbeamError.runtime("Anonymous administrative request was not rejected.") }
                print("PASS: anonymous administration is rejected")
                let localPicture = output.appendingPathComponent("local.jpg")
                try await runtime.saveFrame(to: localPicture)
                _ = try await runtime.startSharing()
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let livePicture = output.appendingPathComponent("audience-live.jpg")
                try await capture(runtime: runtime, tools: tools, output: livePicture, directory: output)
                let liveAudio = try await audioPeak(runtime: runtime, tools: tools, directory: output, name: "live-audio")
                try await runtime.setHold(true)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let holding = output.appendingPathComponent("audience-hold.jpg")
                try await capture(runtime: runtime, tools: tools, output: holding, directory: output)
                let holdAudio = try await audioPeak(runtime: runtime, tools: tools, directory: output, name: "hold-audio")
                guard try Data(contentsOf: livePicture) != Data(contentsOf: holding) else { throw SetbeamError.runtime("Hold did not replace outgoing video.") }
                guard await runtime.snapshot().sourceAvailable else { throw SetbeamError.runtime("Hold interrupted local media.") }
                guard liveAudio > 100, holdAudio < 8 else { throw SetbeamError.runtime("Hold did not suppress the source audio.") }
                print("PASS: Hold replaces audience video and suppresses source audio while local video continues")
                try await runtime.setHold(false)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                await runtime.stopSharing()
                guard await runtime.snapshot().sourceAvailable else { throw SetbeamError.runtime("Stop Sharing interrupted local media.") }
                let currentGuest = await runtime.snapshot().guestToken
                let denied = try await guestPublishDenied(runtime: runtime, tools: tools, fixture: fixtures.appendingPathComponent("Hold.mp4"), password: currentGuest, directory: output)
                guard denied else { throw SetbeamError.runtime("Guest publishing was not denied.") }
                print("PASS: guest publishing rejected; Stop Sharing preserves monitoring")
                let beforeRecovery = await runtime.processIDs()
                guard let inputPID = beforeRecovery.last else { throw SetbeamError.runtime("No input process to exercise recovery.") }
                kill(inputPID, SIGKILL)
                var recovered = false
                for _ in 0..<60 {
                    let snapshot = await runtime.snapshot()
                    if snapshot.sourceAvailable, !(await runtime.processIDs()).contains(inputPID) { recovered = true; break }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                guard recovered else { throw SetbeamError.runtime("Source helper did not recover after a forced process failure.") }
                print("PASS: a crashed source helper restarts and delivers fresh frames")
                let beforeServerFailure = await runtime.processIDs()
                guard let serverPID = beforeServerFailure.first else { throw SetbeamError.runtime("No media server to exercise failure reporting.") }
                kill(serverPID, SIGKILL)
                try await Task.sleep(nanoseconds: 300_000_000)
                let failedServer = await runtime.snapshot()
                guard !failedServer.sourceAvailable, failedServer.message?.contains("media server stopped") == true else { throw SetbeamError.runtime("A failed server was incorrectly reported healthy.") }
                print("PASS: media-server failure reports unavailable rather than a false live state")
                let pids = await runtime.processIDs()
                await runtime.shutdown()
                guard pids.allSatisfy({ kill($0, 0) != 0 }) else { throw SetbeamError.runtime("Owned media processes survived shutdown.") }
                print("PASS: owned media processes exited")
                print("Setbeam media integration checks passed. Browser and physical-device checks are separate.")
            } catch { await runtime.shutdown(); throw error }
        } catch { fputs("FAIL: \(Redaction.text(error.localizedDescription))\n", stderr); exit(1) }
    }

    static func run(tools: URL, args: [String], directory: URL, executable: String = "ffmpeg", expectSuccess: Bool = true) async throws -> Data {
        let task = try ManagedChild(name: executable, executable: tools.appendingPathComponent(executable), arguments: args, directory: directory)
        let deadline = Date().addingTimeInterval(12)
        while task.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        if task.isRunning { task.stop(); throw SetbeamError.runtime("Timed out during \(executable) check.") }
        try await Task.sleep(nanoseconds: 80_000_000)
        if expectSuccess && task.terminationStatus != 0 { throw SetbeamError.runtime("\(executable) failed: \(task.recentError)") }
        return Data((expectSuccess ? task.capturedOutput : task.recentError).utf8)
    }
    static func capture(runtime: MediaRuntime, tools: URL, output: URL, directory: URL) async throws {
        let url = await runtime.localRTSP("live")
        _ = try await run(tools: tools, args: ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-rtsp_transport", "tcp", "-i", url, "-frames:v", "1", "-q:v", "2", output.path], directory: directory)
    }
    static func guestPublishDenied(runtime: MediaRuntime, tools: URL, fixture: URL, password: String, directory: URL) async throws -> Bool {
        var parts = URLComponents(string: await runtime.localRTSP("live"))!; parts.user = "guest"; parts.password = password
        let errors = try await run(tools: tools, args: ["-nostdin", "-hide_banner", "-loglevel", "error", "-re", "-i", fixture.path, "-c", "copy", "-f", "rtsp", "-rtsp_transport", "tcp", parts.string!], directory: directory, expectSuccess: false)
        let text = String(decoding: errors, as: UTF8.self)
        return text.contains("401") || text.contains("403") || text.contains("Unauthorized")
    }
    static func audioPeak(runtime: MediaRuntime, tools: URL, directory: URL, name: String) async throws -> Int {
        let url = await runtime.localRTSP("live"), output = directory.appendingPathComponent(name + ".pcm")
        _ = try await run(tools: tools, args: ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-rtsp_transport", "tcp", "-i", url, "-map", "0:a:0", "-t", "0.5", "-ac", "1", "-ar", "48000", "-c:a", "pcm_s16le", "-f", "s16le", output.path], directory: directory)
        let samples = [UInt8](try Data(contentsOf: output))
        guard samples.count > 2000 else { throw SetbeamError.runtime("Not enough decoded audio for the Hold check.") }
        return stride(from: 0, to: samples.count - 1, by: 2).map { abs(Int(Int16(bitPattern: UInt16(samples[$0]) | UInt16(samples[$0+1]) << 8))) }.max() ?? 0
    }
}
