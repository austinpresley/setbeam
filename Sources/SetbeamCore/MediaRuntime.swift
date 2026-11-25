import Foundation
import Darwin
import CoreFoundation

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
    public let audienceGeneration: UInt64
    public let lastFrameAt: Date?
    public let message: String?
    public let preview: PlaybackDescriptor
    public let audience: PlaybackDescriptor
    public let guestToken: String
    public let sourceHasAudio: Bool
    public let audienceHasAudio: Bool
    public let presenterCursorHighlight: Bool
}

enum SourceConfigurationStep: Sendable { case credentials, path }
enum ViewerAccessStep: Sendable { case credentials, credentialsApplied, disconnect }

/// Owns one received source, a private monitoring output, and an independent audience output.
public actor MediaRuntime {
    private let paths: RuntimePaths
    private var directory: URL?
    private var mediaServer: ManagedChild?
    private var screenCapture: MacScreenCapture?
    private let screenRetirement = ScreenCaptureRetirement()
    private var sourcePublisher: ManagedChild?
    private var audiencePublisher: ManagedChild?
    private var audienceUsesVideoToolbox = false
    private var audienceNeedsSoftware = false
    private var source: VideoSource = .sample
    private var sourceNeedsConfiguration = false
    private let beforeSourceConfigurationStep: @Sendable (SourceConfigurationStep) async throws -> Void
    private let beforeViewerAccessStep: @Sendable (ViewerAccessStep) async throws -> Void
    private var sourceArguments: [String] = []
    private var rtspPort: UInt16 = 0, apiPort: UInt16 = 0, webPort: UInt16 = 0, icePort: UInt16 = 0, rtmpPort: UInt16 = 0
    private let incomingRelay = IncomingStreamRelay()
    private let pyroHNetworks: @Sendable () -> [PyroHNetwork]
    private var pyroHPlayback: PyroHPlayback?
    private var pyroHProblem: String?
    private var publisherPassword = MediaRuntime.secret(), previewPassword = MediaRuntime.secret(), adminPassword = MediaRuntime.secret()
    private var guestPassword = MediaRuntime.secret()
    /// Under viewer approval the shared guest reader is absent; each admitted browser session
    /// reads with its own credential, which can be revoked without disturbing the others.
    private var approvalRequired = false
    private var viewerReaders: Set<ViewerReader> = []
    private var pendingRevocations: Set<String> = []
    /// Requested access is authoritative even if the controller response is lost.
    private var viewerAccessNeedsUpdate = false
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
    private var serverFailures = 0, controllerFailures = 0, audienceRevision = 0
    private var audienceGeneration: UInt64 = 0
    private var replacingSource = false
    private let accsoonDiscovery = AccsoonDiscovery()
    private let accsoonReceiver = AccsoonReceiver()
    private var audienceQuality = AudienceQuality.best
    private var audienceFrameRate = VideoFrameRate.source
    private var screenFrameRate = VideoFrameRate.source
    private var presenterCursorHighlight = false
    private let log: SessionLog
    private let serverWarnings = ServerWarnings()

    public init(paths: RuntimePaths, log: SessionLog = .shared,
                pyroHNetworks: @escaping @Sendable () -> [PyroHNetwork] = { PyroHNetwork.connected() }) {
        self.paths = paths; self.log = log; self.pyroHNetworks = pyroHNetworks
        beforeSourceConfigurationStep = { _ in }
        beforeViewerAccessStep = { _ in }
        let discovery = accsoonDiscovery
        accsoonReceiver.onAnnouncement = { data, host in discovery.observe(data, host: host) }
    }
    /// Allows actual-media tests to exercise failures between controller requests.
    init(paths: RuntimePaths, beforeSourceConfigurationStep: @escaping @Sendable (SourceConfigurationStep) async throws -> Void,
         beforeViewerAccessStep: @escaping @Sendable (ViewerAccessStep) async throws -> Void = { _ in }) {
        self.paths = paths; self.log = .shared
        self.pyroHNetworks = { PyroHNetwork.connected() }
        self.beforeSourceConfigurationStep = beforeSourceConfigurationStep
        self.beforeViewerAccessStep = beforeViewerAccessStep
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
        try Task.checkCancellation()
        if case .pyroH(let route) = validated { try route.requireCurrent(pyroHNetworks()) }
        shutdownLocked()
        var prepared = false
        defer { if !prepared { shutdownLocked() } }
        source = validated; self.viewerAddress = viewerAddress
        self.inputAddress = inputAddress ?? viewerAddress
        log.record("session.prepare", ["source": validated.label])
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
            try Task.checkCancellation()
            // A remembered capture device may be unplugged. Keep the session waiting for it.
            try? await launchSource()
            try Task.checkCancellation()
            sourceFailures = 0; audienceFailures = 0
            serverFailures = 0; nextServerRetry = .distantPast
            nextSourceRetry = Date().addingTimeInterval(2); nextAudienceRetry = .distantPast
            let initial = await refreshSnapshot()
            try Task.checkCancellation()
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
            // Each keyframe arrives as one burst of RTP packets. The default 512-packet reader
            // queue holds about 750 KB, so detailed monitoring-quality keyframes were discarded
            // mid-picture. 8192 holds MediaMTX's largest accepted 8 MiB access unit.
            "writeQueueSize": Self.readerQueuePackets,
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
        ]
        if !approvalRequired {
            result.append(["user": "guest", "pass": guestPassword, "ips": guestNetworks, "permissions": [["action": "read", "path": "live"]]])
        }
        for reader in viewerReaders.sorted(by: { $0.user < $1.user }) {
            result.append(["user": reader.user, "pass": reader.password, "ips": guestNetworks, "permissions": [["action": "read", "path": "live"]]])
        }
        if case .incoming(_, let key) = source {
            result.append(["user": "sender", "pass": key, "ips": ["127.0.0.1", "::1"], "permissions": [["action": "publish", "path": "source"]]])
        }
        return result
    }

    private static func networkRange(for address: String) -> String { NetworkAddress.subnet(for: address) }

    private func makeSourceArguments(displayFrameRate: Int?, accsoonInput: URL?) throws -> [String] {
        var args = commonFFmpegArguments
        switch source {
        case .macScreen:
            guard let displayFrameRate else { throw SetbeamError.runtime("The selected display has no capture rate.") }
            args += Self.screenInputArguments(frameRate: displayFrameRate)
        case .macWindow:
            args += Self.screenInputArguments(frameRate: screenFrameRate.captureRate(for: MacWindow.nativeFrameRate))
        case .sample:
            args += ["-re", "-stream_loop", "-1", "-i", paths.fixtures.appendingPathComponent("Demo.mp4").path]
        case .network, .incoming, .pyroH:
            let input: String
            if case .pyroH = source {
                guard let playback = pyroHPlayback else { throw SetbeamError.unavailable(PyroHRoute.rediscover) }
                input = playback.inputURL
                args += ["-protocol_whitelist", "tcp,rtp"]
            } else { input = publisherURL("source") }
            // External encodings can contain B pictures. Keep FFmpeg's DTS discovery
            // before stream copy; bypassing it can collapse/reorder their timestamps.
            args += ["-analyzeduration", "2000000", "-fpsprobesize", "0", "-probesize", "1000000", "-rtsp_transport", "tcp", "-i", input]
        case .capture(let video, let audio):
            // Request the device's own format and cadence; a fixed rate halves 60p inputs
            // or fails on devices without that mode.
            let device = CaptureDiscovery.devices().first { !$0.audio && $0.index == video }
            let mode = device.flatMap { CaptureDiscovery.mode(forVideoID: $0.id) }
            args += ["-f", "avfoundation"] + (mode?.arguments ?? ["-framerate", "30"]) + ["-i", "\(video):\(audio.map(String.init) ?? "none")"]
        case .captureDevice(let videoID, let audioID):
            let devices = CaptureDiscovery.devices()
            _ = try CaptureHardware.resolve(videoID, audio: false, in: devices)
            if let audioID { _ = try CaptureHardware.resolve(audioID, audio: true, in: devices) }
            let mode = CaptureDiscovery.mode(forVideoID: videoID)
            args += ["-f", "avfoundation"] + (mode?.arguments ?? ["-framerate", "30"]) + ["-video_device_unique_id", videoID]
            if let audioID { args += ["-audio_device_unique_id", audioID] }
            args += ["-i", "none:none"]
        case .accsoon:
            guard let accsoonInput else { throw SetbeamError.runtime("The selected Accsoon input was not prepared.") }
            args += ["-protocol_whitelist", "file,udp,rtp", "-analyzeduration", "1000000", "-probesize", "2000000", "-i", accsoonInput.path]
        }
        args += ["-map", "0:v:0", "-map", "0:a:0?"]
        // Monitoring relays the received picture untouched. Only raw capture frames need an encoder;
        // the screen source arrives already encoded at monitoring quality.
        args += source.isCapture ? MediaOutputContract.monitoringVideoArguments : ["-c:v", "copy"]
        args += MediaOutputContract.audioArguments
        return args + publishArguments("local")
    }

    /// Per-reader RTP queue. MediaMTX refuses to start unless this is a power of two.
    static let readerQueuePackets = 8192

    /// The elementary-stream pipe carries no timestamps. Generated ones advanced one 90 kHz tick per
    /// frame under stream copy, so stamp each frame by arrival from the constant-rate capture clock.
    static func screenInputArguments(frameRate: Int) -> [String] {
        // The normal rate probe can wait for dozens of pictures. At 1 fps that exceeds
        // the source watchdog, even though capture is producing valid frames every second.
        ["-use_wallclock_as_timestamps", "1", "-analyzeduration", "2000000", "-fpsprobesize", "0", "-max_ts_probe", "0",
         "-f", "h264", "-framerate", String(frameRate), "-i", "pipe:0"]
    }
    private var commonFFmpegArguments: [String] {
        ["-nostdin", "-hide_banner", "-loglevel", "warning", "-progress", "pipe:1", "-stats_period", "1"]
    }
    private func publisherURL(_ path: String) -> String { "rtsp://publisher:\(publisherPassword)@127.0.0.1:\(rtspPort)/\(path)" }
    private func publishArguments(_ path: String) -> [String] { ["-f", "rtsp", "-rtsp_transport", "tcp", publisherURL(path)] }
    private func child(_ name: String, _ executable: String, _ arguments: [String], onOutput: (@Sendable (Data) -> Void)? = nil) throws -> ManagedChild {
        guard let directory else { throw SetbeamError.runtime("Media session has not been prepared.") }
        return try ManagedChild(name: name, executable: paths.tools.appendingPathComponent(executable), arguments: arguments, directory: directory, onOutput: onOutput)
    }

    private func launchServer() async throws {
        guard let directory else { throw SetbeamError.unavailable("Connect a source first.") }
        let configuration = directory.appendingPathComponent("mediamtx.yml")
        try Self.json(configurationObject()).write(to: configuration, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
        let generation = audienceGeneration
        // MediaMTX logs reader discards and rejected input on stdout.
        mediaServer = try child("MediaMTX", "mediamtx", [configuration.path]) { [serverWarnings, log] data in
            for entry in serverWarnings.consume(String(decoding: data, as: UTF8.self)) {
                log.record("server.warning", ["message": entry.message, "repeats": entry.repeats])
            }
        }
        var ready = false
        defer {
            if !ready { mediaServer?.stop(); mediaServer = nil }
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            guard mediaServer?.isRunning == true else { throw SetbeamError.runtime("The video service could not start.") }
            if let global = try? await api("/v3/config/global/get"), global["authInternalUsers"] is [[String: Any]] {
                try Task.checkCancellation()
                sourceNeedsConfiguration = false
                incomingRelay.resumeSenders()
                // Stop may have rotated the credentials while this server was starting.
                viewerAccessNeedsUpdate = generation != audienceGeneration
                pendingRevocations = []
                controllerFailures = 0
                ready = true
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SetbeamError.runtime("The video service did not respond.")
    }
    private func launchSource() async throws {
        guard !sourceNeedsConfiguration else {
            throw SetbeamError.unavailable("The selected input is waiting for its private media configuration.")
        }
        await screenRetirement.wait()
        try Task.checkCancellation()
        accsoonReceiver.stop()
        stopPyroHPlayback()
        if case .pyroH(let route) = source {
            do { pyroHPlayback = try PyroHPlayback(route: route, currentNetworks: pyroHNetworks) }
            catch { pyroHProblem = error.localizedDescription; throw error }
        }
        var launched = false
        defer { if !launched { stopPyroHPlayback() } }
        let displayFrameRate: Int?
        if case .macScreen(let id) = source {
            let display = try MacDisplay.resolve(id, in: MacDisplay.connected())
            displayFrameRate = screenFrameRate.captureRate(for: display.frameRate)
        } else {
            displayFrameRate = nil
        }
        let accsoonInput: URL?
        if case .accsoon(let uid) = source, let directory {
            accsoonInput = try await accsoonReceiver.prepareInput(uid: uid, discovery: accsoonDiscovery, directory: directory)
        } else {
            accsoonInput = nil
        }
        sourceArguments = try makeSourceArguments(displayFrameRate: displayFrameRate, accsoonInput: accsoonInput)
        if source.isMacCapture, let directory {
            // A closed or hidden window fails here, before any helper starts, so retries stay cheap.
            if case .macWindow(let identity) = source { try MacWindowLocator.require(identity) }
            let pipe = Pipe()
            let capture = MacScreenCapture(retirement: screenRetirement)
            capture.setPresenterCursorHighlight(presenterCursorHighlight)
            do {
                sourcePublisher = try ManagedChild(name: "Screen input", executable: paths.tools.appendingPathComponent("ffmpeg"), arguments: sourceArguments, directory: directory, standardInput: pipe.fileHandleForReading)
                try pipe.fileHandleForReading.close()
                screenCapture = capture
                switch source {
                case .macWindow(let identity): try await capture.start(window: identity, output: pipe.fileHandleForWriting, frameRate: screenFrameRate)
                case .macScreen(let id):
                    try await capture.start(displayUUID: id, output: pipe.fileHandleForWriting, frameRate: screenFrameRate,
                                            expectedFramesPerSecond: displayFrameRate)
                default: break
                }
            } catch {
                capture.stop(); screenCapture = nil; sourcePublisher?.stop(); sourcePublisher = nil
                throw error
            }
        } else {
            do { sourcePublisher = try child("Source input", "ffmpeg", sourceArguments) }
            catch {
                if accsoonInput != nil { accsoonReceiver.stop(); try? accsoonDiscovery.start() }
                throw error
            }
        }
        launched = true
        sourceStartedAt = Date()
    }
    private func stopPyroHPlayback() {
        pyroHPlayback?.stop(); pyroHPlayback = nil; pyroHProblem = nil
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
    public func updateInputAddress(_ address: String, for expectedSource: VideoSource? = nil) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard expectedSource == nil || expectedSource == source,
              address != inputAddress, case .incoming(let port, _) = source else { return }
        try await incomingRelay.start(address: address, port: port, targetPort: rtmpPort)
        inputAddress = address
    }
    public func retrySource() async {
        await acquireOperation()
        defer { releaseOperation() }
        accsoonReceiver.stop()
        screenCapture?.stop(); screenCapture = nil; sourcePublisher?.stop(); sourcePublisher = nil; nextSourceRetry = .distantPast
        stopPyroHPlayback()
        sessionState.updateSource(available: false); observedSourceAudio = false
        publishSnapshot()
    }
    /// Private setup destination, never exposed by ViewerGateway.
    public func incomingDestination() -> (server: String, streamKey: String)? {
        guard case .incoming(let port, let key) = source else { return nil }
        return ("rtmp://\(inputAddress):\(port)", "source?user=sender&pass=\(key)")
    }

    public func startSharing(approval: Bool? = nil) async throws -> RuntimeSnapshot {
        let generation = audienceGeneration
        await acquireOperation()
        defer { releaseOperation() }
        try checkAudienceCommand(generation)
        guard mediaServer?.isRunning == true else { throw SetbeamError.unavailable("Connect a source before sharing.") }
        guard !sharing else { return snapshot() }
        // Start carries the current operator choice, so a coalesced access follow-up cannot
        // leave an older policy in effect when the publisher begins.
        if let approval { approvalRequired = approval }
        guestPassword = MediaRuntime.secret(); viewerReaders = []
        viewerAccessNeedsUpdate = true
        try await applyCredentials()
        try checkAudienceCommand(generation)
        viewerAccessNeedsUpdate = false; pendingRevocations = []
        try sessionState.startSharing()
        resetAudienceRetry()
        do { try launchAudience() }
        catch { endAudienceSharing(); throw error }
        log.record("sharing.start", ["quality": audienceQuality.rawValue, "fps": audienceFrameRate.rawValue])
        publishSnapshot()
        let result = await refreshSnapshot()
        if generation == audienceGeneration, Task.isCancelled { endAudienceSharing() }
        try checkAudienceCommand(generation)
        return result
    }
    public func setHold(_ enabled: Bool) async throws {
        let generation = audienceGeneration
        await acquireOperation()
        defer { releaseOperation() }
        try checkAudienceCommand(generation)
        try await setHoldLocked(enabled)
        try checkAudienceCommand(generation)
    }
    private func checkAudienceCommand(_ generation: UInt64) throws {
        guard generation == audienceGeneration else { throw CancellationError() }
        try Task.checkCancellation()
    }
    private func setHoldLocked(_ enabled: Bool) async throws {
        guard sharing else { throw SetbeamError.unavailable("Start sharing before holding the audience.") }
        try sessionState.setHold(enabled); sessionState.updateAudience(available: false)
        log.record(enabled ? "hold.on" : "hold.off")
        publishSnapshot()
        // The old publisher is still sending source media as Hold begins.
        audiencePublisher?.stop(timeout: enabled ? 0 : 2); audiencePublisher = nil
        resetAudienceRetry()
        try launchAudience()
        _ = await refreshSnapshot()
    }
    /// Keep the audience credential, ports, and Hold while replacing the one received input.
    /// A failed or absent replacement never resumes audience media automatically.
    public func replaceSource(_ candidate: VideoSource, inputAddress: String? = nil) async throws -> RuntimeSnapshot {
        let validated = try candidate.validated()
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        guard directory != nil, !replacingSource else { throw SetbeamError.unavailable("Connect a source before changing inputs.") }
        if case .pyroH(let route) = validated { try route.requireCurrent(pyroHNetworks()) }
        replacingSource = true
        defer { replacingSource = false }
        log.record("source.replace", ["source": validated.label, "sharing": sharing])
        // Establish a real holding output before touching the input. If it is already
        // running, leave that publisher and every connected audience reader alone.
        if sharing {
            if !holding { try await setHoldLocked(true) }
            else if audiencePublisher?.isRunning != true { try launchAudience() }
            if sharing { try await waitForHoldingOutput(generation: audienceGeneration) }
        }
        // Bind a replacement incoming destination before disturbing the current
        // source. An occupied port must never terminate the audience media server.
        try Task.checkCancellation()
        if case .incoming(let port, _) = validated {
            try await incomingRelay.start(address: inputAddress ?? self.inputAddress, port: port, targetPort: rtmpPort,
                                          suspendSenders: true)
        } else { incomingRelay.stop() }
        accsoonReceiver.stop(); accsoonDiscovery.stop()
        screenCapture?.stop(); screenCapture = nil; sourcePublisher?.stop(); sourcePublisher = nil
        stopPyroHPlayback()
        sessionState.updateSource(available: false)
        observedFrameAt = nil; observedSourceAudio = false
        sourceNeedsConfiguration = true
        presenterCursorHighlight = false
        source = validated
        audienceNeedsSoftware = false
        if let inputAddress { self.inputAddress = inputAddress }
        sourceFailures = 0
        nextSourceRetry = Date().addingTimeInterval(2)
        publishSnapshot()
        try await applySourceConfiguration()
        try? await launchSource()
        return await refreshSnapshot()
    }

    /// A failed or partly applied controller update never authorizes a source
    /// publisher to read the previous path under the newly selected identity.
    private func applySourceConfiguration() async throws {
        // MediaMTX reloads only this input path and its sender credentials.
        // Its RTSP/WebRTC servers, holding publisher, ports, and credentials survive.
        try await beforeSourceConfigurationStep(.credentials)
        try await applyCredentials()
        try await beforeSourceConfigurationStep(.path)
        _ = try await api("/v3/config/paths/replace/source", method: "POST", object: sourceConfiguration())
        try await configurationBarrier()
        let applied = try await api("/v3/config/paths/get/source")
        guard applied["source"] as? String == sourceConfiguration()["source"] as? String else {
            throw SetbeamError.runtime("The new input configuration could not be applied. The audience remains on Hold.")
        }
        // Forwarding stays suspended across retries. Only a sender from before the
        // replacement can still be attached while the controller is being reconciled.
        if case .incoming = source {
            let path = try await mediaPath("source")
            if let publisher = path?["source"] as? [String: Any], publisher["type"] as? String == "rtmpConn" {
                guard let id = publisher["id"] as? String, UUID(uuidString: id) != nil else {
                    throw SetbeamError.runtime("The previous incoming sender could not be identified.")
                }
                _ = try? await api("/v3/rtmp/conns/kick/\(id)", method: "POST")
                let current = try await mediaPath("source")
                if let active = current?["source"] as? [String: Any], active["id"] as? String == id {
                    throw SetbeamError.runtime("The previous incoming sender could not be disconnected. The audience remains on Hold.")
                }
            }
        }
        sourceNeedsConfiguration = false
        incomingRelay.resumeSenders()
    }

    private func waitForHoldingOutput(generation: UInt64) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try Task.checkCancellation()
            // Stop already suppressed outgoing media, so input replacement can continue privately.
            guard generation == audienceGeneration else { return }
            guard audiencePublisher?.isRunning == true, mediaServer?.isRunning == true else {
                throw SetbeamError.runtime("The holding output could not start. The input has not changed.")
            }
            if let path = try? await mediaPath("live"), path["available"] as? Bool == true,
               MediaOutputContract.accepts(path: path),
               let frame = audiencePublisher?.lastVideoFrameAt, Date().timeIntervalSince(frame) < 3 { return }
            if generation != audienceGeneration { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard generation == audienceGeneration else { return }
        throw SetbeamError.runtime("The holding output did not become ready. The input has not changed.")
    }
    private func launchAudience() throws {
        guard sharing else { return }
        var args = commonFFmpegArguments
        // These inputs use Setbeam's own even-size 8-bit H.264 private publisher or fixture.
        // Relayed streams can change codec, bit depth and geometry on the same address.
        let directVideoToolbox = !holding && !audienceNeedsSoftware && (source == .sample || source.isMacCapture || source.isCapture)
        if holding {
            args += ["-re", "-stream_loop", "-1", "-i", paths.fixtures.appendingPathComponent("Hold.mp4").path,
                     "-c:v", "copy", "-c:a", "libopus", "-b:a", "64k", "-ar", "48000", "-ac", "2"]
        } else {
            if directVideoToolbox {
                args += ["-xerror", "-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"]
            }
            // Frame-threaded decoding can buffer a core-count's worth of pictures. At
            // 1 fps that can exceed the publisher watchdog before producing its first frame.
            args += ["-analyzeduration", "2000000", "-fpsprobesize", "0", "-max_ts_probe", "0", "-probesize", "1000000",
                     "-threads:v", "2", "-thread_type:v", "slice", "-rtsp_transport", "tcp", "-i", publisherURL("local"),
                     "-map", "0:v:0", "-map", "0:a:0?"]
            // Every source, including the sample, honors viewer bitrate and cadence settings.
            args += MediaOutputContract.audienceVideoArguments(audienceQuality, frameRate: audienceFrameRate,
                                                                directVideoToolbox: directVideoToolbox) + ["-c:a", "copy"]
        }
        audiencePublisher = try child(holding ? "Audience holding output" : "Audience relay", "ffmpeg", args + publishArguments("live"))
        audienceUsesVideoToolbox = directVideoToolbox
        audienceStartedAt = Date(); audienceRevision += 1
    }
    /// Applies to the next audience encode. An active, unheld audience reconnects at the new rate.
    public func setAudienceQuality(_ quality: AudienceQuality) async {
        await setVideoSettings(quality: quality)
    }

    /// Applies only to the currently selected Mac source, including recovery of its capture.
    public func setPresenterCursorHighlight(_ enabled: Bool, for expectedSource: VideoSource) async {
        await acquireOperation()
        defer { releaseOperation() }
        guard directory != nil, source.isMacCapture, source == expectedSource,
              enabled != presenterCursorHighlight else { return }
        presenterCursorHighlight = enabled
        screenCapture?.setPresenterCursorHighlight(enabled)
        publishSnapshot()
    }

    /// Applies saved video settings together, replacing at most one source and audience publisher.
    /// Viewer-only changes preserve full-rate local monitoring. Screen capture changes retain
    /// the server, viewing identity, sharing intent, and any already-running holding output.
    public func setVideoSettings(quality: AudienceQuality? = nil, frameRate: VideoFrameRate? = nil,
                                 screenFrameRate: VideoFrameRate? = nil) async {
        await acquireOperation()
        defer { releaseOperation() }
        let quality = quality ?? audienceQuality, rate = frameRate ?? audienceFrameRate
        let screenRate = screenFrameRate ?? self.screenFrameRate
        let audienceChanged = quality != audienceQuality || rate != audienceFrameRate
        let screenChanged = screenRate != self.screenFrameRate
        guard audienceChanged || screenChanged else { return }
        audienceQuality = quality; audienceFrameRate = rate; self.screenFrameRate = screenRate
        log.record("video.settings", ["quality": quality.rawValue, "viewerFPS": rate.rawValue, "screenFPS": screenRate.rawValue])
        let restartScreen = source.isMacCapture && screenChanged && directory != nil
        let restartAudience = sharing && !holding && (audienceChanged || restartScreen)
        if restartAudience {
            audiencePublisher?.stop(); audiencePublisher = nil
            sessionState.updateAudience(available: false)
        }
        if restartScreen {
            screenCapture?.stop(); screenCapture = nil; sourcePublisher?.stop(); sourcePublisher = nil
            sessionState.updateSource(available: false); observedFrameAt = nil
        }
        publishSnapshot()
        if restartScreen { try? await launchSource() }
        if restartAudience { try? launchAudience() }
        _ = await refreshSnapshot()
    }
    public func stopSharing() {
        // Cut media before waiting for any parked controller request or input operation.
        endAudienceSharing()
    }

    private func endAudienceSharing() {
        audienceGeneration &+= 1
        if sharing { log.record("sharing.stop") }
        sessionState.stopSharing()
        observedAudienceAudio = false
        audiencePublisher?.stop(timeout: 0); audiencePublisher = nil
        guestPassword = MediaRuntime.secret(); viewerReaders = []; pendingRevocations = []
        viewerAccessNeedsUpdate = true
        resetAudienceRetry()
        publishSnapshot()
    }

    private func resetAudienceRetry() {
        audienceFailures = 0; nextAudienceRetry = .distantPast
    }

    /// Applies viewer approval and the admitted sessions' readers, then disconnects any reader
    /// whose access ended. Credentials apply before the disconnect, so a revoked page cannot
    /// reconnect in between. Changing approval during sharing moves viewers to the new credentials
    /// through a publisher revision. Successful individual removal preserves other readers.
    /// An uncertain update ends audience sharing while local monitoring continues.
    public func setViewerAccess(approval: Bool, readers: Set<ViewerReader>, for expectedGeneration: UInt64? = nil) async throws {
        let generation = expectedGeneration ?? audienceGeneration
        await acquireOperation()
        defer { releaseOperation() }
        try checkAudienceCommand(generation)
        let revoked = Set(viewerReaders.subtracting(readers).map(\.user)).union(approval && !approvalRequired ? ["guest"] : [])
        let enablingApproval = approval && !approvalRequired
        guard approval != approvalRequired || readers != viewerReaders || !pendingRevocations.isEmpty || viewerAccessNeedsUpdate else { return }
        approvalRequired = approval; viewerReaders = readers
        viewerAccessNeedsUpdate = true
        log.record("viewers.access", ["approval": approval, "readers": readers.count, "revoked": revoked.count])
        if enablingApproval && sharing {
            // The gateway already asks new viewers to wait. Suppress the old shared output
            // throughout the controller update, including a timeout or lost response.
            audiencePublisher?.stop(); audiencePublisher = nil
            sessionState.updateAudience(available: false); observedAudienceAudio = false
            publishSnapshot()
        }
        // A restarted server starts from these users and has no earlier sessions to disconnect.
        guard mediaServer?.isRunning == true else { pendingRevocations = []; return }
        do {
            try await beforeViewerAccessStep(.credentials)
            try checkAudienceCommand(generation)
            try await applyCredentials()
            try checkAudienceCommand(generation)
            try await beforeViewerAccessStep(.credentialsApplied)
            try checkAudienceCommand(generation)
            pendingRevocations.formUnion(revoked)
            if !pendingRevocations.isEmpty {
                try await beforeViewerAccessStep(.disconnect)
                try checkAudienceCommand(generation)
                try await disconnectReaders(pendingRevocations, generation: generation)
                try checkAudienceCommand(generation)
                pendingRevocations = []
            }
            if enablingApproval && sharing { try launchAudience() }
            viewerAccessNeedsUpdate = false
        } catch {
            // A failed response cannot establish which credentials the server accepted.
            // End audience sharing instead of restoring an unsafe authorization state.
            if generation == audienceGeneration, sharing { endAudienceSharing() }
            throw error
        }
    }

    public func viewerAccessConfirmed(approval: Bool, readers: Set<ViewerReader>, for generation: UInt64) -> Bool {
        generation == audienceGeneration && sharing && !viewerAccessNeedsUpdate && approvalRequired == approval
            && viewerReaders == readers && mediaServer?.isRunning == true
    }

    public func audiencePreviewURL(generation: UInt64, revision: Int) -> String? {
        guard generation == audienceGeneration, revision == audienceRevision, sessionState.audience == .live else { return nil }
        return localRTSP("live")
    }
    private func applyCredentials() async throws {
        let expected = users()
        _ = try await api("/v3/config/global/patch", method: "PATCH", object: ["authInternalUsers": expected])
        try await configurationBarrier()
        let global = try await api("/v3/config/global/get")
        // MediaMTX redacts password bytes. The barrier sequences the write
        // before this readback of the users, networks and permissions.
        func networks(_ user: [String: Any]) -> Set<String>? {
            guard let ips = user["ips"] as? [String] ?? (user["ips"] is NSNull ? [] : nil) else { return nil }
            return Set(ips.map { $0.contains("/") ? $0 : $0 + ($0.contains(":") ? "/128" : "/32") })
        }
        func permissions(_ user: [String: Any]) -> Set<String>? {
            guard let entries = user["permissions"] as? [[String: String]], entries.allSatisfy({ $0["action"] != nil }) else { return nil }
            return Set(entries.map { $0["action"]! + ":" + ($0["path"] ?? "") })
        }
        guard let actual = global["authInternalUsers"] as? [[String: Any]], actual.count == expected.count,
              expected.allSatisfy({ user in
                  actual.contains { $0["user"] as? String == user["user"] as? String && $0["pass"] is String &&
                      networks($0) == networks(user) && permissions($0) == permissions(user) }
              }) else {
            throw SetbeamError.runtime("The private media credentials could not be confirmed.")
        }
    }

    private func configurationBarrier() async throws {
        // The PATCH response can precede the core loop's apply. A following
        // mutation waits for the loop before it can be acknowledged.
        _ = try await api("/v3/config/global/patch", method: "PATCH", object: [:])
    }

    /// Ends existing media sessions read with these credentials.
    private func disconnectReaders(_ users: Set<String>, generation: UInt64) async throws {
        for (list, kick) in [("/v3/webrtcsessions/list", "/v3/webrtcsessions/kick/"), ("/v3/rtspsessions/list", "/v3/rtspsessions/kick/")] {
            // Each request is one coherent listing. Fail closed if it is truncated
            // instead of treating an unchecked page or malformed row as an empty result.
            let query = list + "?itemsPerPage=1000"
            let sessions = try Self.validatedSessionUsers(await api(query))
            for (id, user) in sessions where users.contains(user) {
                try checkAudienceCommand(generation)
                _ = try? await api(kick + id.uuidString.lowercased(), method: "POST")
            }
            try checkAudienceCommand(generation)
            let remaining = try Self.validatedSessionUsers(await api(query))
            guard !remaining.values.contains(where: users.contains) else {
                throw SetbeamError.runtime("A removed viewer could not be disconnected.")
            }
        }
    }

    static func validatedSessionUsers(_ listing: [String: Any]) throws -> [UUID: String] {
        let error = SetbeamError.runtime("The media controller did not return a complete session list.")
        guard let items = listing["items"] as? [[String: Any]],
              let count = listing["itemCount"] as? NSNumber, CFGetTypeID(count) != CFBooleanGetTypeID(),
              let pages = listing["pageCount"] as? NSNumber, CFGetTypeID(pages) != CFBooleanGetTypeID(),
              count == NSNumber(value: items.count),
              pages == NSNumber(value: items.isEmpty ? 0 : 1) else { throw error }
        var users: [UUID: String] = [:]
        for item in items {
            guard let value = item["id"] as? String, let id = UUID(uuidString: value),
                  let user = item["user"] as? String, users.updateValue(user, forKey: id) == nil else { throw error }
        }
        return users
    }

    /// Reading state never starts, stops, retries, or probes media processes.
    public func snapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(session: sessionState, source: source, sourceAvailable: sessionState.sourceAvailable, connectionStage: observedStage,
            audienceAvailable: sessionState.audienceAvailable, audienceRevision: audienceRevision, audienceGeneration: audienceGeneration,
            lastFrameAt: observedFrameAt, message: observedProblem,
            preview: PlaybackDescriptor(origin: "http://127.0.0.1:\(webPort)", path: "local", user: "preview", password: previewPassword),
            audience: PlaybackDescriptor(origin: "http://\(viewerAddress):\(webPort)", path: "live", user: "guest", password: guestPassword), guestToken: guestPassword,
            sourceHasAudio: observedSourceAudio, audienceHasAudio: observedAudienceAudio,
            presenterCursorHighlight: presenterCursorHighlight)
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

    // Serialize source lifecycle and controller writes across awaits. Stop invalidates the
    // audience generation outside this queue because it must cut output during a parked write.
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
        for entry in serverWarnings.due() { log.record("server.warning", ["message": entry.message, "repeats": entry.repeats]) }
        _ = await refreshSnapshot(problem: problem)
    }
    private func reconcile() async -> String? {
        var problem: String? = pyroHPlayback?.problem ?? pyroHProblem
        let serverUnhealthy = mediaServer?.isRunning != true || controllerFailures >= 3
        if !replacingSource, directory != nil, serverUnhealthy {
            problem = "The video service is restarting. Your selected source has not changed."
            if Date() >= nextServerRetry {
                serverFailures += 1; nextServerRetry = Date().addingTimeInterval(min(10, pow(1.6, Double(serverFailures))))
                log.record("server.restart", ["failures": serverFailures, "controllerFailures": controllerFailures, "exit": Self.exitDescription(mediaServer?.terminationStatus), "error": mediaServer?.recentError.suffix(300).description ?? ""])
                screenCapture?.stop(); screenCapture = nil; sourcePublisher?.stop(); sourcePublisher = nil; audiencePublisher?.stop(); audiencePublisher = nil; mediaServer?.stop(timeout: 0); mediaServer = nil
                stopPyroHPlayback()
                do { try await launchServer(); try? await launchSource(); if sharing { try? launchAudience() } }
                catch { problem = "The video service is retrying. Your preview will return here." }
            }
        }
        let sourceStalled = Date().timeIntervalSince(sourcePublisher?.lastVideoFrameAt ?? sourceStartedAt) > 12
        let receiverFailed = isAccsoonSource && sourcePublisher != nil && !accsoonReceiver.isRunning
        // The relay can close before FFmpeg reports EOF or empties its buffers.
        if pyroHPlayback?.problem != nil {
            sourcePublisher?.stop(); sourcePublisher = nil
        }
        let screenError = screenCapture?.lastError
        if !replacingSource, mediaServer?.isRunning == true, (sourcePublisher?.isRunning != true || sourceStalled || receiverFailed || screenError != nil), Date() >= nextSourceRetry {
            problem = problem ?? (isAccsoonSource ? accsoonReceiver.lastError : screenError) ?? sourcePublisher?.recentError
            sourceFailures += 1; nextSourceRetry = Date().addingTimeInterval(min(10, pow(1.6, Double(sourceFailures))))
            let reason = sourcePublisher == nil ? "not running" : sourcePublisher?.isRunning != true ? "exited" : receiverFailed ? "receiver failed" : screenError != nil ? "screen capture failed" : "stalled"
            log.record("source.restart", ["reason": reason, "failures": sourceFailures, "exit": Self.exitDescription(sourcePublisher?.terminationStatus),
                                          "error": String((problem ?? "").suffix(300))])
            screenCapture?.stop(); screenCapture = nil; sourcePublisher?.stop(); sourcePublisher = nil
            do {
                if sourceNeedsConfiguration { try await applySourceConfiguration() }
                try await launchSource()
            } catch { problem = error.localizedDescription }
        }
        if !sharing, viewerAccessNeedsUpdate, controllerFailures == 0, mediaServer?.isRunning == true {
            let generation = audienceGeneration
            if (try? await applyCredentials()) != nil, generation == audienceGeneration { viewerAccessNeedsUpdate = false }
        }
        let audienceFrame = audiencePublisher?.lastVideoFrameAt
        let audienceStalled = Date().timeIntervalSince(audienceFrame ?? audienceStartedAt) > (audienceUsesVideoToolbox && audienceFrame == nil ? 6 : 12)
        if !replacingSource, sharing, mediaServer?.isRunning == true, (audiencePublisher?.isRunning != true || audienceStalled), Date() >= nextAudienceRetry {
            if audienceUsesVideoToolbox {
                audienceNeedsSoftware = true
                log.record("audience.publisher.software-retry")
            }
            audienceFailures += 1; nextAudienceRetry = Date().addingTimeInterval(min(10, pow(1.6, Double(audienceFailures))))
            log.record("audience.restart", ["reason": audiencePublisher?.isRunning != true ? "exited" : "stalled", "failures": audienceFailures,
                                            "holding": holding, "error": String((audiencePublisher?.recentError ?? "").suffix(300))])
            audiencePublisher?.stop(); audiencePublisher = nil
            try? launchAudience()
        }
        return problem
    }

    @discardableResult private func refreshSnapshot(problem: String? = nil) async -> RuntimeSnapshot {
        let lastFrame = sourcePublisher?.lastVideoFrameAt
        let serverRunning = directory != nil && mediaServer?.isRunning == true
        var controllerResponded = serverRunning
        var localPath: [String: Any]?
        if serverRunning {
            do { localPath = try await mediaPath("local") }
            catch { controllerResponded = false }
        }
        let localReady = localPath?["available"] as? Bool ?? false
        let frameFresh = lastFrame.map { Date().timeIntervalSince($0) < 6 } ?? false
        let localDecodable = MediaOutputContract.acceptsMonitoring(path: localPath)
        let screenError = screenCapture?.lastError
        let available = screenError == nil && pyroHPlayback?.problem == nil && !sourceNeedsConfiguration && localReady
            && frameFresh && localDecodable && (!isAccsoonSource || accsoonReceiver.isRunning)
        if available { sourceFailures = 0; serverFailures = 0 }
        var audiencePath: [String: Any]?
        let generation = audienceGeneration
        if sharing && controllerResponded {
            do { audiencePath = try await mediaPath("live") }
            catch { controllerResponded = false }
        }
        if serverRunning { controllerFailures = controllerResponded ? 0 : controllerFailures + 1 }
        let audienceReady = audiencePath?["available"] as? Bool ?? false
        let audienceFresh = audiencePublisher?.lastVideoFrameAt.map { Date().timeIntervalSince($0) < 6 } ?? false
        let transmitterFound: Bool
        if case .accsoon(let uid) = source { transmitterFound = accsoonDiscovery.device(uid)?.recognized == true }
        else { transmitterFound = false }
        let previousStage = observedStage
        observedStage = ConnectionStage.resolve(serverReady: controllerResponded, sourceFresh: available,
            isTransmitter: isAccsoonSource, transmitterFound: transmitterFound, receiverRunning: accsoonReceiver.isRunning,
            connectionAcknowledged: (accsoonReceiver.statistics["connectionAcknowledgements"] ?? 0) > 0)
        if observedStage != previousStage { log.record("stage", ["stage": observedStage.rawValue]) }
        let audienceAvailable = sharing && generation == audienceGeneration && audienceReady && audienceFresh && MediaOutputContract.accepts(path: audiencePath)
        if audienceAvailable { resetAudienceRetry() }
        if available != sessionState.sourceAvailable {
            // Each readiness input is recorded so a short outage can be attributed afterwards.
            log.record(available ? "source.available" : "source.unavailable", ["stage": observedStage.rawValue, "localPath": localReady,
                "decodable": localDecodable, "receiver": !isAccsoonSource || accsoonReceiver.isRunning,
                "frameAge": lastFrame.map { Date().timeIntervalSince($0) } ?? -1, "problem": problem ?? ""])
        }
        if sharing, audienceAvailable != sessionState.audienceAvailable {
            log.record(audienceAvailable ? "audience.available" : "audience.unavailable", ["holding": holding, "outputPath": audienceReady,
                "frameAge": audiencePublisher?.lastVideoFrameAt.map { Date().timeIntervalSince($0) } ?? -1])
        }
        sessionState.updateSource(available: available); sessionState.updateAudience(available: audienceAvailable)
        observedFrameAt = lastFrame
        observedProblem = available ? nil : (pyroHPlayback?.problem ?? pyroHProblem ?? problem ?? screenError).map(Redaction.text)
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
        let value = snapshot()
        return ["source": source.label, "sourceAvailable": value.sourceAvailable, "connectionStage": value.connectionStage.rawValue, "sharing": sharing, "holding": holding,
                "viewerQuality": audienceQuality.rawValue, "viewerFPS": audienceFrameRate.rawValue, "screenFPS": screenFrameRate.rawValue,
                "audienceVideoToolbox": audiencePublisher != nil && audienceUsesVideoToolbox,
                "audienceError": Redaction.text(audiencePublisher?.recentError ?? ""),
                "audienceProgress": audiencePublisher?.capturedOutput.suffix(1200).description ?? "",
                "sourceFrameAge": sourcePublisher?.lastVideoFrameAt.map { Date().timeIntervalSince($0) } ?? -1,
                "audienceFrameAge": audiencePublisher?.lastVideoFrameAt.map { Date().timeIntervalSince($0) } ?? -1,
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
        await screenRetirement.wait()
    }
    private func shutdownLocked() {
        if directory != nil { log.record("session.end", ["sharing": sharing, "holding": holding]) }
        sourceNeedsConfiguration = false
        presenterCursorHighlight = false
        audienceGeneration &+= 1
        incomingRelay.stop()
        lifetime = UUID(); healthTask?.cancel(); healthTask = nil
        controllerFailures = 0
        audienceNeedsSoftware = false; audienceUsesVideoToolbox = false
        sessionState.end(); observedFrameAt = nil; observedStage = .preparingMonitor
        observedSourceAudio = false; observedAudienceAudio = false; observedProblem = nil
        accsoonReceiver.stop(); accsoonDiscovery.stop()
        audiencePublisher?.stop(); audiencePublisher = nil
        screenCapture?.stop(); screenCapture = nil; sourcePublisher?.stop(); sourcePublisher = nil
        stopPyroHPlayback()
        mediaServer?.stop(); mediaServer = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        publishSnapshot()
    }

    private func mediaPath(_ name: String) async throws -> [String: Any]? {
        let path = try await api("/v3/paths/get/\(name)", missingIsEmpty: true)
        if path.isEmpty { return nil }
        guard path["available"] is Bool else { throw SetbeamError.runtime("The media controller returned an invalid path.") }
        return path
    }

    private func api(_ path: String, method: String = "GET", object: [String: Any]? = nil,
                     missingIsEmpty: Bool = false) async throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(apiPort)\(path)")!
        var request = URLRequest(url: url, timeoutInterval: 2); request.httpMethod = method
        request.setValue("Basic " + Data("admin:\(adminPassword)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let object { request.httpBody = try JSONSerialization.data(withJSONObject: object); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        if missingIsEmpty, (response as? HTTPURLResponse)?.statusCode == 404 { return [:] }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw SetbeamError.runtime("The local media controller did not accept the request.") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], !object.isEmpty else {
            throw SetbeamError.runtime("The media controller returned an invalid response.")
        }
        return object
    }
    /// Decodes a raw wait status for the session log.
    static func exitDescription(_ status: Int32?) -> String {
        guard let status else { return "running" }
        return status & 0x7f == 0 ? "code \((status >> 8) & 0xff)" : "signal \(status & 0x7f)"
    }
    private static func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) }
}
