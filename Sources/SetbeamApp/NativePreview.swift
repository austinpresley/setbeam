import AppKit
import AVFoundation
import ImageIO
import SetbeamCore

/// One local decode serves both native windows. Audience controls never touch it.
@MainActor final class NativePreview: ObservableObject {
    @Published private(set) var image: NSImage?
    private var video: ManagedChild?
    private var audio: ManagedChild?
    private var audioSink: PreviewAudio?
    private var audioOpening = false
    private var audioGeneration = UUID()
    private var audioStartup: Task<Void, Never>?
    private var jpeg: JPEGFrames?
    private var url: String?
    private var directory: URL?
    private var generation = UUID()
    private var lastFrameAt = Date.distantPast
    private var videoStartedAt = Date.distantPast
    private var frameCount = 0
    private var nextRetry = Date.distantPast
    private var sourceReady = false
    private let audioEnabled: Bool
    private let width: Int
    private let frameRate: Int
    init(audioEnabled: Bool = true, width: Int = 1280, frameRate: Int = 24) {
        self.audioEnabled = audioEnabled; self.width = width; self.frameRate = frameRate
    }
    var onPlaybackState: ((Bool, String?) -> Void)?
    var onSoundUnavailable: ((String) -> Void)?
    var muted = true { didSet { if oldValue != muted { configureAudio() } } }

    func start(url: String) throws {
        stop(); self.url = url
        let run = FileManager.default.temporaryDirectory.appendingPathComponent("Setbeam-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directory = run
        try startVideo(); configureAudio()
    }
    private func startVideo() throws {
        guard let url, let directory else { return }
        generation = UUID(); video?.stop(); video = nil
        lastFrameAt = .distantPast; videoStartedAt = Date()
        let current = generation
        let frames = JPEGFrames { [weak self] cgImage in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.image = NSImage(cgImage: cgImage, size: .zero)
                self.lastFrameAt = Date(); self.frameCount += 1
            }
        }
        jpeg = frames
        video = try ManagedChild(name: "Native preview", executable: AppAssets.runtimePaths.tools.appendingPathComponent("ffmpeg"),
            arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-analyzeduration", "500000", "-probesize", "1000000", "-rtsp_transport", "tcp", "-i", url,
                "-map", "0:v:0", "-an", "-vf", "fps=\(frameRate),scale=\(width):-2", "-c:v", "mjpeg", "-pix_fmt", "yuvj420p", "-q:v", "5", "-threads", "2", "-f", "image2pipe", "pipe:1"],
            directory: directory, onOutput: { frames.consume($0) })
    }
    private func configureAudio() {
        audioGeneration = UUID(); let current = audioGeneration
        audioStartup?.cancel(); audioStartup = nil
        audio?.stop(); audio = nil; audioSink?.stop(); audioSink = nil
        guard audioEnabled, !muted, sourceReady, Date().timeIntervalSince(lastFrameAt) < 2, let url, let directory else { return }
        guard !audioOpening else { onSoundUnavailable?("The audio device is still opening. Video monitoring continues."); return }
        audioOpening = true
        let sink = PreviewAudio(); audioSink = sink
        sink.start { [weak self] result in
            Task { @MainActor in
                guard let self else { sink.stop(); return }
                self.audioOpening = false
                guard self.audioGeneration == current else { sink.stop(); return }
                self.audioStartup?.cancel(); self.audioStartup = nil
                do {
                    try result.get()
                    self.audio = try ManagedChild(name: "Preview sound", executable: AppAssets.runtimePaths.tools.appendingPathComponent("ffmpeg"),
                        arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-analyzeduration", "500000", "-probesize", "1000000", "-rtsp_transport", "tcp", "-i", url,
                            "-vn", "-map", "0:a:0", "-ac", "1", "-ar", "48000", "-c:a", "pcm_s16le", "-f", "s16le", "pipe:1"],
                        directory: directory, onOutput: { sink.consume($0) })
                } catch { self.onSoundUnavailable?("Local sound could not start. Video monitoring continues.") }
            }
        }
        audioStartup = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, self.audioGeneration == current, self.audio == nil else { return }
            self.onSoundUnavailable?("The audio device did not respond. Check the Mac's sound output and try again. Video monitoring continues.")
        }
    }
    func checkHealth(sourceAvailable: Bool) {
        sourceReady = sourceAvailable
        let playing = image != nil && Date().timeIntervalSince(lastFrameAt) < 2
        onPlaybackState?(playing, playing ? nil : video?.recentError)
        if audioEnabled && sourceAvailable && playing && !muted && audio == nil && !audioOpening { configureAudio() }
        if !muted, let audio, !audio.isRunning {
            onSoundUnavailable?("This input did not provide local sound. Video monitoring continues.")
        }
        if sourceAvailable, (video?.isRunning != true || Date().timeIntervalSince(max(lastFrameAt, videoStartedAt)) > 8), url != nil, Date() >= nextRetry {
            nextRetry = Date().addingTimeInterval(3)
            try? startVideo()
        }
        let args = CommandLine.arguments
        if audioEnabled, let index = args.firstIndex(of: "--native-preview-file"), index + 1 < args.count {
            let floating = NSApp.windows.first { $0.title == "Setbeam Preview" }
            let value: [String: Any] = ["playing": playing, "ready": playing ? 4 : 0, "time": Double(frameCount) / 24, "frames": frameCount, "renderer": "native-jpeg", "decoderRunning": video?.isRunning ?? false,
                "muted": muted, "audioOpening": audioOpening, "audioSamplesScheduled": audioSink?.scheduledSampleCount ?? 0,
                "floatingVisible": floating?.isVisible ?? false, "floatingAboveNormal": (floating?.level.rawValue ?? 0) > NSWindow.Level.normal.rawValue]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                let destination = URL(fileURLWithPath: args[index+1]); try? data.write(to: destination, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
        }
    }
    func retry() {
        guard url != nil else { return }; nextRetry = .distantPast
        try? startVideo(); configureAudio()
    }
    func stop() {
        audioGeneration = UUID(); audioStartup?.cancel(); audioStartup = nil
        generation = UUID(); video?.stop(); video = nil; jpeg = nil
        audio?.stop(); audio = nil; audioSink?.stop(); audioSink = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil; url = nil; image = nil; lastFrameAt = .distantPast; frameCount = 0; sourceReady = false
    }
}

private final class JPEGFrames: @unchecked Sendable {
    private var buffer = Data()
    private let onFrame: @Sendable (CGImage) -> Void
    init(onFrame: @escaping @Sendable (CGImage) -> Void) { self.onFrame = onFrame }
    // FileHandle serializes calls from this one pipe.
    func consume(_ data: Data) {
        buffer.append(data)
        let start = Data([0xff, 0xd8]), end = Data([0xff, 0xd9])
        while let first = buffer.range(of: start), let last = buffer.range(of: end, in: first.upperBound..<buffer.endIndex) {
            let frame = Data(buffer[first.lowerBound..<last.upperBound]); buffer.removeSubrange(..<last.upperBound)
            if let source = CGImageSourceCreateWithData(frame as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { onFrame(image) }
        }
        if buffer.count > 4_000_000 { buffer.removeAll(keepingCapacity: true) }
    }
}

private final class PreviewAudio: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private let queue = DispatchQueue(label: "app.setbeam.preview-audio")
    private let lock = NSLock()
    private var queuedFrames = 0, scheduledFrames = 0
    private var stopped = false, ready = false
    private var remainder = Data()
    private var active: Bool { lock.lock(); defer { lock.unlock() }; return ready && !stopped }
    var scheduledSampleCount: Int { lock.lock(); defer { lock.unlock() }; return scheduledFrames }
    func start(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            do {
                let engine = AVAudioEngine(), player = AVAudioPlayerNode()
                engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
                try engine.start(); player.play()
                self.engine = engine; self.player = player
                lock.lock(); ready = true; let cancelled = stopped; lock.unlock()
                if cancelled { player.stop(); engine.stop() }
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }
    func consume(_ data: Data) {
        guard active else { return }
        queue.async { [self] in
            guard active, let player else { return }
            remainder.append(data)
            let count = remainder.count / 2
            guard count > 0 else { return }
            lock.lock(); let overloaded = queuedFrames > 12_000; lock.unlock()
            guard !overloaded else { remainder.removeAll(keepingCapacity: true); return }
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let channel = pcm.floatChannelData?[0] else { return }
            let bytes = [UInt8](remainder.prefix(count * 2))
            for index in 0..<count { channel[index] = Float(Int16(bitPattern: UInt16(bytes[index*2]) | UInt16(bytes[index*2+1]) << 8)) / 32768 }
            remainder.removeFirst(count * 2); pcm.frameLength = AVAudioFrameCount(count)
            lock.lock(); queuedFrames += count; scheduledFrames += count; lock.unlock()
            player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }; self.lock.lock(); self.queuedFrames -= count; self.lock.unlock()
            }
        }
    }
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        queue.async { [self] in player?.stop(); engine?.stop(); remainder.removeAll() }
    }
}
