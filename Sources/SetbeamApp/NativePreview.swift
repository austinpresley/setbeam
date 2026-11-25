import AppKit
import AVFoundation
import SetbeamCore

/// One timestamped decode of the private relay serves the main and floating windows.
/// Audio and picture use the same native playback clock. Audience controls never touch it.
@MainActor final class NativePreview: ObservableObject {
    @Published private(set) var picture: PreviewPicture?
    private var decoder: ManagedChild?
    private let retirementQueue = DispatchQueue(label: "app.setbeam.preview-retirement")
    private var playback: PreviewPlayback?
    private var url: String?
    private var directory: URL?
    // Observe this separately from the publisher revision. An automatic restart can
    // replace the decoder while the publisher and viewer link are still the same.
    @Published private(set) var decoderGeneration: UUID?
    private var pictureGeneration: UUID?
    private var lastFrameAt = Date.distantPast
    private var decoderStartedAt = Date.distantPast
    private var nextRetry = Date.distantPast
    private var soundRequestedAt: Date?
    private var soundFailureReported = false
    private var sourceReady = false
    private var watchdog: Task<Void, Never>?
    /// Decoder recovery must not reset the budget while old renderers retain buffers.
    private let pictureAllocations = PreviewBufferAllocations(limit: PreviewPicturePool.maximumBuffers)
    private let audioEnabled: Bool
    private let width: Int
    private let frameRate: Int
    private let tools: URL
    init(audioEnabled: Bool = true, width: Int = 0, frameRate: Int = 0, tools: URL = AppAssets.runtimePaths.tools) {
        self.tools = tools
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
        stop()
        let run = FileManager.default.temporaryDirectory.appendingPathComponent("Setbeam-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directory = run; self.url = url
        do { try startDecoder(url: url, directory: run) }
        catch { stop(); throw error }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self else { return }
                self.observeHealth()
            }
        }
    }

    func freshPicture(for generation: UUID) -> PreviewPicture? {
        guard decoderGeneration == generation, pictureGeneration == generation, pictureIsFresh(stats: diagnostics) else { return nil }
        return picture
    }

    private func pictureIsFresh(stats: PreviewPlaybackStats) -> Bool {
        picture != nil && Date().timeIntervalSince(lastFrameAt) < PreviewPlaybackTiming.freshnessInterval(sourceFPS: stats.sourceFPS)
    }

    private func startDecoder(url: String, directory: URL) throws {
        decoderGeneration = nil
        playback?.stop(); decoder?.stop(); decoder = nil
        lastFrameAt = .distantPast; pictureGeneration = nil; decoderStartedAt = Date()
        soundRequestedAt = muted ? nil : Date(); soundFailureReported = false
        let current = UUID()
        let output = PreviewPlayback(audioEnabled: audioEnabled, muted: muted, allocations: pictureAllocations) { [weak self] frame in
            guard let self, self.decoderGeneration == current else { return }
            self.pictureGeneration = current
            self.lastFrameAt = Date()
            self.picture = frame
        }
        playback = output
        var arguments = [url]
        if !audioEnabled { arguments.append("--silent") }
        if width > 0 { arguments += ["--width", String(width)] }
        if frameRate > 0 { arguments += ["--fps", String(frameRate)] }
        do {
            decoder = try ManagedChild(name: "Native playback", executable: tools.appendingPathComponent("setbeam-preview"),
                arguments: arguments, directory: directory, onOutput: { output.consume($0) })
        } catch { output.stop(); playback = nil; throw error }
        decoderGeneration = current
    }
    /// Upstream availability is an observation. Decoder recovery runs on our own watchdog.
    func checkHealth(sourceAvailable: Bool) { sourceReady = sourceAvailable; observeHealth() }
    private func observeHealth() {
        let stats = diagnostics
        let playing = pictureIsFresh(stats: stats)
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
           Date() >= nextRetry { retry() }
    }
    private func writeTelemetry(stats: PreviewPlaybackStats, playing: Bool) {
        let args = CommandLine.arguments
        guard audioEnabled, let index = args.firstIndex(of: "--native-preview-file"), index + 1 < args.count else { return }
        let floating = NSApp.windows.first { $0.title == "Setbeam Preview" }
        let visibleLayers = NSApp.windows.flatMap { window in
            window.contentView.map { Self.layerTelemetry(in: $0, window: window) } ?? []
        }
        let value: [String: Any] = ["visibleLayers": visibleLayers, "playing": playing, "ready": playing ? 4 : 0, "time": stats.presentedPTS,
            "frames": stats.publishedFrames, "publishedFrames": stats.publishedFrames, "decodedFrames": stats.decodedFrames, "renderer": "native-timestamped-nv12",
            "decoderRunning": decoder?.isRunning ?? false, "muted": muted, "audioOpening": !muted && !stats.audioRendering,
            "audioSamplesScheduled": stats.audioSamplesScheduled, "audioRendering": stats.audioRendering,
            "audioClockPTS": stats.audioClockPTS, "lastScheduledAudioPTS": stats.audioPTS,
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
    private static func layerTelemetry(in view: NSView, window: NSWindow) -> [[String: Any]] {
        if let layer = view as? PictureLayerView, layer.isVisibleForPlayback {
            return [["layer": String(describing: ObjectIdentifier(layer)), "window": window.windowNumber,
                "floating": window.title == "Setbeam Preview", "acceptedFrames": layer.acceptedFrames]]
        }
        return view.subviews.flatMap { layerTelemetry(in: $0, window: window) }
    }

    func retry() {
        guard let url, let directory else { return }
        nextRetry = Date().addingTimeInterval(3)
        do { try startDecoder(url: url, directory: directory) }
        catch { onPlaybackState?(false, Redaction.text(error.localizedDescription)) }
    }
    func stop(retireInBackground: Bool = false) {
        watchdog?.cancel(); watchdog = nil
        decoderGeneration = nil; pictureGeneration = nil
        nextRetry = .distantPast
        let retiredDecoder = decoder, retiredDirectory = directory
        playback?.stop(); playback = nil; decoder = nil
        directory = nil; url = nil; picture = nil; lastFrameAt = .distantPast; sourceReady = false
        let retire: @Sendable () -> Void = {
            retiredDecoder?.stop()
            if let retiredDirectory { try? FileManager.default.removeItem(at: retiredDirectory) }
        }
        if retireInBackground { retirementQueue.async(execute: retire) }
        else { retire() }
    }

    func waitForRetirement() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            retirementQueue.async { continuation.resume() }
        }
    }
}

struct PreviewPlaybackStats {
    var decodedFrames = 0, publishedFrames = 0, width = 0, height = 0
    // The probe's historical counter denotes publication to the UI actor.
    var presentedFrames: Int { publishedFrames }
    var videoQueueFrames = 0, videoQueueBytes = 0, audioQueuePackets = 0
    var droppedVideoFrames = 0, droppedAudioPackets = 0, droppedPresentationFrames = 0, audioSamplesScheduled = 0, clockResets = 0
    var presentedPTS = 0.0, audioPTS = 0.0, audioClockPTS = 0.0, clockPTS = 0.0, videoClockError = 0.0, sourceFPS = 0.0
    var hasAudio: Bool?, audioRendering = false
    var error: String?, audioError: String?
}

/// The pipe reader only parses and places data in bounded inboxes. Native audio
/// startup has its own queue, so a slow output device cannot block picture delivery.
private final class PreviewPlayback: @unchecked Sendable {
    private let parser = PreviewPacketParser()
    private let pipeLock = NSLock()
    // The pipe lock covers this value until the parser delivers the complete packet.
    private var recordAudioEpoch: UInt64?
    private let lock = NSLock()
    private var inbox = PreviewInbox()
    private var stats = PreviewPlaybackStats()
    private var stopped = false, muted: Bool, audioBusy = false
    private var audioAppliedEpoch: UInt64?
    private var latestImage: PreviewPicture?, deliveryPending = false
    private let pictures: PreviewPicturePool
    private var latestPTS = 0.0
    private var latestWidth = 0, latestHeight = 0
    private let audioEnabled: Bool
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private let videoQueue = DispatchQueue(label: "app.setbeam.preview-picture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "app.setbeam.preview-sound", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var anchor: (media: CMTime, host: CMTime)?
    private var audioClockPaused = false
    private let onFrame: @MainActor @Sendable (PreviewPicture) -> Void

    init(audioEnabled: Bool, muted: Bool, allocations: PreviewBufferAllocations, onFrame: @escaping @MainActor @Sendable (PreviewPicture) -> Void) {
        self.audioEnabled = audioEnabled; self.muted = muted; self.onFrame = onFrame
        pictures = PreviewPicturePool(allocations: allocations)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume()
    }
    func consume(_ data: Data) {
        // FileHandle delivers one stdout stream. Packet assembly uses its own lock;
        // only transferring a complete record needs the playback lock.
        pipeLock.lock(); defer { pipeLock.unlock() }
        do {
            try parser.consume(data, beganRecord: {
                lock.lock()
                recordAudioEpoch = muted || stopped ? nil : inbox.audioEpoch
                lock.unlock()
            }) { packet in
                lock.lock(); defer { lock.unlock() }
                guard !stopped, packet.kind != .audio || recordAudioEpoch == inbox.audioEpoch else { return }
                let epoch = inbox.audioEpoch
                inbox.append(packet)
                if epoch != inbox.audioEpoch { pauseAudioClock(); clearAudioStatus() }
            }
        } catch {
            lock.lock()
            if !stopped { stats.error = "The local playback decoder sent invalid media. Reconnecting." }
            lock.unlock()
        }
    }

    func setMuted(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        muted = value
        inbox.invalidateAudio()
        if value { pauseAudioClock() }
        clearAudioStatus()
        if !value { stats.audioError = nil }
    }

    private func clearAudioStatus() {
        stats.audioRendering = false
        stats.audioPTS = 0
    }

    // Keep advancing video on the host clock while the old audio renderer is
    // paused. Its queued PCM must be flushed before applying a new clock anchor.
    private func pauseAudioClock() {
        guard audioEnabled, anchor != nil, !audioClockPaused else { return }
        synchronizer.setRate(0, time: .invalid)
        audioClockPaused = true
    }

    private func playbackTime() -> Double {
        guard let anchor else { return 0 }
        let elapsed = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), anchor.host)
        return CMTimeGetSeconds(CMTimeAdd(anchor.media, elapsed))
    }

    func snapshot() -> PreviewPlaybackStats {
        lock.lock(); defer { lock.unlock() }
        var result = stats
        result.videoQueueFrames = inbox.video.count; result.videoQueueBytes = inbox.videoBytes
        result.audioQueuePackets = inbox.audio.count; result.droppedVideoFrames = inbox.droppedVideo
        result.droppedAudioPackets = inbox.droppedAudio; result.decodedFrames = inbox.decodedFrames
        if stats.audioRendering {
            let time = CMTimeGetSeconds(synchronizer.currentTime())
            if time.isFinite { result.audioClockPTS = time }
        }
        result.hasAudio = inbox.hasAudio
        result.sourceFPS = inbox.sourceFrameDuration > 0 ? 1 / inbox.sourceFrameDuration : 0
        return result
    }
    private func tick() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let clock = playbackTime()
        if PreviewPlaybackTiming.needsAnchor(inbox, anchored: anchor != nil, clock: clock), let latest = inbox.video.last {
            if anchor != nil {
                pauseAudioClock()
                inbox.invalidateAudio()
                clearAudioStatus()
            }
            // Probing can deliver a burst. Anchor both tracks to the newest
            // available picture so the burst does not leave monitoring behind.
            let host = CMClockGetTime(CMClockGetHostTimeClock())
            let delay = CMTime(seconds: PreviewPlaybackTiming.playoutDelay(for: latest), preferredTimescale: 1_000_000)
            let next = (media: CMTime(value: latest.timestamp, timescale: 1_000_000), host: CMTimeAdd(host, delay))
            anchor = next
            if !audioClockPaused { synchronizer.setRate(1, time: next.media, atHostTime: next.host) }
            inbox.acknowledgeDiscontinuity()
            stats.clockResets += 1
        }
        let now = playbackTime()
        let frame = anchor != nil ? inbox.takeVideo(at: now) : nil
        let shouldAudio = audioEnabled && !audioBusy &&
            (audioAppliedEpoch != inbox.audioEpoch || anchor != nil && !muted)
        if shouldAudio { audioBusy = true }
        stats.clockPTS = now
        lock.unlock()
        if shouldAudio { audioQueue.async { [weak self] in self?.renderAudio() } }
        if let frame, let image = pictures.makePicture(frame) {
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            if latestImage != nil { stats.droppedPresentationFrames += 1 }
            latestImage = image; latestPTS = frame.seconds
            latestWidth = frame.width; latestHeight = frame.height
            let schedule = !deliveryPending; deliveryPending = true; lock.unlock()
            if schedule {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); let latest = self.stopped ? nil : self.latestImage
                    if latest != nil {
                        self.stats.publishedFrames += 1; self.stats.presentedPTS = self.latestPTS
                        self.stats.width = self.latestWidth; self.stats.height = self.latestHeight
                        self.stats.videoClockError = self.playbackTime() - self.latestPTS
                    }
                    self.latestImage = nil; self.deliveryPending = false; self.lock.unlock()
                    if let latest { self.onFrame(latest) }
                }
            }
        } else if frame != nil {
            lock.lock(); stats.droppedPresentationFrames += 1; lock.unlock()
        }
    }
    private func renderAudio() {
        lock.lock()
        let epoch = inbox.audioEpoch
        let reset = audioAppliedEpoch != epoch
        let eligible = !stopped && !muted && anchor != nil && !inbox.discontinuity
        lock.unlock()
        defer { lock.lock(); audioBusy = false; lock.unlock() }

        if reset {
            audioRenderer?.isMuted = true
            audioRenderer?.flush()
            if let renderer = audioRenderer, renderer.status == .failed {
                synchronizer.removeRenderer(renderer, at: .invalid, completionHandler: nil)
                audioRenderer = nil
            }
            lock.lock()
            if !stopped, epoch == inbox.audioEpoch {
                audioAppliedEpoch = epoch
                if audioClockPaused, !inbox.discontinuity, let anchor {
                    let host = CMClockGetTime(CMClockGetHostTimeClock())
                    // AVFoundation expects the scheduled host time to be current or future.
                    let resumeHost = CMTimeMaximum(host, anchor.host)
                    let resumePTS = CMTimeAdd(anchor.media, CMTimeSubtract(resumeHost, anchor.host))
                    synchronizer.setRate(1, time: resumePTS, atHostTime: resumeHost)
                    audioClockPaused = false
                }
            }
            lock.unlock()
        }
        guard eligible else { return }
        if audioRenderer == nil {
            lock.lock()
            let hasPackets = !inbox.audio.isEmpty && epoch == inbox.audioEpoch && !stopped
            lock.unlock()
            guard hasPackets else { return }
            let renderer = AVSampleBufferAudioRenderer()
            renderer.isMuted = true
            synchronizer.addRenderer(renderer)
            audioRenderer = renderer
        }
        guard let renderer = audioRenderer else { return }
        var scheduled = false
        for _ in 0..<PreviewInbox.maximumAudioPackets {
            guard renderer.isReadyForMoreMediaData else { break }
            lock.lock()
            let now = playbackTime()
            let offer = !stopped && epoch == inbox.audioEpoch
                ? inbox.offerAudio(through: now + 0.25, staleBefore: now - 0.04) : nil
            lock.unlock()
            guard let offer else { break }
            let buffer = makeAudioBuffer(offer.packet)
            guard renderer.isReadyForMoreMediaData else { break }

            // Check again after allocation. A reset, mute, or queue eviction may have
            // superseded the packet. Only the final submission shares the epoch lock.
            lock.lock()
            let currentTime = playbackTime()
            if !stopped, epoch == inbox.audioEpoch,
               inbox.finishAudio(offer, staleBefore: currentTime - 0.04, dropped: buffer == nil), let buffer {
                renderer.enqueue(buffer)
                stats.audioSamplesScheduled += offer.packet.payload.count / 8
                stats.audioPTS = offer.packet.seconds
                scheduled = true
            }
            lock.unlock()
        }
        let status = renderer.status
        let rendererMuted = renderer.isMuted
        lock.lock()
        let current = !stopped && epoch == inbox.audioEpoch
        if current {
            if scheduled && rendererMuted { renderer.isMuted = false }
            stats.audioRendering = (!rendererMuted || scheduled) && status == .rendering
            if status == .failed { stats.audioError = "Local sound could not start. Check the Mac's sound output and try again. Video monitoring continues." }
        }
        lock.unlock()
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
        audioQueue.async { [self] in
            guard let renderer = audioRenderer else { return }
            renderer.isMuted = true
            renderer.flush()
            synchronizer.removeRenderer(renderer, at: .invalid, completionHandler: nil)
            audioRenderer = nil
        }
    }
    deinit { timer?.cancel() }
}
