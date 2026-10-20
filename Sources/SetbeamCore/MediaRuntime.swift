import Foundation
import Darwin

public struct RuntimePaths: Sendable {
    public let tools: URL
    public let fixtures: URL
    public init(tools: URL, fixtures: URL) { self.tools = tools; self.fixtures = fixtures }
}

public struct RuntimeSnapshot: Sendable {
    public let sourceAvailable: Bool
    public let lastFrameAt: Date?
    public let message: String?
    public let preview: PlaybackDescriptor
    public let audience: PlaybackDescriptor
    public let guestToken: String
}

/// Owns one received source, a private monitoring output, and an independent audience output.
public actor MediaRuntime {
    private let paths: RuntimePaths
    private var directory: URL?
    private var mediaServer: ManagedChild?
    private var sourcePublisher: ManagedChild?
    private var audiencePublisher: ManagedChild?
    private var source: CameraSource = .sample
    private var sourceArguments: [String] = []
    private var rtspPort: UInt16 = 0, apiPort: UInt16 = 0, webPort: UInt16 = 0, icePort: UInt16 = 0
    private var publisherPassword = MediaRuntime.secret(), previewPassword = MediaRuntime.secret(), adminPassword = MediaRuntime.secret()
    private var guestPassword = MediaRuntime.secret()
    private var viewerAddress = "127.0.0.1"
    private var sharing = false, holding = false
    private var nextSourceRetry = Date.distantPast, nextAudienceRetry = Date.distantPast
    private var sourceFailures = 0, audienceFailures = 0
    private var guestNetworks: [String] = ["127.0.0.1", "::1"]

    public init(paths: RuntimePaths) { self.paths = paths }
    private static func secret() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "") }

    public func prepare(source candidate: CameraSource, viewerAddress: String) async throws -> RuntimeSnapshot {
        await shutdown()
        source = try candidate.validated(); self.viewerAddress = viewerAddress
        for executable in ["mediamtx", "ffmpeg", "ffprobe"] {
            guard FileManager.default.isExecutableFile(atPath: paths.tools.appendingPathComponent(executable).path) else {
                throw SetbeamError.unavailable("The app's bundled \(executable) is missing. Rebuild or reinstall Setbeam.")
            }
        }
        let run = FileManager.default.temporaryDirectory.appendingPathComponent("Setbeam", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directory = run
        publisherPassword = MediaRuntime.secret(); previewPassword = MediaRuntime.secret(); adminPassword = MediaRuntime.secret(); guestPassword = MediaRuntime.secret()
        var ports = Set<UInt16>()
        func port() throws -> UInt16 {
            for _ in 0..<20 { let value = try NetworkAddress.freeTCPPort(); if ports.insert(value).inserted { return value } }
            throw SetbeamError.unavailable("Could not find free local media ports.")
        }
        rtspPort = try port(); apiPort = try port(); webPort = try port(); icePort = try port()
        guestNetworks = ["127.0.0.1", "::1", Self.networkRange(for: viewerAddress)]
        let configuration = run.appendingPathComponent("mediamtx.yml")
        try Self.json(configurationObject()).write(to: configuration, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
        do {
            mediaServer = try child("MediaMTX", "mediamtx", [configuration.path])
            for _ in 0..<40 {
                guard mediaServer?.isRunning == true else { throw SetbeamError.runtime("Media server could not start. \(mediaServer?.recentError ?? "")") }
                if (try? await api("/v3/config/global/get")) != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            _ = try await api("/v3/config/global/get")
            sourceArguments = makeSourceArguments()
            sourcePublisher = try child("Camera input", "ffmpeg", sourceArguments)
            sourceFailures = 0; audienceFailures = 0
            nextSourceRetry = .distantPast; nextAudienceRetry = .distantPast
            return await snapshot()
        } catch {
            await shutdown(); throw error
        }
    }

    private func configurationObject() -> [String: Any] {
        let permissions: [[String: String]] = [
            ["action": "publish", "path": "local"], ["action": "publish", "path": "live"],
            ["action": "read", "path": "source"], ["action": "read", "path": "local"], ["action": "read", "path": "live"]]
        var camera: [String: Any] = ["source": "publisher"]
        if case .network(let address) = source { camera = ["source": address, "rtspTransport": "tcp"] }
        return [
            "logLevel": "warn", "api": true, "apiAddress": "127.0.0.1:\(apiPort)",
            "rtsp": true, "rtspAddress": "127.0.0.1:\(rtspPort)", "rtspTransports": ["tcp"],
            "rtmp": false, "hls": false, "srt": false, "moq": false,
            "webrtc": true, "webrtcAddress": ":\(webPort)",
            "webrtcLocalUDPAddress": ":\(icePort)", "webrtcLocalTCPAddress": ":\(icePort)",
            "webrtcIPsFromInterfaces": false,
            "webrtcAdditionalHosts": Array(Set(["127.0.0.1", viewerAddress])),
            "webrtcAllowOrigins": ["*"],
            "authMethod": "internal", "authInternalUsers": users(publisherPermissions: permissions),
            "pathDefaults": ["source": "publisher", "overridePublisher": false],
            "paths": ["source": camera, "local": [:], "live": [:]]
        ]
    }

    private func users(publisherPermissions: [[String: String]]? = nil) -> [[String: Any]] {
        let permissions = publisherPermissions ?? [
            ["action": "publish", "path": "local"], ["action": "publish", "path": "live"],
            ["action": "read", "path": "source"], ["action": "read", "path": "local"], ["action": "read", "path": "live"]]
        return [
            ["user": "publisher", "pass": publisherPassword, "ips": ["127.0.0.1", "::1"], "permissions": permissions],
            ["user": "preview", "pass": previewPassword, "ips": ["127.0.0.1", "::1"], "permissions": [["action": "read", "path": "local"]]],
            ["user": "admin", "pass": adminPassword, "ips": ["127.0.0.1", "::1"], "permissions": [["action": "api"]]],
            ["user": "guest", "pass": guestPassword, "ips": guestNetworks, "permissions": [["action": "read", "path": "live"]]]
        ]
    }

    private static func networkRange(for address: String) -> String {
        // Restrict to the selected interface's actual subnet, rather than guessing a /24.
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return address + "/32" }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let raw = item.pointee.ifa_addr, raw.pointee.sa_family == UInt8(AF_INET), let mask = item.pointee.ifa_netmask else { continue }
            let value = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            guard value == inet_addr(address) else { continue }
            let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let network = UInt32(bigEndian: value) & bits
            let ip = [24, 16, 8, 0].map { String((network >> $0) & 255) }.joined(separator: ".")
            return "\(ip)/\(bits.nonzeroBitCount)"
        }
        return address + "/32"
    }

    private func makeSourceArguments() -> [String] {
        var args = commonFFmpegArguments
        switch source {
        case .sample:
            args += ["-re", "-stream_loop", "-1", "-i", paths.fixtures.appendingPathComponent("Demo.mp4").path]
        case .network:
            args += ["-analyzeduration", "500000", "-probesize", "1000000", "-rtsp_transport", "tcp", "-i", publisherURL("source")]
        case .capture(let video, let audio):
            args += ["-f", "avfoundation", "-framerate", "30", "-i", "\(video):\(audio.map(String.init) ?? "none")"]
        }
        args += ["-map", "0:v:0", "-map", "0:a:0?"]
        if case .capture = source {
            args += ["-vf", "scale=1280:-2,format=yuv420p", "-c:v", "h264_videotoolbox", "-b:v", "2000k", "-bf", "0", "-g", "30", "-profile:v", "baseline"]
        } else { args += ["-c:v", "copy"] }
        args += ["-c:a", "libopus", "-b:a", "96k", "-ar", "48000", "-ac", "2"]
        return args + publishArguments("local")
    }

    private var commonFFmpegArguments: [String] {
        ["-nostdin", "-hide_banner", "-loglevel", "warning", "-progress", "pipe:1", "-stats_period", "1"]
    }
    private func publisherURL(_ path: String) -> String { "rtsp://publisher:\(publisherPassword)@127.0.0.1:\(rtspPort)/\(path)" }
    private func publishArguments(_ path: String) -> [String] { ["-f", "rtsp", "-rtsp_transport", "tcp", publisherURL(path)] }
    private func child(_ name: String, _ executable: String, _ arguments: [String]) throws -> ManagedChild {
        guard let directory else { throw SetbeamError.runtime("Media session has not been prepared.") }
        return try ManagedChild(name: name, executable: paths.tools.appendingPathComponent(executable), arguments: arguments, directory: directory)
    }

    public func startSharing() async throws -> RuntimeSnapshot {
        guard mediaServer?.isRunning == true else { throw SetbeamError.unavailable("Connect a camera before sharing.") }
        guestPassword = MediaRuntime.secret()
        _ = try await api("/v3/config/global/patch", method: "PATCH", object: ["authInternalUsers": users()])
        sharing = true; holding = false; audienceFailures = 0
        try launchAudience()
        return await snapshot()
    }
    public func setHold(_ enabled: Bool) async throws {
        guard sharing else { throw SetbeamError.unavailable("Start sharing before holding the audience.") }
        audiencePublisher?.stop(); audiencePublisher = nil
        holding = enabled; audienceFailures = 0
        try launchAudience()
    }
    private func launchAudience() throws {
        var args = commonFFmpegArguments
        if holding {
            args += ["-re", "-stream_loop", "-1", "-i", paths.fixtures.appendingPathComponent("Hold.mp4").path,
                     "-c:v", "copy", "-c:a", "libopus", "-b:a", "64k", "-ar", "48000", "-ac", "2"]
        } else { args += ["-analyzeduration", "500000", "-probesize", "1000000", "-rtsp_transport", "tcp", "-i", publisherURL("local"), "-c", "copy"] }
        audiencePublisher = try child(holding ? "Audience holding output" : "Audience relay", "ffmpeg", args + publishArguments("live"))
    }
    public func stopSharing() async {
        sharing = false; holding = false
        audiencePublisher?.stop(); audiencePublisher = nil
        guestPassword = MediaRuntime.secret()
        _ = try? await api("/v3/config/global/patch", method: "PATCH", object: ["authInternalUsers": users()])
    }

    public func snapshot() async -> RuntimeSnapshot {
        var problem: String?
        if mediaServer?.isRunning != true { problem = "The media server stopped. Reconnect the source." }
        if mediaServer?.isRunning == true, sourcePublisher?.isRunning != true, Date() >= nextSourceRetry {
            problem = sourcePublisher?.recentError
            sourceFailures += 1; nextSourceRetry = Date().addingTimeInterval(min(10, pow(1.6, Double(sourceFailures))))
            sourcePublisher = try? child("Camera input", "ffmpeg", sourceArguments)
        }
        if sharing, mediaServer?.isRunning == true, audiencePublisher?.isRunning != true, Date() >= nextAudienceRetry {
            audienceFailures += 1; nextAudienceRetry = Date().addingTimeInterval(min(10, pow(1.6, Double(audienceFailures))))
            try? launchAudience()
        }
        let lastFrame = sourcePublisher?.lastVideoFrameAt
        let localReady = (try? await api("/v3/paths/get/local"))?["available"] as? Bool ?? false
        let frameFresh = lastFrame.map { Date().timeIntervalSince($0) < 6 } ?? false
        let available = localReady && frameFresh
        if available { sourceFailures = 0 }
        return RuntimeSnapshot(sourceAvailable: available, lastFrameAt: lastFrame, message: problem.map(Redaction.text),
            preview: PlaybackDescriptor(origin: "http://127.0.0.1:\(webPort)", path: "local", user: "preview", password: previewPassword),
            audience: PlaybackDescriptor(origin: "http://\(viewerAddress):\(webPort)", path: "live", user: "guest", password: guestPassword), guestToken: guestPassword)
    }

    public func saveFrame(to destination: URL) async throws {
        let frame = try child("Save frame", "ffmpeg", ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-rtsp_transport", "tcp", "-i", publisherURL("local"), "-map", "0:v:0", "-frames:v", "1", "-q:v", "2", destination.path])
        let deadline = Date().addingTimeInterval(8)
        while frame.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        if frame.isRunning { frame.stop(); throw SetbeamError.runtime("The camera did not provide a frame in time.") }
        guard frame.terminationStatus == 0, ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? Int ?? 0) > 0 else { throw SetbeamError.runtime("Could not save a frame. \(frame.recentError)") }
    }

    public func captureDeviceListing() async throws -> String {
        let run = FileManager.default.temporaryDirectory.appendingPathComponent("Setbeam-devices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: run) }
        let listing = try ManagedChild(name: "Capture device listing", executable: paths.tools.appendingPathComponent("ffmpeg"), arguments: ["-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""], directory: run)
        let deadline = Date().addingTimeInterval(5)
        while listing.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        listing.stop(); return listing.recentError
    }

    public func diagnosticStatus() async -> [String: Any] {
        let value = await snapshot()
        return ["source": source.label, "sourceAvailable": value.sourceAvailable, "sharing": sharing, "holding": holding,
                "processes": ["server": mediaServer?.isRunning ?? false, "source": sourcePublisher?.isRunning ?? false, "audience": audiencePublisher?.isRunning ?? false],
                "lastError": Redaction.text(value.message ?? sourcePublisher?.recentError ?? "")]
    }

    /// Used by the integration probe; never exposed to the public web viewer.
    public func localRTSP(_ path: String = "local") -> String { publisherURL(path) }
    public func controlOrigin() -> String { "http://127.0.0.1:\(apiPort)" }
    public func processIDs() -> [Int32] { [mediaServer, sourcePublisher, audiencePublisher].compactMap { $0?.processID }.filter { $0 > 0 } }

    public func shutdown() async {
        sharing = false; holding = false
        audiencePublisher?.stop(); audiencePublisher = nil
        sourcePublisher?.stop(); sourcePublisher = nil
        mediaServer?.stop(); mediaServer = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func api(_ path: String, method: String = "GET", object: [String: Any]? = nil) async throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(apiPort)\(path)")!
        var request = URLRequest(url: url, timeoutInterval: 2); request.httpMethod = method
        request.setValue("Basic " + Data("admin:\(adminPassword)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let object { request.httpBody = try JSONSerialization.data(withJSONObject: object); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw SetbeamError.runtime("The local media controller did not accept the request.") }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    private static func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) }
}
