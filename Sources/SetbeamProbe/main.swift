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
            // Each probe run keeps the same redacted session timeline the app writes.
            SessionLog.shared.configure(directory: output.appendingPathComponent("session-log", isDirectory: true))
            if values.contains("--pyro-h-test") {
                try await testPyroH(tools: tools, fixtures: fixtures, output: output); return
            }
            if values.contains("--frame-rate-test") {
                try await testFrameRates(tools: tools, fixtures: fixtures, output: output); return
            }
            if values.contains("--safety-test") {
                try await testSafeSwitching(tools: tools, fixtures: fixtures, output: output); return
            }
            if values.contains("--recovery-test") {
                try await testReconnects(tools: tools, fixtures: fixtures, output: output); return
            }
            if values.contains("--format-test") {
                try await testMediaFormats(tools: tools, fixtures: fixtures, output: output); return
            }
            if values.contains("--keyframe-test") {
                try await testKeyframeBursts(tools: tools, fixtures: fixtures, output: output); return
            }
            if values.contains("--accsoon-test") {
                try await testAccsoon(tools: tools, fixtures: fixtures, output: output); return
            }
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
                let incoming = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
                let inputPort = try NetworkAddress.freeTCPPort()
                let inputKey = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                do {
                    _ = try await incoming.prepare(source: .incoming(port: inputPort, key: inputKey), viewerAddress: "127.0.0.1")
                    guard let destination = await incoming.incomingDestination() else { throw SetbeamError.runtime("Incoming stream destination missing.") }
                    let sender = try ManagedChild(name: "RTMP test sender", executable: tools.appendingPathComponent("ffmpeg"),
                        arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-re", "-stream_loop", "-1", "-i", fixtures.appendingPathComponent("Demo.mp4").path, "-c", "copy", "-f", "flv", destination.server + "/" + destination.streamKey], directory: output)
                    defer { sender.stop() }
                    var received = false
                    for _ in 0..<100 {
                        if await incoming.snapshot().sourceAvailable { received = true; break }
                        try await Task.sleep(nanoseconds: 200_000_000)
                    }
                    guard received else { throw SetbeamError.runtime("Authenticated RTMP input did not produce fresh video. \(sender.recentError)") }
                    try await incoming.saveFrame(to: output.appendingPathComponent("incoming-rtmp.jpg"))
                    sender.stop(); await incoming.shutdown()
                    // A proven destination must be reusable by SEE after Setbeam reopens.
                    _ = try await incoming.prepare(source: .incoming(port: inputPort, key: inputKey), viewerAddress: "127.0.0.1")
                    guard let restored = await incoming.incomingDestination(), restored.server == destination.server, restored.streamKey == destination.streamKey else { throw SetbeamError.runtime("Incoming destination changed on restore.") }
                    await incoming.shutdown()
                } catch { await incoming.shutdown(); throw error }
                print("PASS: authenticated RTMP push produces a local picture and its saved destination is stable; Accsoon hardware is not tested")
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
                let beforeStall = await runtime.processIDs()
                guard let stalledPID = beforeStall.last else { throw SetbeamError.runtime("No source helper for the stalled-frame check.") }
                kill(-stalledPID, SIGSTOP)
                var staleDetected = false, stallRecovered = false
                for _ in 0..<120 {
                    let snapshot = await runtime.snapshot()
                    if !snapshot.sourceAvailable { staleDetected = true }
                    if staleDetected, snapshot.sourceAvailable, !(await runtime.processIDs()).contains(stalledPID) { stallRecovered = true; break }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                guard staleDetected && stallRecovered else { throw SetbeamError.runtime("Stalled video was not marked unavailable and recovered.") }
                print("PASS: a running but stalled source loses its healthy state and recovers fresh frames")
                _ = try await runtime.startSharing(); try await runtime.setHold(true)
                let heldToken = await runtime.snapshot().guestToken
                let beforeServerFailure = await runtime.processIDs()
                guard let serverPID = beforeServerFailure.first else { throw SetbeamError.runtime("No media server to exercise failure reporting.") }
                kill(serverPID, SIGKILL)
                // The engine owns its watchdog; observing status no longer initiates repair.
                // Give it time to discover the dead server without any caller requests.
                try await Task.sleep(nanoseconds: 3_000_000_000)
                var serverRecovered = false
                for _ in 0..<100 {
                    let snapshot = await runtime.snapshot()
                    if snapshot.sourceAvailable && snapshot.audienceAvailable && snapshot.guestToken == heldToken { serverRecovered = true; break }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                let diagnostic = await runtime.diagnosticStatus()
                guard serverRecovered, diagnostic["holding"] as? Bool == true else { throw SetbeamError.runtime("Server recovery did not retain the audience Hold and viewing link.") }
                let recoveredHoldAudio = try await audioPeak(runtime: runtime, tools: tools, directory: output, name: "recovered-hold")
                guard recoveredHoldAudio < 8 else { throw SetbeamError.runtime("Server recovery leaked source audio during Hold.") }
                print("PASS: media-server recovery preserves the source, viewing link, and silent audience Hold")
                let pids = await runtime.processIDs()
                await runtime.shutdown()
                guard pids.allSatisfy({ kill($0, 0) != 0 }) else { throw SetbeamError.runtime("Owned media processes survived shutdown.") }
                print("PASS: owned media processes exited")
                print("Setbeam media integration checks passed. Browser and physical-device checks are separate.")
            } catch { await runtime.shutdown(); throw error }
        } catch { fputs("FAIL: \(Redaction.text(error.localizedDescription))\n", stderr); exit(1) }
    }

    static func testSafeSwitching(tools: URL, fixtures: URL, output: URL) async throws {
        let runtime = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        var sender: ManagedChild?
        var continuousReader: ManagedChild?
        func waitFor(_ predicate: (RuntimeSnapshot) -> Bool) async throws -> RuntimeSnapshot {
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline {
                let snapshot = await runtime.snapshot()
                if predicate(snapshot) { return snapshot }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            throw SetbeamError.runtime("Safe source-change media did not reach the expected state. \(await runtime.diagnosticStatus())")
        }
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            _ = try await waitFor { $0.sourceAvailable }
            _ = try await runtime.startSharing()
            let original = try await waitFor { $0.sourceAvailable && $0.audienceAvailable }
            guard let serverPID = await runtime.processIDs().first else { throw SetbeamError.runtime("Missing source-change server.") }
            let localURL = await runtime.localRTSP()
            guard original.sourceHasAudio && original.audienceHasAudio else { throw SetbeamError.runtime("Sample audio track status was not observed.") }
            do {
                _ = try await runtime.replaceSource(.network("https://invalid.example/feed"))
                throw SetbeamError.runtime("An invalid replacement was accepted.")
            } catch SetbeamError.invalidSource { }
            guard await runtime.diagnosticStatus()["holding"] as? Bool == false else { throw SetbeamError.runtime("An invalid source interrupted live sharing.") }
            let key = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let port = try NetworkAddress.freeTCPPort()
            _ = try await runtime.replaceSource(.incoming(port: port, key: key), inputAddress: "127.0.0.1")
            let offline = try await waitFor { !$0.sourceAvailable && $0.audienceAvailable }
            guard offline.guestToken == original.guestToken, offline.audience == original.audience,
                  await runtime.localRTSP() == localURL,
                  await runtime.processIDs().first == serverPID,
                  await runtime.diagnosticStatus()["holding"] as? Bool == true else {
                throw SetbeamError.runtime("An offline replacement changed the viewing identity or escaped Hold.")
            }
            guard let holdingPID = await runtime.processIDs().last else { throw SetbeamError.runtime("Missing holding publisher.") }
            let holdingRevision = offline.audienceRevision
            continuousReader = try ManagedChild(name: "Continuous audience decoder", executable: tools.appendingPathComponent("ffmpeg"),
                arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-progress", "pipe:1", "-stats_period", "0.25",
                    "-rtsp_transport", "tcp", "-i", await runtime.localRTSP("live"), "-map", "0:v:0", "-an", "-c:v", "wrapped_avframe", "-f", "null", "-"], directory: output)
            func assertHoldingContinues() async throws {
                let value = await runtime.snapshot(), pids = await runtime.processIDs()
                guard pids.first == serverPID, pids.last == holdingPID, value.audienceRevision == holdingRevision,
                      value.guestToken == original.guestToken, value.audienceAvailable,
                      continuousReader?.isRunning == true,
                      let frame = continuousReader?.lastVideoFrameAt, Date().timeIntervalSince(frame) < 3 else {
                    throw SetbeamError.runtime("An input change interrupted the existing server, holding publisher, or continuous audience decoder.")
                }
            }
            let offlineAudio = try await audioPeak(runtime: runtime, tools: tools, directory: output, name: "switch-offline-hold")
            guard offlineAudio < 8 else { throw SetbeamError.runtime("Offline replacement leaked source audio.") }
            guard let destination = await runtime.incomingDestination() else { throw SetbeamError.runtime("Replacement incoming destination missing.") }
            sender = try ManagedChild(name: "Silent replacement sender", executable: tools.appendingPathComponent("ffmpeg"),
                arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-re", "-stream_loop", "-1", "-i", fixtures.appendingPathComponent("Demo.mp4").path,
                    "-c:v", "copy", "-an", "-f", "flv", destination.server + "/" + destination.streamKey], directory: output)
            let silent = try await waitFor { $0.sourceAvailable && $0.audienceAvailable }
            try await assertHoldingContinues()
            guard !silent.sourceHasAudio, await runtime.diagnosticStatus()["holding"] as? Bool == true else {
                throw SetbeamError.runtime("A fresh replacement resumed automatically or invented source audio.")
            }
            try await runtime.saveFrame(to: output.appendingPathComponent("switch-private-input.jpg"))
            try await capture(runtime: runtime, tools: tools, output: output.appendingPathComponent("switch-audience-hold.jpg"), directory: output)
            guard try Data(contentsOf: output.appendingPathComponent("switch-private-input.jpg")) != Data(contentsOf: output.appendingPathComponent("switch-audience-hold.jpg")) else {
                throw SetbeamError.runtime("A held replacement leaked its private source picture.")
            }
            let occupiedPort = try NetworkAddress.freeTCPPort()
            let occupiedSocket = socket(AF_INET, SOCK_STREAM, 0)
            guard occupiedSocket >= 0 else { throw SetbeamError.runtime("Could not create occupied input fixture.") }
            defer { close(occupiedSocket) }
            var occupiedAddress = sockaddr_in()
            occupiedAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); occupiedAddress.sin_family = sa_family_t(AF_INET)
            occupiedAddress.sin_addr.s_addr = inet_addr("127.0.0.1"); occupiedAddress.sin_port = occupiedPort.bigEndian
            let didBind = withUnsafePointer(to: &occupiedAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(occupiedSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            } }
            guard didBind, listen(occupiedSocket, 1) == 0 else { throw SetbeamError.runtime("Could not occupy input fixture port.") }
            do {
                _ = try await runtime.replaceSource(.incoming(port: occupiedPort, key: UUID().uuidString.replacingOccurrences(of: "-", with: "")), inputAddress: "127.0.0.1")
                throw SetbeamError.runtime("An occupied incoming destination was accepted.")
            } catch SetbeamError.unavailable { }
            try await assertHoldingContinues()
            guard await runtime.snapshot().sourceAvailable,
                  await runtime.incomingDestination()?.streamKey == destination.streamKey else {
                throw SetbeamError.runtime("A failed incoming binding interrupted the original private source.")
            }
            // Replacing an incoming key on the same listener must end the old
            // sender's existing authorization without touching audience readers.
            let replacementKey = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            _ = try await runtime.replaceSource(.incoming(port: port, key: replacementKey), inputAddress: "127.0.0.1")
            _ = try await waitFor { !$0.sourceAvailable && $0.audienceAvailable }
            try await assertHoldingContinues()
            let senderDeadline = Date().addingTimeInterval(5)
            while sender?.isRunning == true && Date() < senderDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
            guard sender?.isRunning == false else { throw SetbeamError.runtime("The old incoming credential retained an active publisher.") }
            sender?.stop(); sender = nil
            guard let changedDestination = await runtime.incomingDestination(), changedDestination.streamKey != destination.streamKey else {
                throw SetbeamError.runtime("The replacement incoming credential was not applied.")
            }
            sender = try ManagedChild(name: "Replacement credential sender", executable: tools.appendingPathComponent("ffmpeg"),
                arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-re", "-stream_loop", "-1", "-i", fixtures.appendingPathComponent("Demo.mp4").path,
                    "-c:v", "copy", "-an", "-f", "flv", changedDestination.server + "/" + changedDestination.streamKey], directory: output)
            _ = try await waitFor { $0.sourceAvailable && $0.audienceAvailable }
            try await assertHoldingContinues()
            sender?.stop(); sender = nil
            let absentRTSPPort = try NetworkAddress.freeTCPPort()
            _ = try await runtime.replaceSource(.network("rtsp://127.0.0.1:\(absentRTSPPort)/absent"))
            _ = try await waitFor { !$0.sourceAvailable && $0.audienceAvailable }
            try await assertHoldingContinues()
            _ = try await runtime.replaceSource(.incoming(port: port, key: replacementKey), inputAddress: "127.0.0.1")
            sender = try ManagedChild(name: "Returned incoming sender", executable: tools.appendingPathComponent("ffmpeg"),
                arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-re", "-stream_loop", "-1", "-i", fixtures.appendingPathComponent("Demo.mp4").path,
                    "-c:v", "copy", "-an", "-f", "flv", changedDestination.server + "/" + changedDestination.streamKey], directory: output)
            _ = try await waitFor { $0.sourceAvailable && $0.audienceAvailable }
            try await assertHoldingContinues()
            continuousReader?.stop(); continuousReader = nil
            try await runtime.setHold(false)
            _ = try await waitFor { $0.sourceAvailable && $0.audienceAvailable && !$0.audienceHasAudio }
            sender?.stop(); sender = nil
            _ = try await runtime.replaceSource(.sample)
            let returned = try await waitFor { $0.sourceAvailable && $0.audienceAvailable && $0.sourceHasAudio }
            guard returned.guestToken == original.guestToken, returned.audience == original.audience,
                  await runtime.diagnosticStatus()["holding"] as? Bool == true else { throw SetbeamError.runtime("Returning to the previous input lost the viewing link or Hold.") }
            try await runtime.setHold(false)
            _ = try await waitFor { $0.sourceAvailable && $0.audienceAvailable && $0.audienceHasAudio }
            let resumedAudio = try await audioPeak(runtime: runtime, tools: tools, directory: output, name: "switch-resumed-audio")
            guard resumedAudio > 100 else { throw SetbeamError.runtime("Explicit Resume failed to restore source audio.") }
            let ids = await runtime.processIDs()
            await runtime.shutdown()
            guard ids.allSatisfy({ kill($0, 0) != 0 }) else { throw SetbeamError.runtime("Source changes left owned processes running.") }
            print("PASS: invalid source preserves live sharing; input swaps and an occupied incoming port retain the same server and holding publisher with continuous decoded audience video; incoming key rotation disconnects the old sender")
            print("PASS: offline RTSP/RTMP replacements hold real video/audio; fresh replacements stay held; return and explicit Resume preserve viewing identity")
            print("PASS: received/outgoing audio track status distinguishes sample audio, silent Hold, and a video-only input; owned processes exit")
        } catch { continuousReader?.stop(); sender?.stop(); await runtime.shutdown(); throw error }
    }

    /// Feed incompatible encoded media into the generic adapter rather than
    /// testing it only with another Setbeam instance's already-normalized output.
    static func testMediaFormats(tools: URL, fixtures: URL, output: URL) async throws {
        let runtime = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        let fixtureDirectory = output.appendingPathComponent("formats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let port = try NetworkAddress.freeTCPPort()
        var controlPort = try NetworkAddress.freeTCPPort()
        while controlPort == port { controlPort = try NetworkAddress.freeTCPPort() }
        let password = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let configuration: [String: Any] = ["logLevel": "warn", "api": true, "apiAddress": "127.0.0.1:\(controlPort)",
            "rtspAddress": "127.0.0.1:\(port)", "rtspTransports": ["tcp"], "rtmp": false, "hls": false,
            "webrtc": false, "srt": false, "moq": false,
            "authInternalUsers": [["user": "fixture", "pass": password, "ips": ["127.0.0.1"],
                "permissions": [["action": "publish", "path": "fixture"], ["action": "read", "path": "fixture"], ["action": "api"]]]],
            "paths": ["fixture": ["source": "publisher", "overridePublisher": false]]]
        let configurationURL = fixtureDirectory.appendingPathComponent("mediamtx.json")
        try JSONSerialization.data(withJSONObject: configuration).write(to: configurationURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
        let server = try ManagedChild(name: "Codec fixture server", executable: tools.appendingPathComponent("mediamtx"), arguments: [configurationURL.path], directory: fixtureDirectory)
        var sender: ManagedChild?
        defer { sender?.stop(); server.stop() }
        func fixtureStatus() async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(controlPort)/v3/paths/get/fixture")!, timeoutInterval: 2)
            request.setValue("Basic " + Data("fixture:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SetbeamError.runtime("Fixture server not ready.") }
            return value
        }
        func waitFor(_ predicate: (RuntimeSnapshot) -> Bool) async throws -> RuntimeSnapshot {
            let deadline = Date().addingTimeInterval(35)
            while Date() < deadline {
                let value = await runtime.snapshot()
                if predicate(value) { return value }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            throw SetbeamError.runtime("Codec/format transition timed out. \(await runtime.diagnosticStatus())")
        }
        /// `passthrough` names the source codec the private relay must keep; nil requires the browser contract.
        func verifyOutput(_ path: String, width: Int, height: Int, rate: String, audio: Bool, passthrough: String? = nil, loopAudioPadding: Double = 0) async throws {
            let data = try await run(tools: tools, args: ["-v", "error", "-analyzeduration", "2000000", "-fpsprobesize", "0", "-max_ts_probe", "0",
                "-rtsp_transport", "tcp", "-show_streams", "-of", "json", await runtime.localRTSP(path)], directory: fixtureDirectory, executable: "ffprobe")
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let streams = value["streams"] as? [[String: Any]],
                  let video = streams.first(where: { $0["codec_type"] as? String == "video" }),
                  video["width"] as? Int == width, video["height"] as? Int == height,
                  streams.contains(where: { $0["codec_name"] as? String == "opus" }) == audio else {
                throw SetbeamError.runtime("The \(path) relay lost its \(width)x\(height) picture or Opus audio state. \(String(decoding: data, as: UTF8.self))")
            }
            if let passthrough {
                guard video["codec_name"] as? String == passthrough else {
                    throw SetbeamError.runtime("The \(path) relay re-encoded the received \(passthrough) picture. \(String(decoding: data, as: UTF8.self))")
                }
            } else {
                guard video["codec_name"] as? String == "h264", (video["profile"] as? String ?? "").lowercased().contains("baseline"),
                      video["has_b_frames"] as? Int == 0, ["yuv420p", "yuvj420p"].contains(video["pix_fmt"] as? String ?? "") else {
                    throw SetbeamError.runtime("The \(path) relay did not satisfy the H.264 baseline/no-B-frame/Opus contract at \(width)x\(height) \(rate). \(String(decoding: data, as: UTF8.self))")
                }
            }
            // RTSP's declared rate can be inferred from the first few packets and
            // vary between probes. Measure the decoded presentation timeline.
            let ratio = rate.split(separator: "/").compactMap { Double($0) }
            // Local monitoring keeps the received cadence; nothing Setbeam encodes for viewers exceeds 30 fps.
            let expected = path == "live" ? min(ratio[0] / ratio[1], Double(VideoFrameRate.maximum)) : ratio[0] / ratio[1]
            // An initial RTCP clock adjustment can end a relative-time read interval
            // before it contains a measurable timeline. Count selected video packets.
            let packets = Int(ceil(expected * 5)) + 4
            let timingData = try await run(tools: tools, args: ["-v", "error", "-analyzeduration", "2000000", "-fpsprobesize", "0", "-max_ts_probe", "0",
                "-threads:v", "2", "-thread_type:v", "slice", "-rtsp_transport", "tcp", "-select_streams", "v:0",
                "-read_intervals", "%+#\(packets)", "-show_frames", "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", await runtime.localRTSP(path)], directory: fixtureDirectory, executable: "ffprobe")
            try timingData.write(to: output.appendingPathComponent("format-\(path)-\(width)-\(height)-timing.json"), options: .atomic)
            let timing = try JSONSerialization.jsonObject(with: timingData) as? [String: Any]
            // Closing a finite read can leave trailing B pictures without their future
            // reference packets. Judge the interior timeline, outside the codec's reorder tail.
            let reorderTail = max(1, (video["has_b_frames"] as? Int ?? 0) + 1)
            let timed = (timing?["frames"] as? [[String: Any]] ?? []).compactMap { ($0["best_effort_timestamp_time"] as? String).flatMap(Double.init) }
            // A sender report can align the initial RTP/NTP clocks after playback has
            // started. Measure steady cadence after that startup mapping settles.
            let steadyStart = (timed.first ?? 0) + 2
            let frames = Array(timed.drop(while: { $0 < steadyStart }).dropLast(reorderTail))
            guard let first = frames.first, let last = frames.last, last - first >= 1, frames.count > 1 else {
                throw SetbeamError.runtime("Not enough decoded video presentation time for the \(path) cadence check.")
            }
            let intervals = zip(frames.dropFirst(), frames).map(-)
            let measured = Double(frames.count - 1) / (last - first)
            // Demo.mp4 repeats AAC's 1024-sample priming packet at its eight-second
            // loop boundary. Stream copy must preserve that extra source interval.
            let maximumGap = loopAudioPadding > 0 ? max(1.5 / expected, 1 / expected + loopAudioPadding + 0.001) : 1.5 / expected
            guard abs(measured - expected) / expected < 0.02,
                  intervals.allSatisfy({ $0 > 0 && $0 < maximumGap }) else {
                throw SetbeamError.runtime("The \(path) relay changed decoded cadence: expected \(expected) fps, measured \(measured), largest frame interval \(intervals.max() ?? 0) seconds.")
            }
        }
        do {
            let serverDeadline = Date().addingTimeInterval(5)
            while (try? await fixtureStatus()) == nil && Date() < serverDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
            guard server.isRunning else { throw SetbeamError.runtime("Codec fixture server failed. \(server.recentError)") }
            let upstream = "rtsp://fixture:\(password)@127.0.0.1:\(port)/fixture"
            _ = try await runtime.prepare(source: .network(upstream), viewerAddress: "127.0.0.1")
            guard !(await runtime.snapshot()).sourceAvailable else { throw SetbeamError.runtime("Offline codec fixture was reported ready.") }
            var stableServer: Int32?, stableHolding: Int32?, stableCredential: String?, stableRevision: Int?
            let formats: [(String, String, Int, Int, String, Bool, String)] = [
                ("Compatibility-HEVC.mp4", "HEVC Main with B frames", 640, 360, "30/1", false, "hevc"),
                ("Compatibility-H264.mp4", "H.264 High with B frames", 960, 540, "60/1", false, "h264"),
                ("Demo.mp4", "H.264 with AAC audio", 1280, 720, "24/1", true, "h264")]
            for (index, format) in formats.enumerated() {
                sender = try ManagedChild(name: "Codec fixture sender", executable: tools.appendingPathComponent("ffmpeg"),
                    arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-re", "-stream_loop", "-1", "-i", fixtures.appendingPathComponent(format.0).path,
                        "-c", "copy", "-f", "rtsp", "-rtsp_transport", "tcp", upstream], directory: fixtureDirectory)
                let value = try await waitFor { $0.sourceAvailable && $0.sourceHasAudio == format.5 }
                if index > 0 {
                    // A source format change under Hold keeps the server, holding publisher, and viewing identity.
                    let pids = await runtime.processIDs()
                    guard pids.first == stableServer, pids.last == stableHolding,
                          value.guestToken == stableCredential, value.audienceRevision == stableRevision,
                          await runtime.diagnosticStatus()["holding"] as? Bool == true else {
                        throw SetbeamError.runtime("A source format change interrupted the independent audience Hold.")
                    }
                }
                try await verifyOutput("local", width: format.2, height: format.3, rate: format.4, audio: format.5, passthrough: format.6,
                                       loopAudioPadding: format.0 == "Demo.mp4" ? 1024.0 / 48000 : 0)
                if index < 2 {
                    // Each received encoding reaches browsers through the audience's own Baseline encode.
                    if index == 0 { _ = try await runtime.startSharing() } else { try await runtime.setHold(false) }
                    _ = try await waitFor { $0.audienceAvailable && !$0.session.holding }
                    try await verifyOutput("live", width: format.2, height: format.3, rate: format.4, audio: false)
                    if index == 0 {
                        // A lighter viewer bitrate replaces only the audience encode, at the same identity.
                        let before = await runtime.snapshot(), server = await runtime.processIDs().first
                        await runtime.setAudienceQuality(.light)
                        let lighter = try await waitFor { $0.audienceAvailable && $0.audienceRevision > before.audienceRevision }
                        let serverAfter = await runtime.processIDs().first
                        guard lighter.guestToken == before.guestToken, serverAfter == server else {
                            throw SetbeamError.runtime("Changing viewer quality replaced the viewing credential.")
                        }
                        try await verifyOutput("live", width: format.2, height: format.3, rate: format.4, audio: false)
                        print("PASS: viewer quality changes restart only the audience encode and keep the viewing credential")
                    }
                    try await runtime.setHold(true)
                    let held = try await waitFor { $0.audienceAvailable }
                    let pids = await runtime.processIDs()
                    if index == 0 { stableServer = pids.first; stableCredential = held.guestToken }
                    guard pids.first == stableServer, held.guestToken == stableCredential else {
                        throw SetbeamError.runtime("Resuming a new source format replaced the server or viewing credential.")
                    }
                    stableHolding = pids.last; stableRevision = held.audienceRevision
                }
                let status = try await fixtureStatus()
                guard (status["readers"] as? [[String: Any]])?.count == 1 else {
                    throw SetbeamError.runtime("Monitoring and sharing opened more than one upstream connection.")
                }
                print(index < 2
                    ? "PASS: \(format.1) reaches local monitoring unchanged at \(format.2)x\(format.3) \(format.4) and browsers as baseline H.264 without B frames at no more than 30 fps, upstream received once"
                    : "PASS: \(format.1) reaches local monitoring unchanged at \(format.2)x\(format.3) \(format.4) with accurate audio while viewers stay on Hold, upstream received once")
                sender?.stop(); sender = nil
                _ = try await waitFor { !$0.sourceAvailable && $0.audienceAvailable }
            }
            await runtime.shutdown()
            print("PASS: codec, resolution, cadence, and audio format changes recover at the same RTSP address while the server and holding publisher remain running")
        } catch { await runtime.shutdown(); throw error }
    }

    /// Real media disappears and returns at the same authenticated destination.
    static func testReconnects(tools: URL, fixtures: URL, output: URL) async throws {
        for networkInput in [false, true] {
            let receiver = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
            let upstream = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
            var sender: ManagedChild?
            let name = networkInput ? "RTSP" : "RTMP"
            do {
                let port = try NetworkAddress.freeTCPPort()
                let key = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let destination: (server: String, streamKey: String)
                if networkInput {
                    _ = try await upstream.prepare(source: .incoming(port: port, key: key), viewerAddress: "127.0.0.1")
                    destination = await upstream.incomingDestination()!
                    _ = try await receiver.prepare(source: .network(await upstream.localRTSP()), viewerAddress: "127.0.0.1")
                } else {
                    _ = try await receiver.prepare(source: .incoming(port: port, key: key), viewerAddress: "127.0.0.1")
                    destination = await receiver.incomingDestination()!
                }
                guard !(await receiver.snapshot()).sourceAvailable else { throw SetbeamError.runtime("Absent \(name) input was reported live.") }
                var viewingCredential: String?
                for cycle in 0..<3 {
                    sender = try ManagedChild(name: "Reconnect fixture sender", executable: tools.appendingPathComponent("ffmpeg"),
                        arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-re", "-stream_loop", "-1", "-i", fixtures.appendingPathComponent("Demo.mp4").path,
                            "-c", "copy", "-f", "flv", destination.server + "/" + destination.streamKey], directory: output)
                    let deadline = Date().addingTimeInterval(35)
                    var fresh = false
                    while Date() < deadline {
                        if networkInput { _ = await upstream.snapshot() }
                        if await receiver.snapshot().sourceAvailable { fresh = true; break }
                        try await Task.sleep(nanoseconds: 200_000_000)
                    }
                    guard fresh else { throw SetbeamError.runtime("\(name) did not reconnect on cycle \(cycle + 1).") }
                    if cycle == 0 {
                        _ = try await receiver.startSharing()
                        viewingCredential = await receiver.snapshot().guestToken
                    } else {
                        let restored = await receiver.diagnosticStatus()
                        guard await receiver.snapshot().guestToken == viewingCredential,
                              restored["sharing"] as? Bool == true, restored["holding"] as? Bool == (cycle == 1) else {
                            throw SetbeamError.runtime("\(name) reconnection changed audience intent or credentials.")
                        }
                    }
                    // One outage during Hold, one during live sharing.
                    try await receiver.setHold(cycle == 0)
                    let token = await receiver.snapshot().guestToken
                    if cycle < 2 {
                        sender?.stop(); sender = nil
                        let lossDeadline = Date().addingTimeInterval(10)
                        var unavailable = false
                        while Date() < lossDeadline {
                            if networkInput { _ = await upstream.snapshot() }
                            if !(await receiver.snapshot()).sourceAvailable { unavailable = true; break }
                            try await Task.sleep(nanoseconds: 200_000_000)
                        }
                        guard unavailable else { throw SetbeamError.runtime("Lost \(name) input retained a live status.") }
                        let diagnostic = await receiver.diagnosticStatus()
                        guard diagnostic["sharing"] as? Bool == true, diagnostic["holding"] as? Bool == (cycle == 0),
                              await receiver.snapshot().guestToken == token else { throw SetbeamError.runtime("\(name) outage changed sharing, Hold, or the viewing credential.") }
                    }
                }
                let deadline = Date().addingTimeInterval(15)
                var audience = false
                while Date() < deadline {
                    if networkInput { _ = await upstream.snapshot() }
                    if await receiver.snapshot().audienceAvailable { audience = true; break }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                guard audience else { throw SetbeamError.runtime("\(name) audience did not recover after source reconnection.") }
                try await capture(runtime: receiver, tools: tools, output: output.appendingPathComponent("reconnected-\(name).jpg"), directory: output)
                print("PASS: \(name) starts offline and reconnects twice with real decoded audience video, retaining sharing, Hold, and viewing credentials")
                sender?.stop(); sender = nil
                let receiverPIDs = await receiver.processIDs()
                let pids = receiverPIDs + (await upstream.processIDs())
                await receiver.shutdown(); await upstream.shutdown()
                guard pids.allSatisfy({ kill($0, 0) != 0 }) else { throw SetbeamError.runtime("Reconnect test left owned processes running.") }
            } catch {
                sender?.stop(); await receiver.shutdown(); await upstream.shutdown(); throw error
            }
        }
    }

    static func testAccsoon(tools: URL, fixtures: URL, output: URL) async throws {
        let runtime = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        do {
            var found: AccsoonDevice?
            for _ in 0..<40 {
                found = try await runtime.discoverWireless().first(where: \.recognized)
                if found != nil { break }; try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard let device = found else { throw SetbeamError.unavailable("No identified CineView Master 4K. Join its Wi-Fi and close Accsoon SEE.") }
            print("PASS: discovered CineView Master 4K, firmware \(device.firmwareLabel ?? "unknown"), video signal \(device.videoAvailable), audio signal \(device.audioAvailable)")
            guard device.videoAvailable else { throw SetbeamError.unavailable("The transmitter has no advertised video stream. Restore its HDMI or SDI source before the picture test.") }
            _ = try await runtime.prepare(source: .accsoon(uid: device.id), viewerAddress: "127.0.0.1")
            var ready = false
            for _ in 0..<120 {
                if await runtime.snapshot().sourceAvailable { ready = true; break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard ready else {
                let diagnostic = await runtime.diagnosticStatus()
                throw SetbeamError.runtime("Accsoon did not produce a fresh decoded feed. \(diagnostic)")
            }
            try await runtime.saveFrame(to: output.appendingPathComponent("accsoon-source.jpg"))
            print("PASS: real Accsoon video decoded and exported from the private local feed")
            let localURL = await runtime.localRTSP()
            let streams = try await run(tools: tools, args: ["-v", "error", "-rtsp_transport", "tcp", "-show_streams", "-of", "json", localURL], directory: output, executable: "ffprobe")
            let descriptions = String(decoding: streams, as: UTF8.self)
            guard descriptions.contains("h264") else { throw SetbeamError.runtime("The Accsoon feed was not converted to browser-compatible H.264.") }
            print("PASS: received HEVC is converted to H.264; Opus audio track \(descriptions.contains("opus"))")
            _ = try await runtime.startSharing()
            try await capture(runtime: runtime, tools: tools, output: output.appendingPathComponent("accsoon-audience.jpg"), directory: output)
            try await runtime.setHold(true)
            try await capture(runtime: runtime, tools: tools, output: output.appendingPathComponent("accsoon-hold.jpg"), directory: output)
            let holdPeak = try await audioPeak(runtime: runtime, tools: tools, directory: output, name: "accsoon-hold-audio")
            guard holdPeak < 8 else { throw SetbeamError.runtime("Physical-source Hold did not silence outgoing audio.") }
            guard await runtime.snapshot().sourceAvailable else { throw SetbeamError.runtime("Hold interrupted the Accsoon source.") }
            await runtime.stopSharing()
            guard await runtime.snapshot().sourceAvailable else { throw SetbeamError.runtime("Stop interrupted the Accsoon source.") }
            print("PASS: real Accsoon local monitoring survives audience Hold and Stop")
            if let option = CommandLine.arguments.firstIndex(of: "--soak-seconds"), option + 1 < CommandLine.arguments.count,
               let duration = Double(CommandLine.arguments[option + 1]), duration > 0, duration <= 3_600 {
                _ = try await runtime.startSharing(); try await runtime.setHold(true)
                let credential = await runtime.snapshot().guestToken
                for cycle in 1...3 {
                    guard let sourcePID = (await runtime.processIDs()).dropFirst().first else { throw SetbeamError.runtime("No physical-source helper for recovery check.") }
                    kill(sourcePID, SIGKILL)
                    let began = Date(), deadline = Date().addingTimeInterval(20)
                    var recovered = false
                    while Date() < deadline {
                        let value = await runtime.snapshot()
                        if value.sourceAvailable, !(await runtime.processIDs()).contains(sourcePID) { recovered = true; break }
                        try await Task.sleep(nanoseconds: 200_000_000)
                    }
                    let diagnostic = await runtime.diagnosticStatus()
                    guard recovered, await runtime.snapshot().guestToken == credential, diagnostic["holding"] as? Bool == true else {
                        throw SetbeamError.runtime("Master 4K helper recovery changed the feed, viewing credential, or Hold.")
                    }
                    print(String(format: "PASS: Master 4K helper recovery %d in %.2f seconds with Hold retained", cycle, Date().timeIntervalSince(began)))
                }
                let warmup = Date().addingTimeInterval(10)
                while Date() < warmup {
                    let value = await runtime.snapshot()
                    if value.sourceAvailable && value.audienceAvailable { break }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                let began = Date(), deadline = Date().addingTimeInterval(duration)
                var samples = 0, unavailable = 0
                while Date() < deadline {
                    let value = await runtime.snapshot(); samples += 1
                    if !value.sourceAvailable || !value.audienceAvailable { unavailable += 1 }
                    guard value.guestToken == credential else { throw SetbeamError.runtime("Master 4K soak changed the viewing credential.") }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard unavailable == 0 else { throw SetbeamError.runtime("Master 4K short soak had \(unavailable) unavailable samples of \(samples).") }
                print(String(format: "PASS: Master 4K short soak %.1f seconds, %d fresh source/audience samples, no outages", Date().timeIntervalSince(began), samples))
            }
            let pids = await runtime.processIDs()
            await runtime.shutdown()
            guard pids.allSatisfy({ kill($0, 0) != 0 }) else { throw SetbeamError.runtime("Physical-source probe left owned processes running.") }
        } catch { await runtime.shutdown(); throw error }
    }

    static func run(tools: URL, args: [String], directory: URL, executable: String = "ffmpeg", expectSuccess: Bool = true, timeout: TimeInterval = 12) async throws -> Data {
        let task = try ManagedChild(name: executable, executable: tools.appendingPathComponent(executable), arguments: args, directory: directory)
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        if task.isRunning { task.stop(); throw SetbeamError.runtime("Timed out during \(executable) check.") }
        try await Task.sleep(nanoseconds: 80_000_000)
        if expectSuccess && task.terminationStatus != 0 { throw SetbeamError.runtime("\(executable) failed: \(task.recentError)") }
        return Data((expectSuccess ? task.capturedOutput : task.recentError).utf8)
    }
    static func capture(runtime: MediaRuntime, tools: URL, output: URL, directory: URL) async throws {
        let deadline = Date().addingTimeInterval(20)
        var ready = false
        while Date() < deadline {
            if await runtime.snapshot().audienceAvailable { ready = true; break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard ready else { throw SetbeamError.runtime("The audience output did not produce fresh video before capture.") }
        let url = await runtime.localRTSP("live")
        _ = try await run(tools: tools, args: ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-rtsp_transport", "tcp", "-i", url, "-frames:v", "1", "-pix_fmt", "yuvj420p", "-q:v", "2", output.path], directory: directory)
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
