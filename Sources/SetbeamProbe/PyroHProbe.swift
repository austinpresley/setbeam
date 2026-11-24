import Foundation
import os
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
        let network = PyroHNetwork.loopbackFixture
        let routes = OSAllocatedUnfairLock(initialState: [network])
        let routeChecks = OSAllocatedUnfairLock(initialState: 0)
        let currentNetworks: @Sendable () -> [PyroHNetwork] = {
            routeChecks.withLock { $0 += 1 }
            return routes.withLock { $0 }
        }
        let runtime = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures), pyroHNetworks: currentNetworks)
        let suite = "setbeam-pyro-h-probe-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
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
        func waitForNoReader() async throws {
            for _ in 0..<30 {
                if try await readerCount() == 0 { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw SetbeamError.runtime("The fixture still has an upstream reader.")
        }
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
            let sources = await PyroHDiscovery.scan(networks: [network], ports: [port], currentNetworks: currentNetworks)
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
            try await verifyHold(runtime: runtime, tools: tools, fixtures: fixtures, directory: directory,
                                 maximumHoldPeak: 1, resume: false)
            guard try await readerCount() == 1 else { throw SetbeamError.runtime("Hold opened a second upstream media reader.") }
            sender?.stop(); sender = nil
            _ = try await waitFor { !$0.sourceAvailable && $0.session.holding && $0.audienceAvailable }
            sender = try startSender()
            let recovered = try await waitFor { $0.sourceAvailable && $0.audienceAvailable && $0.session.holding }
            guard recovered.guestToken == live.guestToken else { throw SetbeamError.runtime("Source recovery changed the viewing credential.") }
            // The original endpoint remains reachable on loopback throughout this simulated route change.
            // An unscoped reconnect would attach another reader to that same numeric endpoint.
            let changed = PyroHNetwork(interface: network.interface, address: network.address, router: network.router,
                                       bssid: "00:11:22:33:44:66")
            routes.withLock { $0 = [changed] }
            let blocked = try await waitFor { !$0.sourceAvailable && $0.session.holding && $0.audienceAvailable && $0.message != nil }
            try await waitForNoReader()
            guard blocked.guestToken == live.guestToken else {
                throw SetbeamError.runtime("Changing the Pyro H route did not close the upstream reader and preserve Hold.")
            }
            let beforeRetry = routeChecks.withLock { $0 }
            await runtime.retrySource()
            _ = try await waitFor {
                routeChecks.withLock { $0 } > beforeRetry
                    && !$0.sourceAvailable && $0.session.holding && $0.audienceAvailable && $0.message != nil
            }
            guard try await readerCount() == 0 else { throw SetbeamError.runtime("Retry connected without the original Pyro H route.") }

            routes.withLock { $0 = [network] }
            let restoredRoute = try await waitFor { $0.sourceAvailable && $0.session.holding && $0.audienceAvailable }
            guard restoredRoute.guestToken == live.guestToken, try await readerCount() == 1 else {
                throw SetbeamError.runtime("Returning to the verified route did not restore one reader with the same Hold and viewing link.")
            }
            try await runtime.setHold(false)
            _ = try await waitFor { $0.sourceAvailable && $0.audienceAvailable && !$0.session.holding }
            await runtime.stopSharing()
            let stopped = try await waitFor { $0.sourceAvailable && !$0.session.sharing }
            guard stopped.session.monitoring, try await readerCount() == 1 else { throw SetbeamError.runtime("Stop Sharing interrupted the Pyro H local input.") }
            let pids = await runtime.processIDs()
            await runtime.shutdown()
            guard pids.allSatisfy({ kill(-$0, 0) != 0 && errno == ESRCH }) else {
                throw SetbeamError.runtime("Pyro H runtime left owned groups behind: \(pids).")
            }
            print("PASS: Pyro H shutdown emptied owned media process groups \(pids)")
            print("PASS: scoped Pyro H media, silent Hold, source-loss and Wi-Fi-route recovery preserving Hold and link, Resume/Stop, and one upstream reader")

            try await waitForNoReader()
            let store = ProvenSetupStore(defaults: defaults)
            try store.confirm(source.setup)
            guard let saved = store.setup, saved.pyroHRoute == source.route else {
                throw SetbeamError.runtime("The proven setup did not retain the discovered Pyro H route.")
            }
            let restoredSource = try saved.source(address: source.address)
            routes.withLock { $0 = [changed] }
            do {
                _ = try await runtime.prepare(source: restoredSource, viewerAddress: "127.0.0.1")
                throw SetbeamError.runtime("The saved setup opened on a different Pyro H route.")
            } catch SetbeamError.unavailable(let message) where message == PyroHRoute.verifyWiFi {}
            let inactive = await runtime.snapshot()
            guard !inactive.session.monitoring, try await readerCount() == 0 else {
                throw SetbeamError.runtime("Rejected restore left a Pyro H upstream reader or an active monitor.")
            }
            routes.withLock { $0 = [network] }
            _ = try await runtime.prepare(source: restoredSource, viewerAddress: "127.0.0.1")
            let privateRestore = try await waitFor { $0.sourceAvailable && $0.sourceHasAudio }
            guard !privateRestore.session.sharing, try await readerCount() == 1 else {
                throw SetbeamError.runtime("The Pyro H saved setup did not restore privately with one reader.")
            }
            let privatePIDs = await runtime.processIDs()
            await runtime.shutdown()
            guard privatePIDs.allSatisfy({ kill(-$0, 0) != 0 && errno == ESRCH }) else {
                throw SetbeamError.runtime("Pyro H private restore left owned groups behind.")
            }
            print("PASS: saved Pyro H refuses an unverified route, restores privately on the original route, and cleans up owned processes")
        } catch { await runtime.shutdown(); throw error }
    }
}
