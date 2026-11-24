import XCTest
import SetbeamCore
@testable import SetbeamApp

final class PreviewPlaybackTests: XCTestCase {
    private func video(_ pts: Int64, width: Int = 4, height: Int = 2) -> PreviewPacket {
        PreviewPacket(kind: .video, flags: 0, timestamp: pts, duration: 16_667, width: width, height: height,
            channels: 0, sampleRate: 0, aspectNumerator: 1, aspectDenominator: 1, matrix: 1,
            payload: Data(repeating: 128, count: width * height * 3 / 2))
    }
    private func audio(_ pts: Int64) -> PreviewPacket {
        PreviewPacket(kind: .audio, flags: 0, timestamp: pts, duration: 20_000, width: 0, height: 0,
            channels: 2, sampleRate: 48_000, aspectNumerator: 0, aspectDenominator: 1, matrix: 0,
            payload: Data(repeating: 0, count: 960 * 8))
    }
    private func encoded(_ packet: PreviewPacket) -> Data {
        var header = Data(repeating: 0, count: 64)
        header.replaceSubrange(0..<6, with: [83, 66, 80, 70, 1, 0]); header[6] = UInt8(packet.kind.rawValue)
        func put(_ value: UInt64, _ index: Int, _ count: Int) { for byte in 0..<count { header[index + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) } }
        put(UInt64(packet.payload.count), 8, 4); put(UInt64(packet.flags), 12, 4)
        put(UInt64(bitPattern: packet.timestamp), 16, 8); put(UInt64(bitPattern: packet.duration), 24, 8)
        put(UInt64(packet.width), 32, 4); put(UInt64(packet.height), 36, 4)
        put(UInt64(packet.channels), 40, 4); put(UInt64(packet.sampleRate), 44, 4)
        put(UInt64(packet.aspectNumerator), 48, 4); put(UInt64(packet.aspectDenominator), 52, 4)
        put(UInt64(packet.kind == .streams ? 0 : packet.kind.rawValue), 56, 4); put(UInt64(packet.matrix), 60, 4)
        return header + packet.payload
    }
    func testFragmentedInterleavedPacketsRetainDimensionsCadenceAndCommonTimestamps() throws {
        let expected = [video(9_000_000), audio(8_990_000), video(9_016_667)]
        let stream = expected.map(encoded).reduce(Data(), +)
        let parser = PreviewPacketParser(); var actual: [PreviewPacket] = []
        for byte in stream { try parser.consume(Data([byte])) { actual.append($0) } }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual[2].seconds - actual[0].seconds, 1.0 / 60, accuracy: 0.000001)
        XCTAssertEqual(actual[0].seconds - actual[1].seconds, 0.01, accuracy: 0.000001)
    }
    func testCoalescedStreamRecordsAndSlicedChunks() throws {
        let streams = PreviewPacket(kind: .streams, flags: 1, timestamp: 0, duration: 0, width: 0, height: 0,
            channels: 0, sampleRate: 0, aspectNumerator: 0, aspectDenominator: 1, matrix: 0, payload: Data())
        let frame = video(0, width: 1920, height: 1080)
        let bytes = Data([255]) + encoded(streams) + encoded(frame) + encoded(streams)
        let parser = PreviewPacketParser()
        var actual: [PreviewPacket] = [], recordStarts = 0
        for index in stride(from: 1, to: bytes.count, by: 65_536) {
            try parser.consume(bytes[index..<min(index + 65_536, bytes.count)], beganRecord: { recordStarts += 1 }) {
                actual.append($0)
            }
        }
        XCTAssertEqual(actual, [streams, frame, streams])
        XCTAssertEqual(recordStarts, 3)
    }

    func testInvalidVersionOversizedLengthAndInvalidFormatsFailClosed() {
        for mutation in [4, 8, 32, 56] {
            var record = encoded(video(0)); record[mutation] = 255
            let parser = PreviewPacketParser()
            XCTAssertThrowsError(try parser.consume(record) { _ in XCTFail("Invalid packet escaped") })
            XCTAssertTrue(parser.failed)
            XCTAssertThrowsError(try parser.consume(encoded(video(0))) { _ in XCTFail("Parser resumed after invalid data") })
        }
        var invalidAudio = encoded(audio(0)); invalidAudio[44] = 0
        XCTAssertThrowsError(try PreviewPacketParser().consume(invalidAudio) { _ in XCTFail("Invalid sample rate escaped") })
    }
    func testVideoWaitsForItsTimestampAndDropsSupersededPictures() {
        var inbox = PreviewInbox()
        for pts: Int64 in [0, 16_667, 33_334, 50_001] { inbox.append(video(pts)) }
        XCTAssertNil(inbox.takeVideo(at: -0.1))
        XCTAssertEqual(inbox.takeVideo(at: 0.034)?.timestamp, 33_334)
        XCTAssertEqual(inbox.droppedVideo, 2)
        XCTAssertEqual(inbox.video.first?.timestamp, 50_001)
    }
    func testSlowConsumerHasBoundedVideoMemoryAndAudioDuration() {
        var inbox = PreviewInbox()
        for index in 0..<100 { inbox.append(video(Int64(index) * 16_667, width: 1920, height: 1080)); inbox.append(audio(Int64(index) * 20_000)) }
        XCTAssertLessThanOrEqual(inbox.video.count, PreviewInbox.maximumVideoFrames)
        XCTAssertLessThanOrEqual(inbox.videoBytes, PreviewInbox.maximumVideoBytes)
        XCTAssertLessThanOrEqual(inbox.audio.last!.seconds + inbox.audio.last!.durationSeconds - inbox.audio.first!.seconds, 0.4 + 0.000001)
        XCTAssertGreaterThan(inbox.droppedVideo, 90)
        XCTAssertGreaterThan(inbox.droppedAudio, 70)
    }
    func testAudioUsesSourceTimeAndRejectsStaleSoundInsteadOfReplayingIt() {
        var inbox = PreviewInbox()
        for pts: Int64 in [0, 20_000, 40_000, 60_000] { inbox.append(audio(pts)) }
        let first = inbox.offerAudio(through: 0.045, staleBefore: 0.035)!
        XCTAssertEqual(first.packet.timestamp, 20_000)
        XCTAssertEqual(inbox.offerAudio(through: 0.045, staleBefore: 0.035)?.packet.timestamp, 20_000)
        XCTAssertTrue(inbox.finishAudio(first, staleBefore: 0.035))
        let second = inbox.offerAudio(through: 0.045, staleBefore: 0.035)!
        XCTAssertEqual(second.packet.timestamp, 40_000)
        XCTAssertTrue(inbox.finishAudio(second, staleBefore: 0.035))
        XCTAssertNil(inbox.offerAudio(through: 0.045, staleBefore: 0.035))
        XCTAssertEqual(inbox.droppedAudio, 1)
        XCTAssertEqual(inbox.audio.first?.timestamp, 60_000)
    }
    func testAudioOffersExpireOnEvictionResetAndMute() throws {
        var inbox = PreviewInbox()
        inbox.append(audio(0))
        let evicted = try XCTUnwrap(inbox.offerAudio(through: 0.25, staleBefore: -1))
        inbox.append(audio(1_000_000))
        XCTAssertFalse(inbox.finishAudio(evicted, staleBefore: -1))

        let reset = try XCTUnwrap(inbox.offerAudio(through: 1.25, staleBefore: 0.9))
        let epoch = inbox.audioEpoch
        inbox.invalidateAudio()
        inbox.append(audio(1_000_000))
        XCTAssertNotEqual(inbox.audioEpoch, epoch)
        XCTAssertFalse(inbox.finishAudio(reset, staleBefore: 0.9))
        let stale = try XCTUnwrap(inbox.offerAudio(through: 1.25, staleBefore: 0.9))
        XCTAssertFalse(inbox.finishAudio(stale, staleBefore: 1.1))
        XCTAssertTrue(inbox.audio.isEmpty)
    }

    func testSourceTimestampRestartFlushesBothQueues() {
        var inbox = PreviewInbox()
        inbox.append(video(10_000_000)); inbox.append(audio(10_000_000)); inbox.append(video(0))
        XCTAssertTrue(inbox.discontinuity)
        XCTAssertEqual(inbox.video.map(\.timestamp), [0]); XCTAssertTrue(inbox.audio.isEmpty)
        inbox.acknowledgeDiscontinuity(); XCTAssertFalse(inbox.discontinuity)
    }
    func testPlayoutDelayFitsInsideBoundedQueueAt1080p4KAnd8K60() {
        for size in [(1920, 1080), (3840, 2160), (7680, 4320)] {
            let frame = video(0, width: size.0, height: size.1)
            let depth = min(PreviewInbox.maximumVideoFrames, max(1, PreviewInbox.maximumVideoBytes / frame.payload.count))
            XCTAssertLessThanOrEqual(PreviewPlaybackTiming.playoutDelay(for: frame), Double(depth - 1) / 60)
        }
    }
    func testA4KClockBehindItsArrivalsStillPresentsPictures() {
        // A late arrival anchored the clock 150 ms behind, so later 4K pictures arrive that early.
        // Few 4K pictures fit the bounded queue; they must not all be evicted before they are due.
        var inbox = PreviewInbox()
        var offset = -0.15, presented = 0, next: Int64 = 0
        for step in 0..<250 {
            let now = Double(step) * 0.008
            while Double(next) / 1_000_000 <= now { inbox.append(video(next, width: 3840, height: 2160)); next += 16_667 }
            var clock = now + offset
            if PreviewPlaybackTiming.needsAnchor(inbox, anchored: true, clock: clock), let latest = inbox.video.last {
                offset = latest.seconds - PreviewPlaybackTiming.playoutDelay(for: latest) - now; clock = now + offset
                inbox.acknowledgeDiscontinuity()
            }
            if inbox.takeVideo(at: clock) != nil { presented += 1 }
        }
        XCTAssertGreaterThan(presented, 100, "120 pictures arrived in two seconds")
    }
    func testClockRecoversFromBufferedStartupWithoutTreatingOrdinaryFrameCadenceAsAnOutage() {
        let frame = video(1_000_000)
        XCTAssertTrue(PreviewPlaybackTiming.arrivedTooLate(frame, clock: 1.14))
        XCTAssertFalse(PreviewPlaybackTiming.arrivedTooLate(frame, clock: 1.02))
        XCTAssertFalse(PreviewPlaybackTiming.arrivedTooLate(frame, clock: 0.96))
        XCTAssertLessThanOrEqual(PreviewPlaybackTiming.playoutDelay(for: frame), 0.04)
    }

    @MainActor func testNativePlaybackClockAndCadenceThroughActualPrivateRTSPRelay() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let environment = ProcessInfo.processInfo.environment
        let tools = environment["SETBEAM_TEST_TOOLS"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Vendor/bin")
        let fixtures = environment["SETBEAM_TEST_FIXTURES"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Fixtures")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("setbeam-preview").path) else {
            throw XCTSkip("Build the bundled playback bridge before native RTSP integration.")
        }
        let runtime = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        let player = NativePreview(tools: tools)
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            let deadline = Date().addingTimeInterval(15)
            while !(await runtime.snapshot()).sourceAvailable && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            let source = await runtime.snapshot()
            XCTAssertTrue(source.sourceAvailable)
            let url = await runtime.localRTSP()
            try player.start(url: url)
            let generation = try XCTUnwrap(player.decoderGeneration)
            XCTAssertNil(player.freshPicture(for: generation))
            player.checkHealth(sourceAvailable: true)
            let playbackDeadline = Date().addingTimeInterval(10)
            while player.diagnostics.presentedFrames < 12 && Date() < playbackDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
            let before = player.diagnostics
            XCTAssertGreaterThanOrEqual(before.presentedFrames, 12)
            let started = ContinuousClock.now
            var errors: [Double] = []
            for _ in 0..<50 {
                try await Task.sleep(nanoseconds: 50_000_000)
                errors.append(abs(player.diagnostics.videoClockError))
            }
            let elapsed = started.duration(to: .now)
            let after = player.diagnostics
            print("Native RTSP playback: \(after.width)x\(after.height), \(String(format: "%.3f", after.sourceFPS)) fps, \(after.presentedFrames - before.presentedFrames) frames over \(elapsed), max presentation/clock difference \(String(format: "%.2f", (errors.max() ?? 0) * 1000))ms, \(after.clockResets) shared-clock anchors")
            XCTAssertEqual(after.width, 1280); XCTAssertEqual(after.height, 720)
            XCTAssertEqual(after.sourceFPS, 24, accuracy: 0.05)
            XCTAssertGreaterThan(after.presentedFrames - before.presentedFrames, 45)
            XCTAssertLessThan(try XCTUnwrap(errors.max()), 0.08, "Native presentation must remain near the shared A/V clock after RTSP probing settles.")
            XCTAssertLessThanOrEqual(after.videoQueueFrames, PreviewInbox.maximumVideoFrames)
            XCTAssertNotNil(player.freshPicture(for: generation))
            player.retry()
            let replacement = try XCTUnwrap(player.decoderGeneration)
            XCTAssertNotEqual(replacement, generation)
            XCTAssertNil(player.freshPicture(for: generation))
            XCTAssertNil(player.freshPicture(for: replacement))
            let resumed = Date().addingTimeInterval(10)
            while player.freshPicture(for: replacement) == nil && Date() < resumed {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertNotNil(player.freshPicture(for: replacement))
            player.stop()
            XCTAssertNil(player.decoderGeneration)
            XCTAssertNil(player.freshPicture(for: replacement))
            await runtime.shutdown()
        } catch { player.stop(); await runtime.shutdown(); throw error }
    }
}
