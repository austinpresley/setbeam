import AppKit
import AVFoundation
import SetbeamCore

/// One timestamped decode of the private relay serves the main and floating windows.
/// Audio and picture use the same native playback clock. Audience controls never touch it.
@MainActor final class NativePreview: ObservableObject {
    @Published private(set) var picture: PreviewPicture?
    private var decoder: ManagedChild?
    private var playback: PreviewPlayback?
    private var url: String?
    private var directory: URL?
    private var generation = UUID()
    private var lastFrameAt = Date.distantPast
    private var decoderStartedAt = Date.distantPast
    private var nextRetry = Date.distantPast
    private var soundRequestedAt: Date?
    private var soundFailureReported = false
    private var sourceReady = false
    private var watchdog: Task<Void, Never>?
    private let audioEnabled: Bool
    private let width: Int
    private let frameRate: Int
    init(audioEnabled: Bool = true, width: Int = 0, frameRate: Int = 0) {
        self.audioEnabled = audioEnabled; self.width = width; self.frameRate = frameRate
    }
    var onPlaybackState: ((Bool, String?) -> Void)?
    var onSoundUnavailable: ((String) -> Void)?
    var diagnostics: PreviewPlaybackStats { playback?.snapshot() ?? PreviewPlaybackStats() }
    var muted = true {
        didSet {
            guard oldValue != muted else { return }
            soundRequestedAt = muted ? nil : Date(); soundFailureReported = false
            playback?.setMuted(muted)
        }
    }

    func start(url: String) throws {
        stop(); self.url = url
        let run = FileManager.default.temporaryDirectory.appendingPathComponent("Setbeam-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directory = run
        try startDecoder()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self else { return }
                self.observeHealth()
            }
        }
    }
    private func startDecoder() throws {
        guard let url, let directory else { return }
        generation = UUID(); decoder?.stop(); decoder = nil; playback?.stop()
        lastFrameAt = .distantPast; decoderStartedAt = Date()
        soundRequestedAt = muted ? nil : Date(); soundFailureReported = false
        let current = generation
        let output = PreviewPlayback(audioEnabled: audioEnabled, muted: muted) { [weak self] frame in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.picture = frame; self.lastFrameAt = Date()
            }
        }
        playback = output
        var arguments = [url]
        if !audioEnabled { arguments.append("--silent") }
        if width > 0 { arguments += ["--width", String(width)] }
        if frameRate > 0 { arguments += ["--fps", String(frameRate)] }
        do {
            decoder = try ManagedChild(name: "Native playback", executable: AppAssets.runtimePaths.tools.appendingPathComponent("setbeam-preview"),
                arguments: arguments, directory: directory, onOutput: { output.consume($0) })
        } catch { output.stop(); playback = nil; throw error }
    }
    /// Upstream availability is an observation. Decoder recovery runs on our own watchdog.
    func checkHealth(sourceAvailable: Bool) { sourceReady = sourceAvailable; observeHealth() }
    private func observeHealth() {
        let stats = diagnostics
        let playing = picture != nil && Date().timeIntervalSince(lastFrameAt) < PreviewPlaybackTiming.freshnessInterval(sourceFPS: stats.sourceFPS)
        onPlaybackState?(playing, playing ? nil : stats.error ?? decoder?.recentError)
        if audioEnabled, !muted, playing, !soundFailureReported {
            let timedOut = soundRequestedAt.map { Date().timeIntervalSince($0) > 4 } ?? false
            let message: String?
            if stats.hasAudio == false { message = "This input did not provide local sound. Video monitoring continues." }
            else if let error = stats.audioError { message = error }
            else if timedOut && !stats.audioRendering { message = "The audio device did not respond. Check the Mac's sound output and try again. Video monitoring continues." }
            else { message = nil }
            if let message { soundFailureReported = true; onSoundUnavailable?(message) }
        }
        writeTelemetry(stats: stats, playing: playing)
        if sourceReady, (decoder?.isRunning != true || Date().timeIntervalSince(max(lastFrameAt, decoderStartedAt)) > 8 || stats.error != nil),
           url != nil, Date() >= nextRetry {
            nextRetry = Date().addingTimeInterval(3)
            do { try startDecoder() } catch { onPlaybackState?(false, Redaction.text(error.localizedDescription)) }
        }
    }
    private func writeTelemetry(stats: PreviewPlaybackStats, playing: Bool) {
        let args = CommandLine.arguments
        guard audioEnabled, let index = args.firstIndex(of: "--native-preview-file"), index + 1 < args.count else { return }
        let floating = NSApp.windows.first { $0.title == "Setbeam Preview" }
        let value: [String: Any] = ["playing": playing, "ready": playing ? 4 : 0, "time": stats.presentedPTS,
            "frames": stats.presentedFrames, "decodedFrames": stats.decodedFrames, "renderer": "native-timestamped-nv12",
            "decoderRunning": decoder?.isRunning ?? false, "muted": muted, "audioOpening": !muted && !stats.audioRendering,
            "audioSamplesScheduled": stats.audioSamplesScheduled, "audioRendering": stats.audioRendering,
            "audioClockPTS": stats.audioRendering ? stats.clockPTS : 0, "lastScheduledAudioPTS": stats.audioPTS,
            "audioVideoClockShared": true, "videoPTS": stats.presentedPTS, "playbackClockPTS": stats.clockPTS,
            "videoClockErrorMilliseconds": stats.videoClockError * 1000,
            "width": stats.width, "height": stats.height, "sourceFPS": stats.sourceFPS,
            "videoQueueFrames": stats.videoQueueFrames, "videoQueueBytes": stats.videoQueueBytes,
            "audioQueuePackets": stats.audioQueuePackets, "droppedVideoFrames": stats.droppedVideoFrames,
            "droppedAudioPackets": stats.droppedAudioPackets, "droppedPresentationFrames": stats.droppedPresentationFrames, "clockResets": stats.clockResets,
            "floatingVisible": floating?.isVisible ?? false, "floatingAboveNormal": (floating?.level.rawValue ?? 0) > NSWindow.Level.normal.rawValue]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            let destination = URL(fileURLWithPath: args[index+1]); try? data.write(to: destination, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }
    func retry() {
        guard url != nil else { return }; nextRetry = Date().addingTimeInterval(3)
        do { try startDecoder() } catch { onPlaybackState?(false, Redaction.text(error.localizedDescription)) }
    }
    func stop() {
        watchdog?.cancel(); watchdog = nil; generation = UUID()
        decoder?.stop(); decoder = nil; playback?.stop(); playback = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil; url = nil; picture = nil; lastFrameAt = .distantPast; sourceReady = false
    }
}

struct PreviewPlaybackStats {
    var decodedFrames = 0, presentedFrames = 0, width = 0, height = 0
    var videoQueueFrames = 0, videoQueueBytes = 0, audioQueuePackets = 0
    var droppedVideoFrames = 0, droppedAudioPackets = 0, droppedPresentationFrames = 0, audioSamplesScheduled = 0, clockResets = 0
    var presentedPTS = 0.0, audioPTS = 0.0, clockPTS = 0.0, videoClockError = 0.0, sourceFPS = 0.0
    var hasAudio: Bool?, audioRendering = false
    var error: String?, audioError: String?
}

/// The pipe reader only parses and places data in bounded inboxes. Native audio
/// startup has its own queue, so a slow output device cannot block picture delivery.
private final class PreviewPlayback: @unchecked Sendable {
    private let parser = PreviewPacketParser()
    private let lock = NSLock()
    private var inbox = PreviewInbox()
    private var stats = PreviewPlaybackStats()
    private var stopped = false, muted: Bool, audioBusy = false, audioReset = false
    private var latestImage: PreviewPicture?, deliveryPending = false
    private var pool: CVPixelBufferPool?, poolFormat = (width: 0, height: 0, format: OSType(0))
    private var latestPTS = 0.0
    private var latestWidth = 0, latestHeight = 0
    private let audioEnabled: Bool
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private let videoQueue = DispatchQueue(label: "app.setbeam.preview-picture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "app.setbeam.preview-sound", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var anchored = false
    private let onFrame: @Sendable (PreviewPicture) -> Void

    init(audioEnabled: Bool, muted: Bool, onFrame: @escaping @Sendable (PreviewPicture) -> Void) {
        self.audioEnabled = audioEnabled; self.muted = muted; self.onFrame = onFrame
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume()
    }
    func consume(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        do { try parser.consume(data) { inbox.append($0) } }
        catch { stats.error = "The local playback decoder sent invalid media. Reconnecting." }
    }
    func setMuted(_ value: Bool) {
        lock.lock(); muted = value
        audioReset = true
        if !value { stats.audioError = nil }; lock.unlock()
        // Do not place UI work behind audio-device initialization.
        audioQueue.async { [weak self] in self?.audioRenderer?.isMuted = value }
    }
    func snapshot() -> PreviewPlaybackStats {
        lock.lock(); defer { lock.unlock() }
        var result = stats
        result.videoQueueFrames = inbox.video.count; result.videoQueueBytes = inbox.videoBytes
        result.audioQueuePackets = inbox.audio.count; result.droppedVideoFrames = inbox.droppedVideo
        result.droppedAudioPackets = inbox.droppedAudio; result.decodedFrames = inbox.decodedFrames
        result.hasAudio = inbox.hasAudio
        result.sourceFPS = inbox.sourceFrameDuration > 0 ? 1 / inbox.sourceFrameDuration : 0
        return result
    }
    private func tick() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let clock = CMTimeGetSeconds(synchronizer.currentTime())
        if PreviewPlaybackTiming.needsAnchor(inbox, anchored: anchored, clock: clock), let latest = inbox.video.last {
            // Stream probing can deliver a buffered burst before steady live packets.
            // Anchor to current decoded media availability, and reset audio on that
            // same clock, rather than letting the startup burst leave sound late.
            synchronizer.setRate(1, time: CMTime(seconds: latest.seconds, preferredTimescale: 1_000_000),
                atHostTime: CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: PreviewPlaybackTiming.playoutDelay(for: latest), preferredTimescale: 1_000_000)))
            anchored = true; audioReset = true; inbox.acknowledgeDiscontinuity(); stats.clockResets += 1
        }
        let now = CMTimeGetSeconds(synchronizer.currentTime())
        let frame = anchored ? inbox.takeVideo(at: now) : nil
        let shouldAudio = anchored && audioEnabled && !audioBusy
        if shouldAudio { audioBusy = true }
        stats.clockPTS = now
        lock.unlock()
        if let frame, let image = makePicture(frame) {
            lock.lock()
            if latestImage != nil { stats.droppedPresentationFrames += 1 }
            latestImage = image; latestPTS = frame.seconds
            latestWidth = frame.width; latestHeight = frame.height
            let schedule = !deliveryPending; deliveryPending = true; lock.unlock()
            if schedule {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); let latest = self.stopped ? nil : self.latestImage
                    if latest != nil {
                        self.stats.presentedFrames += 1; self.stats.presentedPTS = self.latestPTS
                        self.stats.width = self.latestWidth; self.stats.height = self.latestHeight
                        self.stats.videoClockError = CMTimeGetSeconds(self.synchronizer.currentTime()) - self.latestPTS
                    }
                    self.latestImage = nil; self.deliveryPending = false; self.lock.unlock()
                    if let latest { self.onFrame(latest) }
                }
            }
        }
        if shouldAudio { audioQueue.async { [weak self] in self?.renderAudio() } }
    }
    private func renderAudio() {
        lock.lock()
        let isStopped = stopped, isMuted = muted, reset = audioReset; audioReset = false
        let now = CMTimeGetSeconds(synchronizer.currentTime())
        let packets = inbox.takeAudio(through: now + 0.25, staleBefore: now - 0.04)
        lock.unlock()
        defer { lock.lock(); audioBusy = false; lock.unlock() }
        guard !isStopped else { audioRenderer?.flush(); return }
        if reset {
            audioRenderer?.flush()
            if let renderer = audioRenderer, renderer.status == .failed {
                synchronizer.removeRenderer(renderer, at: .invalid, completionHandler: nil)
                audioRenderer = nil
            }
        }
        guard !isMuted else { audioRenderer?.isMuted = true; return }
        guard !packets.isEmpty || audioRenderer != nil else { return }
        if audioRenderer == nil {
            let renderer = AVSampleBufferAudioRenderer(); renderer.isMuted = true
            synchronizer.addRenderer(renderer); audioRenderer = renderer
        }
        guard let renderer = audioRenderer else { return }
        lock.lock(); let cancelled = stopped || muted; lock.unlock()
        guard !cancelled else { renderer.isMuted = true; renderer.flush(); return }
        renderer.isMuted = false
        for packet in packets {
            guard renderer.isReadyForMoreMediaData else { break }
            guard let buffer = makeAudioBuffer(packet) else { continue }
            renderer.enqueue(buffer)
            lock.lock(); stats.audioSamplesScheduled += packet.payload.count / 8
            stats.audioPTS = packet.seconds; lock.unlock()
        }
        lock.lock(); stats.audioRendering = renderer.status == .rendering
        if renderer.status == .failed { stats.audioError = "Local sound could not start. Check the Mac's sound output and try again. Video monitoring continues." }
        lock.unlock()
    }
    /// Runs on the picture queue only. Pooled IOSurfaces avoid mapping a new 12 MB surface per 4K frame.
    private func makePicture(_ frame: PreviewPacket) -> PreviewPicture? {
        let format = frame.flags & 1 != 0 ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if pool == nil || poolFormat != (frame.width, frame.height, format) {
            let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: format, kCVPixelBufferWidthKey: frame.width,
                                               kCVPixelBufferHeightKey: frame.height, kCVPixelBufferIOSurfacePropertiesKey: [:]]
            pool = nil; CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            poolFormat = (frame.width, frame.height, format)
        }
        var pixelBuffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        frame.payload.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            for plane in 0..<2 {
                let rows = plane == 0 ? frame.height : frame.height / 2
                let start = plane == 0 ? 0 : frame.width * frame.height
                guard let destination = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                if stride == frame.width { memcpy(destination, source.advanced(by: start), rows * frame.width); continue }
                for row in 0..<rows { memcpy(destination.advanced(by: row * stride), source.advanced(by: start + row * frame.width), frame.width) }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        let matrix = frame.matrix == 1 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : frame.matrix == 9 ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        let size = NSSize(width: Double(frame.width) * Double(frame.aspectNumerator) / Double(frame.aspectDenominator), height: Double(frame.height))
        return PreviewPicture(pixelBuffer: pixelBuffer, size: size)
    }
    private func makeAudioBuffer(_ packet: PreviewPacket) -> CMSampleBuffer? {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: packet.payload.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: packet.payload.count,
            flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = packet.payload.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: packet.payload.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: packet.payload.count / 8,
            presentationTimeStamp: CMTime(value: packet.timestamp, timescale: 1_000_000), packetDescriptions: nil,
            sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
    func stop() {
        lock.lock(); stopped = true; latestImage = nil; inbox.clearMedia(); lock.unlock()
        timer?.cancel(); timer = nil
        videoQueue.async { [self] in synchronizer.setRate(0, time: .invalid) }
        audioQueue.async { [self] in audioRenderer?.isMuted = true; audioRenderer?.flush(); audioRenderer = nil }
    }
    deinit { timer?.cancel() }
}
