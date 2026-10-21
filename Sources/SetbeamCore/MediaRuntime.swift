import Foundation
import Darwin

public struct RuntimePaths: Sendable {
    public let tools: URL
    public let fixtures: URL
    public init(tools: URL, fixtures: URL) { self.tools = tools; self.fixtures = fixtures }
}

public struct RuntimeSnapshot: Sendable {
    public let sourceAvailable: Bool
    public let connectionStage: ConnectionStage
    public let audienceAvailable: Bool
    public let audienceRevision: Int
    public let lastFrameAt: Date?
    public let message: String?
    public let preview: PlaybackDescriptor
    public let audience: PlaybackDescriptor
    public let guestToken: String
    public let sourceHasAudio: Bool
    public let audienceHasAudio: Bool
}

/// Owns one received source, a private monitoring output, and an independent audience output.
public actor MediaRuntime {
    private let paths: RuntimePaths
    private var directory: URL?
    private var mediaServer: ManagedChild?
    private var sourcePublisher: ManagedChild?
    private var audiencePublisher: ManagedChild?
    private var source: VideoSource = .sample
    private var sourceArguments: [String] = []
    private var rtspPort: UInt16 = 0, apiPort: UInt16 = 0, webPort: UInt16 = 0, icePort: UInt16 = 0
    private var publisherPassword = MediaRuntime.secret(), previewPassword = MediaRuntime.secret(), adminPassword = MediaRuntime.secret()
    private var guestPassword = MediaRuntime.secret()
    private var viewerAddress = "127.0.0.1"
    private var inputAddress = "127.0.0.1"
    private var sharing = false, holding = false
    private var nextSourceRetry = Date.distantPast, nextAudienceRetry = Date.distantPast
    private var sourceFailures = 0, audienceFailures = 0
    private var guestNetworks: [String] = ["127.0.0.1", "::1"]
    private var sourceStartedAt = Date.distantPast, audienceStartedAt = Date.distantPast
    private var nextServerRetry = Date.distantPast
    private var serverFailures = 0, audienceRevision = 0
    private var replacingSource = false
    private let accsoonDiscovery = AccsoonDiscovery()
    private let accsoonReceiver = AccsoonReceiver()
    private var accsoonVideoPort: UInt16 = 0, accsoonAudioPort: UInt16?

    public init(paths: RuntimePaths) {
        self.paths = paths
        let discovery = accsoonDiscovery
        accsoonReceiver.onAnnouncement = { data, host in discovery.observe(data, host: host) }
    }
    public func discoverWireless() throws -> [AccsoonDevice] {
        if !accsoonReceiver.isRunning { try accsoonDiscovery.start() }
        return accsoonDiscovery.devices
    }
    public func stopWirelessDiscovery() { if !accsoonReceiver.isRunning { accsoonDiscovery.stop() } }
    private static func secret() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "") }

    public func prepare(source candidate: VideoSource, viewerAddress: String, inputAddress: String? = nil) async throws -> RuntimeSnapshot {
        await shutdown()
        source = try candidate.validated(); self.viewerAddress = viewerAddress
        self.inputAddress = inputAddress ?? viewerAddress
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
            try await launchServer()
            // A remembered capture device may be unplugged. Keep the session waiting for it.
            try? launchSource()
            sourceFailures = 0; audienceFailures = 0
            serverFailures = 0; nextServerRetry = .distantPast
            nextSourceRetry = Date().addingTimeInterval(2); nextAudienceRetry = .distantPast
            return await snapshot()
        } catch {
            await shutdown(); throw error
        }
    }

    private func configurationObject() -> [String: Any] {
        let permissions: [[String: String]] = [
            ["action": "publish", "path": "local"], ["action": "publish", "path": "live"],
            ["action": "read", "path": "source"], ["action": "read", "path": "local"], ["action": "read", "path": "live"]]
        var upstream: [String: Any] = ["source": "publisher"]
        if case .network(let address) = source { upstream = ["source": address, "rtspTransport": "tcp"] }
        var configuration: [String: Any] = [
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
            "paths": ["source": upstream, "local": [:], "live": [:]]
        ]
        if case .incoming(let port, _) = source { configuration["rtmp"] = true; configuration["rtmpAddress"] = "\(inputAddress):\(port)" }
        return configuration
    }

    private func users(publisherPermissions: [[String: String]]? = nil) -> [[String: Any]] {
        let permissions = publisherPermissions ?? [
            ["action": "publish", "path": "local"], ["action": "publish", "path": "live"],
            ["action": "read", "path": "source"], ["action": "read", "path": "local"], ["action": "read", "path": "live"]]
        var result: [[String: Any]] = [
            ["user": "publisher", "pass": publisherPassword, "ips": ["127.0.0.1", "::1"], "permissions": permissions],
            ["user": "preview", "pass": previewPassword, "ips": ["127.0.0.1", "::1"], "permissions": [["action": "read", "path": "local"]]],
            ["user": "admin", "pass": adminPassword, "ips": ["127.0.0.1", "::1"], "permissions": [["action": "api"]]],
            ["user": "guest", "pass": guestPassword, "ips": guestNetworks, "permissions": [["action": "read", "path": "live"]]]
        ]
        if case .incoming(_, let key) = source {
            result.append(["user": "sender", "pass": key, "ips": ["127.0.0.1", "::1", Self.networkRange(for: inputAddress)], "permissions": [["action": "publish", "path": "source"]]])
        }
        return result
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

    private func makeSourceArguments() throws -> [String] {
        var args = commonFFmpegArguments
        switch source {
        case .sample:
            args += ["-re", "-stream_loop", "-1", "-i", paths.fixtures.appendingPathComponent("Demo.mp4").path]
        case .network, .incoming:
            args += ["-analyzeduration", "500000", "-probesize", "1000000", "-rtsp_transport", "tcp", "-i", publisherURL("source")]
        case .capture(let video, let audio):
            args += ["-f", "avfoundation", "-framerate", "30", "-i", "\(video):\(audio.map(String.init) ?? "none")"]
        case .captureDevice(let videoID, let audioID):
            let devices = CaptureDiscovery.devices()
            _ = try CaptureHardware.resolve(videoID, audio: false, in: devices)
            if let audioID { _ = try CaptureHardware.resolve(audioID, audio: true, in: devices) }
            args += ["-f", "avfoundation", "-framerate", "30", "-video_device_unique_id", videoID]
            if let audioID { args += ["-audio_device_unique_id", audioID] }
            args += ["-i", "none:none"]
        case .accsoon(let uid):
            try accsoonDiscovery.start()
            guard let device = accsoonDiscovery.device(uid), device.recognized, let directory else {
                throw SetbeamError.unavailable("Join your saved transmitter's Wi-Fi and turn it on. Setbeam will reconnect to that same unit.")
            }
            guard device.videoAvailable else { throw SetbeamError.unavailable("Connect a live computer or camera output to the transmitter's HDMI or SDI input.") }
            accsoonVideoPort = try NetworkAddress.freeRTPPorts()
            accsoonAudioPort = device.audioAvailable ? try NetworkAddress.freeRTPPorts() : nil
            var sdp = "v=0\no=- 0 0 IN IP4 127.0.0.1\ns=Setbeam private input\nc=IN IP4 127.0.0.1\nt=0 0\nm=video \(accsoonVideoPort) RTP/AVP 96\na=rtpmap:96 H265/90000\na=recvonly\n"
            if let audio = accsoonAudioPort {
                sdp += "m=audio \(audio) RTP/AVP 97\na=rtpmap:97 MPEG4-GENERIC/48000/2\na=fmtp:97 streamtype=5; profile-level-id=1; mode=AAC-hbr; config=1190; SizeLength=13; IndexLength=3; IndexDeltaLength=3\na=recvonly\n"
            }
            let file = directory.appendingPathComponent("accsoon.sdp")
            try sdp.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            args += ["-protocol_whitelist", "file,udp,rtp", "-analyzeduration", "1000000", "-probesize", "2000000", "-i", file.path]
        }
        args += ["-map", "0:v:0", "-map", "0:a:0?"]
        if source.isCapture || isAccsoonSource {
            args += ["-vf", isAccsoonSource ? "scale=w='min(1920,iw)':h=-2,format=yuv420p" : "scale=1280:-2,format=yuv420p", "-c:v", "h264_videotoolbox", "-b:v", isAccsoonSource ? "6000k" : "2000k", "-bf", "0", "-g", "30", "-profile:v", "baseline"]
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

    private func launchServer() async throws {
        guard let directory else { throw SetbeamError.unavailable("Connect a source first.") }
        let configuration = directory.appendingPathComponent("mediamtx.yml")
        try Self.json(configurationObject()).write(to: configuration, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
        mediaServer = try child("MediaMTX", "mediamtx", [configuration.path])
        for _ in 0..<40 {
            guard mediaServer?.isRunning == true else { throw SetbeamError.runtime("The video service could not start.") }
            if (try? await api("/v3/config/global/get")) != nil { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SetbeamError.runtime("The video service did not respond.")
    }
    private func launchSource() throws {
        accsoonReceiver.stop()
        sourceArguments = try makeSourceArguments()
        sourcePublisher = try child("Source input", "ffmpeg", sourceArguments)
        sourceStartedAt = Date()
        if case .accsoon(let uid) = source, let device = accsoonDiscovery.device(uid) {
            accsoonDiscovery.stop()
            do { try accsoonReceiver.start(host: device.host, deviceUID: uid, videoPort: accsoonVideoPort, audioPort: accsoonAudioPort) }
            catch { sourcePublisher?.stop(); sourcePublisher = nil; try? accsoonDiscovery.start(); throw error }
        }
    }
    private var isAccsoonSource: Bool { if case .accsoon = source { return true }; return false }

    public func updateViewerAddress(_ address: String) async throws {
        viewerAddress = address
        guestNetworks = ["127.0.0.1", "::1", Self.networkRange(for: address)]
        if mediaServer?.isRunning == true {
            let changes: [String: Any] = ["webrtcAdditionalHosts": Array(Set(["127.0.0.1", address])), "authInternalUsers": users()]
            _ = try await api("/v3/config/global/patch", method: "PATCH", object: changes)
            audienceRevision += 1
        }
    }
    public func updateInputAddress(_ address: String) async throws {
        guard address != inputAddress, case .incoming(let port, _) = source else { return }
        inputAddress = address
        if mediaServer?.isRunning == true {
            _ = try await api("/v3/config/global/patch", method: "PATCH", object: ["rtmpAddress": "\(address):\(port)", "authInternalUsers": users()])
        }
    }
    public func retrySource() {
        accsoonReceiver.stop()
        sourcePublisher?.stop(); sourcePublisher = nil; nextSourceRetry = .distantPast
    }
    /// Private setup destination, never exposed by ViewerGateway.
    public func incomingDestination() -> (server: String, streamKey: String)? {
        guard case .incoming(let port, let key) = source else { return nil }
        return ("rtmp://\(inputAddress):\(port)", "source?user=sender&pass=\(key)")
    }

    public func startSharing() async throws -> RuntimeSnapshot {
        guard mediaServer?.isRunning == true else { throw SetbeamError.unavailable("Connect a source before sharing.") }
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
    /// Keep the audience credential, ports, and Hold while replacing the one received input.
    /// A failed or absent replacement never resumes audience media automatically.
    public func replaceSource(_ candidate: VideoSource, inputAddress: String? = nil) async throws -> RuntimeSnapshot {
        let validated = try candidate.validated()
        guard directory != nil, !replacingSource else { throw SetbeamError.unavailable("Connect a source before changing inputs.") }
        replacingSource = true
        defer { replacingSource = false }
        if sharing { holding = true }
        audiencePublisher?.stop(); audiencePublisher = nil
        accsoonReceiver.stop(); accsoonDiscovery.stop()
        sourcePublisher?.stop(); sourcePublisher = nil
        mediaServer?.stop(); mediaServer = nil
        source = validated
        if let inputAddress { self.inputAddress = inputAddress }
        sourceFailures = 0; audienceFailures = 0; serverFailures = 0
        nextServerRetry = .distantPast; nextSourceRetry = Date().addingTimeInterval(2); nextAudienceRetry = .distantPast
        try await launchServer()
        // Hold is independent of the new input and remains available even when it has no picture.
        if sharing { try launchAudience() }
        try? launchSource()
        return await snapshot()
    }
    private func launchAudience() throws {
        var args = commonFFmpegArguments
        if holding {
            args += ["-re", "-stream_loop", "-1", "-i", paths.fixtures.appendingPathComponent("Hold.mp4").path,
                     "-c:v", "copy", "-c:a", "libopus", "-b:a", "64k", "-ar", "48000", "-ac", "2"]
        } else { args += ["-analyzeduration", "500000", "-probesize", "1000000", "-rtsp_transport", "tcp", "-i", publisherURL("local"), "-c", "copy"] }
        audiencePublisher = try child(holding ? "Audience holding output" : "Audience relay", "ffmpeg", args + publishArguments("live"))
        audienceStartedAt = Date(); audienceRevision += 1
    }
    public func stopSharing() async {
        sharing = false; holding = false
        audiencePublisher?.stop(); audiencePublisher = nil
        guestPassword = MediaRuntime.secret()
        _ = try? await api("/v3/config/global/patch", method: "PATCH", object: ["authInternalUsers": users()])
    }

    public func snapshot() async -> RuntimeSnapshot {
        var problem: String?
        if !replacingSource, directory != nil, mediaServer?.isRunning != true {
            problem = "The video service is restarting. Your selected source has not changed."
            if Date() >= nextServerRetry {
                serverFailures += 1; nextServerRetry = Date().addingTimeInterval(min(10, pow(1.6, Double(serverFailures))))
                sourcePublisher?.stop(); sourcePublisher = nil; audiencePublisher?.stop(); audiencePublisher = nil; mediaServer?.stop()
                do { try await launchServer(); try? launchSource(); if sharing { try? launchAudience() } }
                catch { problem = "The video service is retrying. Your preview will return here." }
            }
        }
        let sourceStalled = Date().timeIntervalSince(sourcePublisher?.lastVideoFrameAt ?? sourceStartedAt) > 12
        let receiverFailed = isAccsoonSource && sourcePublisher != nil && !accsoonReceiver.isRunning
        if !replacingSource, mediaServer?.isRunning == true, (sourcePublisher?.isRunning != true || sourceStalled || receiverFailed), Date() >= nextSourceRetry {
            problem = isAccsoonSource ? accsoonReceiver.lastError ?? sourcePublisher?.recentError : sourcePublisher?.recentError
            sourceFailures += 1; nextSourceRetry = Date().addingTimeInterval(min(10, pow(1.6, Double(sourceFailures))))
            sourcePublisher?.stop(); sourcePublisher = nil
            do { try launchSource() } catch { problem = error.localizedDescription }
        }
        let audienceStalled = Date().timeIntervalSince(audiencePublisher?.lastVideoFrameAt ?? audienceStartedAt) > 12
        if !replacingSource, sharing, mediaServer?.isRunning == true, (audiencePublisher?.isRunning != true || audienceStalled), Date() >= nextAudienceRetry {
            audienceFailures += 1; nextAudienceRetry = Date().addingTimeInterval(min(10, pow(1.6, Double(audienceFailures))))
            audiencePublisher?.stop(); audiencePublisher = nil
            try? launchAudience()
        }
        let lastFrame = sourcePublisher?.lastVideoFrameAt
        let localPath = try? await api("/v3/paths/get/local")
        let localReady = localPath?["available"] as? Bool ?? false
        let frameFresh = lastFrame.map { Date().timeIntervalSince($0) < 6 } ?? false
        let available = localReady && frameFresh && (!isAccsoonSource || accsoonReceiver.isRunning)
        if available { sourceFailures = 0; serverFailures = 0; problem = nil }
        var audiencePath: [String: Any]?
        if sharing { audiencePath = try? await api("/v3/paths/get/live") }
        let audienceReady = audiencePath?["available"] as? Bool ?? false
        let audienceFresh = audiencePublisher?.lastVideoFrameAt.map { Date().timeIntervalSince($0) < 6 } ?? false
        let transmitterFound: Bool
        if case .accsoon(let uid) = source { transmitterFound = accsoonDiscovery.device(uid)?.recognized == true }
        else { transmitterFound = false }
        let stage = ConnectionStage.resolve(serverReady: mediaServer?.isRunning == true, sourceFresh: available,
            isTransmitter: isAccsoonSource, transmitterFound: transmitterFound, receiverRunning: accsoonReceiver.isRunning,
            connectionAcknowledged: (accsoonReceiver.statistics["connectionAcknowledgements"] ?? 0) > 0)
        return RuntimeSnapshot(sourceAvailable: available, connectionStage: stage, audienceAvailable: audienceReady && audienceFresh, audienceRevision: audienceRevision,
            lastFrameAt: lastFrame, message: problem.map(Redaction.text),
            preview: PlaybackDescriptor(origin: "http://127.0.0.1:\(webPort)", path: "local", user: "preview", password: previewPassword),
            audience: PlaybackDescriptor(origin: "http://\(viewerAddress):\(webPort)", path: "live", user: "guest", password: guestPassword), guestToken: guestPassword,
            sourceHasAudio: available && MediaTracks.hasAudio(localPath?["tracks"] as? [String] ?? []),
            audienceHasAudio: audienceReady && audienceFresh && MediaTracks.hasAudio(audiencePath?["tracks"] as? [String] ?? []))
    }

    public func saveFrame(to destination: URL) async throws {
        let frame = try child("Save frame", "ffmpeg", ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-rtsp_transport", "tcp", "-i", publisherURL("local"), "-map", "0:v:0", "-frames:v", "1", "-pix_fmt", "yuvj420p", "-q:v", "2", destination.path])
        let deadline = Date().addingTimeInterval(8)
        while frame.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        if frame.isRunning { frame.stop(); throw SetbeamError.runtime("The source did not provide a frame in time.") }
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
        return ["source": source.label, "sourceAvailable": value.sourceAvailable, "connectionStage": value.connectionStage.rawValue, "sharing": sharing, "holding": holding,
                "processes": ["server": mediaServer?.isRunning ?? false, "source": sourcePublisher?.isRunning ?? false, "audience": audiencePublisher?.isRunning ?? false],
                "lastError": Redaction.text(value.message ?? sourcePublisher?.recentError ?? ""), "wirelessError": accsoonReceiver.lastError ?? "", "wirelessStatistics": accsoonReceiver.statistics]
    }

    /// Used by the integration probe; never exposed to the public web viewer.
    public func localRTSP(_ path: String = "local") -> String { publisherURL(path) }
    public func controlOrigin() -> String { "http://127.0.0.1:\(apiPort)" }
    public func processIDs() -> [Int32] { [mediaServer, sourcePublisher, audiencePublisher].compactMap { $0?.processID }.filter { $0 > 0 } }

    public func shutdown() async {
        sharing = false; holding = false
        accsoonReceiver.stop(); accsoonDiscovery.stop()
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
