import Foundation
import SetbeamCore

extension SetbeamProbe {
    /// Expect the decoded holding artwork itself and prove motion independently on the private relay.
    static func verifyHold(runtime: MediaRuntime, tools: URL, fixtures: URL, directory: URL, maximumHoldPeak: Int = 7, resume: Bool = true) async throws {
        let evidence = directory.appendingPathComponent("hold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        print("Hold evidence directory: \(evidence.path)")
        let ffmpeg = tools.appendingPathComponent("ffmpeg")
        let common = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"]
        let input = ["-rtsp_transport", "tcp", "-i"]
        // Video can start after audio while the reader waits for a keyframe. Start
        // each measurement at the first decoded sample of its own track.
        // Hash the native-size planes. Scaling can change chroma rounding
        // between file and RTSP decodes of the same pixels.
        let picture = ["-map", "0:v:0", "-vf", "setpts=PTS-STARTPTS,format=yuv420p", "-fps_mode", "passthrough",
                       "-c:v", "rawvideo", "-f", "framemd5"]
        // Count decoded PCM samples on a continuous clock. RTP gaps must never
        // shorten the sample window or be padded with zeros.
        let pcm = ["-map", "0:a:0", "-af", "asetpts=N/SR/TB", "-ac", "2", "-ar", "48000", "-c:a", "pcm_s16le", "-f", "s16le"]

        @Sendable func hashes(_ data: Data) -> [String] {
            String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                .filter { !$0.hasPrefix("#") }
                .compactMap { $0.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) }
        }
        let reference = evidence.appendingPathComponent("bundled-hold.framemd5")
        _ = try await run(tools: tools, args: common + ["-i", fixtures.appendingPathComponent("Hold.mp4").path] + picture + [reference.path],
                          directory: directory)
        let referenceFrames = hashes(try Data(contentsOf: reference))
        let expected = Set(referenceFrames)
        guard referenceFrames.count >= 24 else {
            throw SetbeamError.runtime("Could not decode a full second of the bundled Hold fixture.")
        }
        @Sendable func capture(_ name: String, url: String) async throws -> (frames: [String], peak: Int) {
            let video = evidence.appendingPathComponent("\(name).framemd5")
            let audio = evidence.appendingPathComponent("\(name).pcm")
            _ = try await run(tools: tools, args: common + input + [url] +
                ["-t", "2"] + picture + [video.path] + ["-t", "2"] + pcm + [audio.path], directory: directory)
            let frames = hashes(try Data(contentsOf: video))
            guard frames.count >= 40 else {
                throw SetbeamError.runtime("\(name) decoded only \(frames.count) frames in the two-second window.")
            }
            let peak = try pcmPeak(at: audio, samples: 2 * 48_000 * 2)
            print("Hold evidence: \(name), \(frames.count) decoded frames, \(Set(frames).count) distinct, 96000 stereo PCM frames, peak \(peak)")
            return (frames, peak)
        }
        @Sendable func expectSource(_ name: String, url: String) async throws {
            let observed = try await capture(name, url: url)
            guard Set(observed.frames).count >= 4, expected.isDisjoint(with: observed.frames), observed.peak > 100 else {
                throw SetbeamError.runtime("\(name) did not decode the moving source with audible PCM.")
            }
        }
        func wait(_ message: String, seconds: Double, _ predicate: () async -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < deadline {
                if await predicate() { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw SetbeamError.runtime(message)
        }

        try await wait("Live output did not start for Hold proof.", seconds: 20) { await runtime.snapshot().audienceAvailable }
        let live = await runtime.snapshot()
        var guest = URLComponents(string: await runtime.localRTSP("live"))!
        guest.user = "guest"; guest.password = live.guestToken
        let guestURL = guest.string!
        try await expectSource("before-hold", url: guestURL)
        let attached = try ManagedChild(name: "Already-attached audience decoder", executable: ffmpeg,
            arguments: common + input + [guestURL, "-progress", "pipe:1", "-t", "60", "-f", "null", "-"], directory: directory)
        defer { attached.stop() }
        let attachedPID = attached.processID
        try await wait("The already-attached guest did not decode live video.", seconds: 10) {
            attached.isRunning && attached.lastVideoFrameAt != nil
        }
        try await runtime.setHold(true)
        try await wait("The old live reader stayed attached after Hold.", seconds: 5) { !attached.isRunning }
        print("PASS: already-decoding RTSP guest group \(attachedPID) disconnected when Hold replaced the publisher")
        try await wait("Hold output did not become ready.", seconds: 15) {
            let state = await runtime.snapshot()
            return state.session.holding && state.audienceAvailable && state.audienceRevision > live.audienceRevision
        }
        let before = await runtime.snapshot()
        async let fresh = capture("fresh-hold-guest", url: guestURL)
        async let local: Void = expectSource("private-during-hold", url: await runtime.localRTSP())
        let held = try await fresh
        try await local
        let after = await runtime.snapshot()
        guard Set(held.frames).isSubset(of: expected) else {
            throw SetbeamError.runtime("A held frame differed from the decoded bundled Hold picture. Compare the framemd5 files in \(evidence.path).")
        }
        guard held.peak <= maximumHoldPeak else {
            throw SetbeamError.runtime("The held PCM peak was \(held.peak), above the limit \(maximumHoldPeak).")
        }
        guard after.session.holding, after.audienceAvailable, after.audienceRevision == before.audienceRevision,
              after.sourceAvailable, let start = before.lastFrameAt, let end = after.lastFrameAt, end > start else {
            throw SetbeamError.runtime("The held publisher changed revision or the private source stopped advancing during capture.")
        }
        print("PASS: a new RTSP guest decoded the bundled holding picture and silent stereo PCM while the private feed kept moving with audio")
        guard resume else { return }
        try await runtime.setHold(false)
        try await wait("Resume output did not become ready.", seconds: 20) {
            let state = await runtime.snapshot()
            return !state.session.holding && state.audienceAvailable && state.audienceRevision > after.audienceRevision
        }
        try await expectSource("resumed-guest", url: guestURL)
        print("PASS: Resume restores moving source video and audio to the same guest credential")
    }

    static func pcmPeak(at file: URL, samples: Int) throws -> Int {
        let bytes = [UInt8](try Data(contentsOf: file))
        guard bytes.count == samples * 2 else {
            throw SetbeamError.runtime("Expected \(samples) PCM samples, decoded \(bytes.count / 2) (\(bytes.count) bytes).")
        }
        return stride(from: 0, to: bytes.count, by: 2).reduce(0) { peak, i in
            max(peak, abs(Int(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8))))
        }
    }
}
