import Foundation
import Darwin

public struct RuntimePaths: Sendable {
    public let tools: URL
    public let fixtures: URL
    public init(tools: URL, fixtures: URL) { self.tools = tools; self.fixtures = fixtures }
}

public struct RuntimeSnapshot: Sendable {
    public let session: SessionState
    public let source: VideoSource
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

enum SourceConfigurationStep: Sendable { case credentials, path }

/// Owns one received source, a private monitoring output, and an independent audience output.
public actor MediaRuntime {
    private let paths: RuntimePaths
    private var directory: URL?
    private var mediaServer: ManagedChild?
    private var sourcePublisher: ManagedChild?
    private var audiencePublisher: ManagedChild?
    private var source: VideoSource = .sample
    private var sourceNeedsConfiguration = false
    private let beforeSourceConfigurationStep: @Sendable (SourceConfigurationStep) throws -> Void
    private var sourceArguments: [String] = []
    private var rtspPort: UInt16 = 0, apiPort: UInt16 = 0, webPort: UInt16 = 0, icePort: UInt16 = 0, rtmpPort: UInt16 = 0
    private let incomingRelay = IncomingStreamRelay()
    private var publisherPassword = MediaRuntime.secret(), previewPassword = MediaRuntime.secret(), adminPassword = MediaRuntime.secret()
    private var guestPassword = MediaRuntime.secret()
    private var viewerAddress = "127.0.0.1"
    private var inputAddress = "127.0.0.1"
    private var sessionState = SessionState()
    private var sharing: Bool { sessionState.sharing }
    private var holding: Bool { sessionState.holding }
    private var healthTask: Task<Void, Never>?
    private var lifetime = UUID()
    private var operationActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [UUID: AsyncStream<RuntimeSnapshot>.Continuation] = [:]
    private var observedFrameAt: Date?
    private var observedStage: ConnectionStage = .preparingMonitor
    private var observedSourceAudio = false, observedAudienceAudio = false
    private var observedProblem: String?
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
        beforeSourceConfigurationStep = { _ in }
        let discovery = accsoonDiscovery
        accsoonReceiver.onAnnouncement = { data, host in discovery.observe(data, host: host) }
    }
    /// Allows actual-media tests to exercise failures between controller requests.
    init(paths: RuntimePaths, beforeSourceConfigurationStep: @escaping @Sendable (SourceConfigurationStep) throws -> Void) {
        self.paths = paths
        self.beforeSourceConfigurationStep = beforeSourceConfigurationStep
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
        let validated = try candidate.validated()
        await acquireOperation()
        defer { releaseOperation() }
        shutdownLocked()
        var prepared = false
        defer { if !prepared { shutdownLocked() } }
        source = validated; self.viewerAddress = viewerAddress
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
        if case .incoming(let inputPort, _) = source { ports.insert(inputPort) }
        func port() throws -> UInt16 {
            for _ in 0..<20 { let value = try NetworkAddress.freeTCPPort(); if ports.insert(value).inserted { return value } }
            throw SetbeamError.unavailable("Could not find free local media ports.")
        }
        rtspPort = try port(); apiPort = try port(); webPort = try port(); icePort = try port(); rtmpPort = try port()
        guestNetworks = ["127.0.0.1", "::1", Self.networkRange(for: viewerAddress)]
        let configuration = run.appendingPathComponent("mediamtx.yml")
        try Self.json(configurationObject()).write(to: configuration, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
        do {
            try await launchServer()
            sessionState.beginMonitoring()
            if case .incoming(let port, _) = source {
                try? await incomingRelay.start(address: self.inputAddress, port: port, targetPort: rtmpPort, keepTrying: true)
            }
            // A remembered capture device may be unplugged. Keep the session waiting for it.
            try? launchSource()
            sourceFailures = 0; audienceFailures = 0
            serverFailures = 0; nextServerRetry = .distantPast
            nextSourceRetry = Date().addingTimeInterval(2); nextAudienceRetry = .distantPast
            let initial = await refreshSnapshot()
            startHealthLoop()
            prepared = true
            return initial
        } catch {
            shutdownLocked(); throw error
        }
    }

    private func configurationObject() -> [String: Any] {
        let permissions: [[String: String]] = [
            ["action": "publish", "path": "local"], ["action": "publish", "path": "live"],
            ["action": "read", "path": "source"], ["action": "read", "path": "local"], ["action": "read", "path": "live"]]
        let configuration: [String: Any] = [
            "logLevel": "warn", "api": true, "apiAddress": "127.0.0.1:\(apiPort)",
            "rtsp": true, "rtspAddress": "127.0.0.1:\(rtspPort)", "rtspTransports": ["tcp"],
            "rtmp": true, "rtmpAddress": "127.0.0.1:\(rtmpPort)", "hls": false, "srt": false, "moq": false,
            "webrtc": true, "webrtcAddress": ":\(webPort)",
            "webrtcLocalUDPAddress": ":\(icePort)", "webrtcLocalTCPAddress": ":\(icePort)",
            "webrtcIPsFromInterfaces": false,
            "webrtcAdditionalHosts": Array(Set(["127.0.0.1", viewerAddress])),
            "webrtcAllowOrigins": ["*"],
            "authMethod": "internal", "authInternalUsers": users(publisherPermissions: permissions),
            "pathDefaults": ["source": "publisher", "overridePublisher": false],
            "paths": ["source": sourceConfiguration(), "local": [:], "live": [:]]
        ]
        return configuration
    }

    private func sourceConfiguration() -> [String: Any] {
        if case .network(let address) = source { return ["source": address, "rtspTransport": "tcp"] }
        return ["source": "publisher"]
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
            result.append(["user": "sender", "pass": key, "ips": ["127.0.0.1", "::1"], "permissions": [["action": "publish", "path": "source"]]])
        }
        return result
    }

    private static func networkRange(for address: String) -> String { NetworkAddress.subnet(for: address) }

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
        if case .sample = source { args += ["-c:v", "copy"] }
        else { args += MediaOutputContract.videoArguments }
        args += MediaOutputContract.audioArguments
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
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            guard mediaServer?.isRunning == true else { throw SetbeamError.runtime("The video service could not start.") }
            if (try? await api("/v3/config/global/get")) != nil { sourceNeedsConfiguration = false; return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SetbeamError.runtime("The video service did not respond.")
    }
    private func launchSource() throws {
        guard !sourceNeedsConfiguration else {
            throw SetbeamError.unavailable("The selected input is waiting for its private media configuration.")
        }
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
        await acquireOperation()
        defer { releaseOperation() }
        viewerAddress = address
        guestNetworks = ["127.0.0.1", "::1", Self.networkRange(for: address)]
        if mediaServer?.isRunning == true {
            let changes: [String: Any] = ["webrtcAdditionalHosts": Array(Set(["127.0.0.1", address])), "authInternalUsers": users()]
            _ = try await api("/v3/config/global/patch", method: "PATCH", object: changes)
            audienceRevision += 1
        }
        publishSnapshot()
    }
    public func updateInputAddress(_ address: String) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard address != inputAddress, case .incoming(let port, _) = source else { return }
        try await incomingRelay.start(address: address, port: port, targetPort: rtmpPort)
        inputAddress = address
    }
    public func retrySource() async {
        await acquireOperation()
        defer { releaseOperation() }
        accsoonReceiver.stop()
        sourcePublisher?.stop(); sourcePublisher = nil; nextSourceRetry = .distantPast
        sessionState.updateSource(available: false); observedSourceAudio = false
        publishSnapshot()
    }
    /// Private setup destination, never exposed by ViewerGateway.
    public func incomingDestination() -> (server: String, streamKey: String)? {
        guard case .incoming(let port, let key) = source else { return nil }
        return ("rtmp://\(inputAddress):\(port)", "source?user=sender&pass=\(key)")
    }

    public func startSharing() async throws -> RuntimeSnapshot {
        await acquireOperation()
        defer { releaseOperation() }
        guard mediaServer?.isRunning == true else { throw SetbeamError.unavailable("Connect a source before sharing.") }
        guard !sharing else { return snapshot() }
        guestPassword = MediaRuntime.secret()
        _ = try await api("/v3/config/global/patch", method: "PATCH", object: ["authInternalUsers": users()])
        try sessionState.startSharing(); sessionState.updateAudience(available: false); audienceFailures = 0
        publishSnapshot()
        try launchAudience()
        return await refreshSnapshot()
    }
    public func setHold(_ enabled: Bool) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try await setHoldLocked(enabled)
    }
    private func setHoldLocked(_ enabled: Bool) async throws {
        guard sharing else { throw SetbeamError.unavailable("Start sharing before holding the audience.") }
        try sessionState.setHold(enabled); sessionState.updateAudience(available: false)
        publishSnapshot()
        audiencePublisher?.stop(); audiencePublisher = nil
        audienceFailures = 0
        try launchAudience()
        _ = await refreshSnapshot()
    }
    /// Keep the audience credential, ports, and Hold while replacing the one received input.
    /// A failed or absent replacement never resumes audience media automatically.
    public func replaceSource(_ candidate: VideoSource, inputAddress: String? = nil) async throws -> RuntimeSnapshot {
        let validated = try candidate.validated()
        await acquireOperation()
        defer { releaseOperation() }
        guard directory != nil, !replacingSource else { throw SetbeamError.unavailable("Connect a source before changing inputs.") }
        replacingSource = true
        defer { replacingSource = false }
        // Establish a real holding output before touching the input. If it is already
        // running, leave that publisher and every connected audience reader alone.
        if sharing {
            if !holding { try await setHoldLocked(true) }
            else if audiencePublisher?.isRunning != true { try launchAudience() }
            try await waitForHoldingOutput()
        }
        // Bind a replacement incoming destination before disturbing the current
        // source. An occupied port must never terminate the audience media server.
        if case .incoming(let port, _) = validated {
            try await incomingRelay.start(address: inputAddress ?? self.inputAddress, port: port, targetPort: rtmpPort)
        } else { incomingRelay.stop() }
        accsoonReceiver.stop(); accsoonDiscovery.stop()
        sourcePublisher?.stop(); sourcePublisher = nil
        sessionState.updateSource(available: false)
        observedFrameAt = nil; observedSourceAudio = false
        sourceNeedsConfiguration = true
        source = validated
        if let inputAddress { self.inputAddress = inputAddress }
        sourceFailures = 0
        nextSourceRetry = Date().addingTimeInterval(2)
        publishSnapshot()
        try await applySourceConfiguration()
        try? launchSource()
        return await refreshSnapshot()
    }

    /// A failed or partly applied controller update never authorizes a source
    /// publisher to read the previous path under the newly selected identity.
    private func applySourceConfiguration() async throws {
        // MediaMTX reloads only this input path and its sender credentials.
        // Its RTSP/WebRTC servers, holding publisher, ports, and credentials survive.
        try beforeSourceConfigurationStep(.credentials)
        _ = try await api("/v3/config/global/patch", method: "PATCH", object: ["authInternalUsers": users()])
        try beforeSourceConfigurationStep(.path)
        _ = try await api("/v3/config/paths/replace/source", method: "POST", object: sourceConfiguration())
        // Mutating requests are serialized through MediaMTX's core loop, but a
        // config GET reads directly and can precede a just-acknowledged reload.
        // This no-op patch is a barrier for both preceding reloads.
        _ = try await api("/v3/config/global/patch", method: "PATCH", object: [:])
        let global = try await api("/v3/config/global/get")
        // The controller intentionally redacts password bytes. The successful
        // patch and sequenced read confirm application; read back every access
        // scope and permission instead of comparing the redacted placeholder.
        func networks(_ user: [String: Any]) -> Set<String> {
            Set((user["ips"] as? [String] ?? []).map { $0.contains("/") ? $0 : $0 + ($0.contains(":") ? "/128" : "/32") })
        }
        func permissions(_ user: [String: Any]) -> Set<String> {
            Set((user["permissions"] as? [[String: String]] ?? []).map { ($0["action"] ?? "") + ":" + ($0["path"] ?? "") })
        }
        guard let appliedUsers = global["authInternalUsers"] as? [[String: Any]],
              appliedUsers.count == users().count,
              users().allSatisfy({ expected in
                  appliedUsers.contains { $0["user"] as? String == expected["user"] as? String && $0["pass"] is String &&
                      networks($0) == networks(expected) && permissions($0) == permissions(expected) }
              }) else {
            throw SetbeamError.runtime("The selected input's private credentials could not be confirmed. The audience remains on Hold.")
        }
        let applied = try await api("/v3/config/paths/get/source")
        guard applied["source"] as? String == sourceConfiguration()["source"] as? String else {
            throw SetbeamError.runtime("The new input configuration could not be applied. The audience remains on Hold.")
        }
        // Revoke existing incoming connections only after the new credentials
        // have applied, so an old sender cannot reconnect in between updates.
        incomingRelay.disconnectSenders()
        if let path = try? await api("/v3/paths/get/source"),
           let publisher = path["source"] as? [String: Any], publisher["type"] as? String == "rtmpConn",
           let identifier = publisher["id"] as? String {
            // Closing the relay may already have ended this connection.
            _ = try? await api("/v3/rtmp/conns/kick/\(identifier)", method: "POST")
            if let current = try? await api("/v3/paths/get/source"),
               let active = current["source"] as? [String: Any], active["id"] as? String == identifier {
                throw SetbeamError.runtime("The previous incoming sender could not be disconnected. The audience remains on Hold.")
            }
        }
        sourceNeedsConfiguration = false
    }

    private func waitForHoldingOutput() async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            guard audiencePublisher?.isRunning == true, mediaServer?.isRunning == true else {
                throw SetbeamError.runtime("The holding output could not start. The input has not changed.")
            }
            if let path = try? await api("/v3/paths/get/live"), path["available"] as? Bool == true,
               MediaOutputContract.accepts(path: path),
               let frame = audiencePublisher?.lastVideoFrameAt, Date().timeIntervalSince(frame) < 3 { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SetbeamError.runtime("The holding output did not become ready. The input has not changed.")
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
        await acquireOperation()
        defer { releaseOperation() }
        sessionState.stopSharing()
        observedAudienceAudio = false
        publishSnapshot()
        audiencePublisher?.stop(); audiencePublisher = nil
        guestPassword = MediaRuntime.secret()
        _ = try? await api("/v3/config/global/patch", method: "PATCH", object: ["authInternalUsers": users()])
        publishSnapshot()
    }

    /// Reading state never starts, stops, retries, or probes media processes.
    public func snapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(session: sessionState, source: source, sourceAvailable: sessionState.sourceAvailable, connectionStage: observedStage,
            audienceAvailable: sessionState.audienceAvailable, audienceRevision: audienceRevision,
            lastFrameAt: observedFrameAt, message: observedProblem,
            preview: PlaybackDescriptor(origin: "http://127.0.0.1:\(webPort)", path: "local", user: "preview", password: previewPassword),
            audience: PlaybackDescriptor(origin: "http://\(viewerAddress):\(webPort)", path: "live", user: "guest", password: guestPassword), guestToken: guestPassword,
            sourceHasAudio: observedSourceAudio, audienceHasAudio: observedAudienceAudio)
    }

    /// Subscribers observe the same authoritative session state as command callers.
    public func updates() -> AsyncStream<RuntimeSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func publishSnapshot() { let value = snapshot(); observers.values.forEach { $0.yield(value) } }

    // Actor isolation alone permits interleaving across awaits. Serialize lifecycle commands
    // and reconciliation so an older probe cannot recreate a source after Stop or replacement.
    private func acquireOperation() async {
        if operationActive { await withCheckedContinuation { operationWaiters.append($0) } }
        else { operationActive = true }
    }
    private func releaseOperation() {
        if operationWaiters.isEmpty { operationActive = false }
        else { operationWaiters.removeFirst().resume() }
    }
    private func startHealthLoop() {
        healthTask?.cancel()
        let current = lifetime
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                guard let engine = self else { return }
                await engine.serviceTick(lifetime: current)
            }
        }
    }
    private func serviceTick(lifetime expected: UUID) async {
        await acquireOperation()
        defer { releaseOperation() }
        guard expected == lifetime, directory != nil, !Task.isCancelled else { return }
        let problem = await reconcile()
        _ = await refreshSnapshot(problem: problem)
    }
    private func reconcile() async -> String? {
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
            do {
                if sourceNeedsConfiguration { try await applySourceConfiguration() }
                try launchSource()
            } catch { problem = error.localizedDescription }
        }
        let audienceStalled = Date().timeIntervalSince(audiencePublisher?.lastVideoFrameAt ?? audienceStartedAt) > 12
        if !replacingSource, sharing, mediaServer?.isRunning == true, (audiencePublisher?.isRunning != true || audienceStalled), Date() >= nextAudienceRetry {
            audienceFailures += 1; nextAudienceRetry = Date().addingTimeInterval(min(10, pow(1.6, Double(audienceFailures))))
            audiencePublisher?.stop(); audiencePublisher = nil
            try? launchAudience()
        }
        return problem
    }

    @discardableResult private func refreshSnapshot(problem: String? = nil) async -> RuntimeSnapshot {
        let lastFrame = sourcePublisher?.lastVideoFrameAt
        let serverReady = directory != nil && mediaServer?.isRunning == true
        let localPath = serverReady ? try? await api("/v3/paths/get/local") : nil
        let localReady = localPath?["available"] as? Bool ?? false
        let frameFresh = lastFrame.map { Date().timeIntervalSince($0) < 6 } ?? false
        let available = !sourceNeedsConfiguration && localReady && frameFresh && MediaOutputContract.accepts(path: localPath) && (!isAccsoonSource || accsoonReceiver.isRunning)
        if available { sourceFailures = 0; serverFailures = 0 }
        var audiencePath: [String: Any]?
        if sharing && serverReady { audiencePath = try? await api("/v3/paths/get/live") }
        let audienceReady = audiencePath?["available"] as? Bool ?? false
        let audienceFresh = audiencePublisher?.lastVideoFrameAt.map { Date().timeIntervalSince($0) < 6 } ?? false
        let transmitterFound: Bool
        if case .accsoon(let uid) = source { transmitterFound = accsoonDiscovery.device(uid)?.recognized == true }
        else { transmitterFound = false }
        observedStage = ConnectionStage.resolve(serverReady: serverReady, sourceFresh: available,
            isTransmitter: isAccsoonSource, transmitterFound: transmitterFound, receiverRunning: accsoonReceiver.isRunning,
            connectionAcknowledged: (accsoonReceiver.statistics["connectionAcknowledgements"] ?? 0) > 0)
        let audienceAvailable = audienceReady && audienceFresh && MediaOutputContract.accepts(path: audiencePath)
        sessionState.updateSource(available: available); sessionState.updateAudience(available: audienceAvailable)
        observedFrameAt = lastFrame; observedProblem = available ? nil : problem.map(Redaction.text)
        observedSourceAudio = available && MediaTracks.hasAudio(localPath?["tracks"] as? [String] ?? [])
        observedAudienceAudio = audienceAvailable && MediaTracks.hasAudio(audiencePath?["tracks"] as? [String] ?? [])
        publishSnapshot()
        return snapshot()
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
        await acquireOperation()
        defer { releaseOperation() }
        shutdownLocked()
    }
    private func shutdownLocked() {
        sourceNeedsConfiguration = false
        incomingRelay.stop()
        lifetime = UUID(); healthTask?.cancel(); healthTask = nil
        sessionState.end(); observedFrameAt = nil; observedStage = .preparingMonitor
        observedSourceAudio = false; observedAudienceAudio = false; observedProblem = nil
        accsoonReceiver.stop(); accsoonDiscovery.stop()
        audiencePublisher?.stop(); audiencePublisher = nil
        sourcePublisher?.stop(); sourcePublisher = nil
        mediaServer?.stop(); mediaServer = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        publishSnapshot()
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
