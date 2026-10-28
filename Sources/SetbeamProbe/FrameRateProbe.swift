import Foundation
import SetbeamCore

extension SetbeamProbe {
    /// Decodes real relay frames, rather than trusting an encoder's nominal rate metadata.
    static func testFrameRates(tools: URL, fixtures: URL, output: URL) async throws {
        let runtime = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        let receiver = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        func waitFor(_ engine: MediaRuntime, _ predicate: (RuntimeSnapshot) -> Bool) async throws -> RuntimeSnapshot {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                let value = await engine.snapshot()
                if predicate(value) { return value }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            throw SetbeamError.runtime("Frame-rate check did not reach the expected state. \(await engine.diagnosticStatus())")
        }
        func verify(_ engine: MediaRuntime, path: String, expectedFPS: Double) async throws {
            let packets = Int(ceil(expectedFPS * 3)) + 4
            let data = try await run(tools: tools, args: ["-v", "error", "-analyzeduration", "2000000", "-fpsprobesize", "0", "-max_ts_probe", "0", "-probesize", "1000000",
                "-threads:v", "2", "-thread_type:v", "slice", "-rtsp_transport", "tcp", "-select_streams", "v:0", "-read_intervals", "%+#\(packets)",
                "-show_frames", "-show_entries", "frame=best_effort_timestamp_time,width,height", "-of", "json",
                await engine.localRTSP(path)], directory: output, executable: "ffprobe", timeout: 16)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            try data.write(to: output.appendingPathComponent("fps-\(path)-\(Int(expectedFPS))-timing.json"), options: .atomic)
            let frames = json?["frames"] as? [[String: Any]] ?? []
            // RTSP can deliver an untimed first picture and adjust its initial RTP clock
            // anchor. Measure the subsequent presentation intervals, including at 1 fps.
            let pts = Array(frames.compactMap { ($0["best_effort_timestamp_time"] as? String).flatMap(Double.init) }.dropFirst(2))
            guard let first = pts.first, let last = pts.last, last - first >= 1.9, pts.count >= 3,
                  frames.allSatisfy({ $0["width"] as? Int == 1280 && $0["height"] as? Int == 720 }) else {
                throw SetbeamError.runtime("The \(path) frame-rate check did not decode a full-size picture over two seconds.")
            }
            let rate = Double(pts.count - 1) / (last - first)
            let intervals = zip(pts.dropFirst(), pts).map(-)
            // All these paths originate in Demo.mp4. Its AAC priming adds 1024/48000
            // seconds at each loop, which Match source correctly retains in the video.
            let maximumGap = max(1.5 / expectedFPS, 1 / expectedFPS + 1024.0 / 48000 + 0.001)
            guard abs(rate - expectedFPS) / expectedFPS < 0.03,
                  intervals.allSatisfy({ $0 > 0 && $0 < maximumGap }) else {
                throw SetbeamError.runtime("Expected \(expectedFPS) fps on \(path), decoded \(rate) fps with largest gap \(intervals.max() ?? 0).")
            }
            print("PASS: \(path) decodes \(String(format: "%.3f", rate)) fps at unchanged 1280x720 dimensions")
        }
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            _ = try await waitFor(runtime) { $0.sourceAvailable }
            let sourcePIDs = await runtime.processIDs()
            await runtime.setVideoSettings(quality: .light, frameRate: .fps1)
            _ = try await runtime.startSharing()
            let original = try await waitFor(runtime) { $0.sourceAvailable && $0.audienceAvailable }
            try await verify(runtime, path: "live", expectedFPS: 1)
            try await verify(runtime, path: "local", expectedFPS: 24)
            guard Array((await runtime.processIDs()).prefix(2)) == sourcePIDs else {
                throw SetbeamError.runtime("Viewer FPS changed the server or local source publisher.")
            }
            // Cross both watchdog thresholds without decoded-frame reads or UI activity.
            try await Task.sleep(nanoseconds: 14_000_000_000)
            let stable = await runtime.snapshot()
            guard stable.sourceAvailable, stable.audienceAvailable, stable.audienceRevision == original.audienceRevision else {
                throw SetbeamError.runtime("Healthy 1 fps output triggered recovery.")
            }
            print("PASS: 1 fps remains healthy beyond the watchdog thresholds without a publisher restart")

            await runtime.setVideoSettings(frameRate: .fps5)
            _ = try await waitFor(runtime) { $0.audienceAvailable && $0.audienceRevision > original.audienceRevision }
            try await verify(runtime, path: "live", expectedFPS: 5)
            try await runtime.setHold(true)
            let held = try await waitFor(runtime) { $0.audienceAvailable }
            let holdingPID = await runtime.processIDs().last
            await runtime.setVideoSettings(quality: .best, frameRate: .fps1, screenFrameRate: .fps1)
            let afterSettings = await runtime.snapshot()
            guard afterSettings.session.holding, afterSettings.audienceRevision == held.audienceRevision,
                  await runtime.processIDs().last == holdingPID else {
                throw SetbeamError.runtime("Changing FPS disturbed the running holding output.")
            }
            let holdAudio = try await audioPeak(runtime: runtime, tools: tools, directory: output, name: "fps-hold")
            guard holdAudio < 8 else { throw SetbeamError.runtime("Source audio leaked through Hold after an FPS change.") }
            try await runtime.setHold(false)
            _ = try await waitFor(runtime) { $0.audienceAvailable && !$0.session.holding }
            try await verify(runtime, path: "live", expectedFPS: 1)
            let liveAudio = try await audioPeak(runtime: runtime, tools: tools, directory: output, name: "fps-live")
            guard liveAudio > 100 else { throw SetbeamError.runtime("Lower viewer FPS removed source audio.") }
            guard (await runtime.snapshot()).guestToken == original.guestToken,
                  Array((await runtime.processIDs()).prefix(2)) == sourcePIDs else {
                throw SetbeamError.runtime("FPS changes replaced the viewing identity or local source.")
            }
            print("PASS: live FPS/bitrate changes retain the source and viewing identity; Hold stays silent and Resume restores audio")

            // A receiver capped above an already slow source must not invent extra frames.
            await receiver.setVideoSettings(frameRate: .fps30)
            _ = try await receiver.prepare(source: .network(await runtime.localRTSP("live")), viewerAddress: "127.0.0.1")
            _ = try await waitFor(receiver) { $0.sourceAvailable }
            _ = try await receiver.startSharing()
            _ = try await waitFor(receiver) { $0.audienceAvailable }
            try await verify(receiver, path: "live", expectedFPS: 1)
            await receiver.shutdown()

            await runtime.setVideoSettings(frameRate: .source)
            _ = try await waitFor(runtime) { $0.audienceAvailable }
            try await verify(runtime, path: "live", expectedFPS: 24)
            await runtime.stopSharing()
            guard (await runtime.snapshot()).sourceAvailable else { throw SetbeamError.runtime("Stop Sharing interrupted local monitoring.") }
            let pids = await runtime.processIDs()
            await runtime.shutdown()
            guard pids.allSatisfy({ kill($0, 0) != 0 }) else { throw SetbeamError.runtime("FPS check left owned media processes running.") }
            print("PASS: Match source restores 24 fps; Stop Sharing preserves local monitoring and shutdown cleans owned processes")
        } catch { await receiver.shutdown(); await runtime.shutdown(); throw error }
    }
}
