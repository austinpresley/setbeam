import Foundation
import SetbeamCore

extension SetbeamProbe {
    /// Simulated Pyro H endpoint with actual H.264/AAC media. Does not qualify physical hardware.
    static func testPyroH(tools: URL, fixtures: URL, output: URL) async throws {
        let directory = output.appendingPathComponent("pyro-h-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let port = try NetworkAddress.freeTCPPort()
        var apiPort = try NetworkAddress.freeTCPPort()
        while apiPort == port { apiPort = try NetworkAddress.freeTCPPort() }
        let password = UUID().uuidString
        let config: [String: Any] = ["logLevel": "warn", "api": true, "apiAddress": "127.0.0.1:\(apiPort)",
            "rtspAddress": "127.0.0.1:\(port)", "rtspTransports": ["tcp"], "rtmp": false, "hls": false, "webrtc": false, "srt": false, "moq": false,
            "authInternalUsers": [
                ["user": "fixture", "pass": password, "ips": ["127.0.0.1"], "permissions": [["action": "publish", "path": "live"], ["action": "api"]]],
                ["user": "any", "pass": "", "ips": ["127.0.0.1"], "permissions": [["action": "read", "path": "live"]]]],
            "paths": ["live": ["source": "publisher", "overridePublisher": false]]]
        let configuration = directory.appendingPathComponent("mediamtx.json")
        try JSONSerialization.data(withJSONObject: config).write(to: configuration)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
        let server = try ManagedChild(name: "Pyro H simulated transmitter", executable: tools.appendingPathComponent("mediamtx"), arguments: [configuration.path], directory: directory)
        let runtime = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        var sender: ManagedChild?
        defer { sender?.stop(); server.stop() }
        func startSender() throws -> ManagedChild {
            try ManagedChild(name: "Pyro H simulated HDMI input", executable: tools.appendingPathComponent("ffmpeg"),
                arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-re", "-stream_loop", "-1", "-i", fixtures.appendingPathComponent("Demo.mp4").path,
                    "-c", "copy", "-f", "rtsp", "-rtsp_transport", "tcp", "rtsp://fixture:\(password)@127.0.0.1:\(port)/live"], directory: directory)
        }
        func status() async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(apiPort)/v3/paths/get/live")!, timeoutInterval: 2)
            request.setValue("Basic " + Data("fixture:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SetbeamError.runtime("The simulated transmitter has no picture.")
            }
            return value
        }
        func readerCount() async throws -> Int { (try await status())["readers"].flatMap { $0 as? [Any] }?.count ?? 0 }
        func waitFor(_ predicate: (RuntimeSnapshot) -> Bool) async throws -> RuntimeSnapshot {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                let value = await runtime.snapshot()
                if predicate(value) { return value }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw SetbeamError.runtime("Pyro H simulation timed out: \(await runtime.diagnosticStatus())")
        }
        do {
            // The sender can start before the server is listening, so retry its owned process if needed.
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if sender?.isRunning != true { sender?.stop(); sender = try startSender() }
                if (try? await status()["ready"] as? Bool) == true { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let network = PyroHNetwork(interface: "lo0", address: "127.0.0.1", router: "127.0.0.1")
            let sources = await PyroHDiscovery.scan(networks: [network], ports: [port])
            guard let source = sources.first, source.hasAudio, source.port == port, try await readerCount() == 0 else {
                throw SetbeamError.runtime("Discovery did not describe the simulated H.264/AAC source without a media reader.")
            }
            print("PASS: Pyro H discovery describes the /live H.264/AAC endpoint without SETUP/PLAY or an upstream media reader")
            _ = try await runtime.prepare(source: source.setup.source(address: source.address), viewerAddress: "127.0.0.1")
            _ = try await waitFor { $0.sourceAvailable && $0.sourceHasAudio }
            _ = try await runtime.startSharing()
            let live = try await waitFor { $0.sourceAvailable && $0.audienceAvailable && $0.audienceHasAudio }
            try await runtime.saveFrame(to: output.appendingPathComponent("pyro-h-simulated-local.jpg"))
            try await capture(runtime: runtime, tools: tools, output: output.appendingPathComponent("pyro-h-simulated-audience.jpg"), directory: directory)
            guard try await readerCount() == 1 else { throw SetbeamError.runtime("Native/local and audience paths opened more than one upstream reader.") }
            try await runtime.setHold(true)
            _ = try await waitFor { $0.sourceAvailable && $0.audienceAvailable && $0.session.holding }
            let heldPicture = output.appendingPathComponent("pyro-h-simulated-hold.jpg")
            try await capture(runtime: runtime, tools: tools, output: heldPicture, directory: directory)
            guard try Data(contentsOf: heldPicture) != Data(contentsOf: output.appendingPathComponent("pyro-h-simulated-audience.jpg")) else {
                throw SetbeamError.runtime("Pyro H Hold did not replace the audience picture.")
            }
            guard try await audioPeak(runtime: runtime, tools: tools, directory: directory, name: "pyro-h-hold") <= 1 else { throw SetbeamError.runtime("Pyro H Hold leaked source sound.") }
            sender?.stop(); sender = nil
            _ = try await waitFor { !$0.sourceAvailable && $0.session.holding && $0.audienceAvailable }
            sender = try startSender()
            let recovered = try await waitFor { $0.sourceAvailable && $0.audienceAvailable && $0.session.holding }
            guard recovered.guestToken == live.guestToken else { throw SetbeamError.runtime("Source recovery changed the viewing credential.") }
            try await runtime.setHold(false)
            _ = try await waitFor { $0.sourceAvailable && $0.audienceAvailable && !$0.session.holding }
            await runtime.stopSharing()
            let stopped = try await waitFor { $0.sourceAvailable && !$0.session.sharing }
            guard stopped.session.monitoring, try await readerCount() == 1 else { throw SetbeamError.runtime("Stop Sharing interrupted the Pyro H local input.") }
            await runtime.shutdown()
            guard await runtime.processIDs().isEmpty else { throw SetbeamError.runtime("Pyro H runtime left owned processes behind.") }
            print("PASS: simulated Pyro H local/audience pictures and audio, silent Hold, source-loss recovery retaining Hold/link, Resume/Stop, one upstream reader, and owned-process cleanup")
        } catch { await runtime.shutdown(); throw error }
    }
}
