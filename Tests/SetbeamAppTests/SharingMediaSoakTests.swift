import Darwin
import SetbeamCore
import XCTest
@testable import SetbeamApp

/// Headless companion to SharingMemorySoakTests. Run with scripts/check-sharing-soak.sh.
final class SharingMediaSoakTests: XCTestCase {
    @MainActor func testRealMediaEndurance() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let setting = env["SETBEAM_REAL_MEDIA_SECONDS"] else {
            throw XCTSkip("Opt in with scripts/check-sharing-soak.sh SECONDS.")
        }
        guard let seconds = Int(setting), (30...14400).contains(seconds),
              let output = env["SETBEAM_REAL_MEDIA_REPORT_DIR"], let node = env["SETBEAM_REAL_MEDIA_NODE"] else {
            throw SetbeamError.runtime("Use scripts/check-sharing-soak.sh with 30 to 14400 seconds of live playback.")
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let tools = env["SETBEAM_TEST_TOOLS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppAssets.runtimePaths.tools
        let fixtures = env["SETBEAM_TEST_FIXTURES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppAssets.runtimePaths.fixtures
        let report = URL(fileURLWithPath: output, isDirectory: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Setbeam-soak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sample = scratch.appendingPathComponent("Demo.mp4")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("Hold.mp4"),
                                         to: scratch.appendingPathComponent("Hold.mp4"))
        let log = SessionLog()
        log.configure(directory: report.appendingPathComponent("runtime-log"))
        let runtime = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: scratch), log: log)
        let gateway = ViewerGateway(assets: AppAssets.viewerAssets)
        let preview = NativePreview(audioEnabled: false, tools: tools)
        let evidenceURL = report.appendingPathComponent("mac.ndjson")
        try Data().write(to: evidenceURL)
        let evidence = try FileHandle(forWritingTo: evidenceURL)
        defer { try? evidence.close() }
        let control = scratch.appendingPathComponent("control.json")
        let ack = scratch.appendingPathComponent("browser-ack.json")
        let clock = ContinuousClock(), began = clock.now
        let timestamps = ISO8601DateFormatter()
        timestamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let MiB: UInt64 = 1024 * 1024
        var browser: ManagedChild?
        var observations: Task<Void, Never>?
        var link = ""
        var step = 0
        var phase = "setup"
        var observedPIDs: [pid_t: Int64] = [:]
        var warmupPeak: UInt64 = 0
        var lastMemorySample = clock.now

        func record(_ event: String, _ fields: [String: Any] = [:]) throws {
            var row = fields
            row["event"] = event
            row["at"] = timestamps.string(from: Date())
            row["step"] = step
            row["phase"] = phase
            var data = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
            data.append(10)
            try evidence.write(contentsOf: data)
        }
        func changePhase(_ next: String) throws {
            step += 1
            phase = next
            let value: [String: Any] = ["url": link, "pid": getpid(), "phase": phase, "step": step, "duration": seconds]
            try JSONSerialization.data(withJSONObject: value).write(to: control, options: .atomic)
            try record("phase")
            print("SOAK \(phase)")
            fflush(stdout)
        }
        func wait(_ timeout: Int = 30, _ failure: String, condition: () async throws -> Bool) async throws {
            let deadline = clock.now + .seconds(timeout)
            while clock.now < deadline {
                if try await condition() { return }
                if let browser, !browser.isRunning, phase != "stop" {
                    throw SetbeamError.runtime("Browser check exited in \(phase): \(browser.recentError)")
                }
                if warmupPeak > 0, lastMemorySample.duration(to: clock.now) >= .seconds(5) {
                    _ = try await sampleMemory()
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw SetbeamError.runtime(failure)
        }
        func browserVerified() -> Bool {
            guard let data = try? Data(contentsOf: ack),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return false }
            return value["step"] == step
        }
        func ffmpeg(_ arguments: [String], _ operation: String) async throws {
            let child = try ManagedChild(name: operation, executable: tools.appendingPathComponent("ffmpeg"),
                arguments: ["-nostdin", "-hide_banner", "-loglevel", "error"] + arguments, directory: scratch)
            defer { child.stop() }
            try await wait(30, "\(operation) timed out.") { !child.isRunning }
            guard child.terminationStatus == 0 else {
                throw SetbeamError.runtime("\(operation) failed: \(child.recentError)")
            }
        }
        func audioPeak(_ label: String, silent: Bool) async throws {
            // Check both channels across the complete half-second capture.
            let pcm = scratch.appendingPathComponent("audio.pcm")
            defer { try? FileManager.default.removeItem(at: pcm) }
            let audience = await runtime.localRTSP("live")
            try await ffmpeg(["-y", "-rtsp_transport", "tcp", "-i", audience, "-map", "0:a:0", "-t", "0.5",
                "-ac", "2", "-ar", "48000", "-c:a", "pcm_s16le", "-f", "s16le", pcm.path], label)
            let bytes = [UInt8](try Data(contentsOf: pcm))
            let peak = stride(from: 0, to: bytes.count - 1, by: 2).reduce(0) { peak, index in
                let sample = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
                return max(peak, abs(Int(sample)))
            }
            try record("outgoingAudio", ["label": label, "samples": bytes.count / 2, "channels": 2, "sampleRate": 48_000, "peakS16": peak])
            guard bytes.count == 24_000 * 2 * 2, silent ? peak < 8 : peak > 100 else {
                throw SetbeamError.runtime("\(label) decoded \(bytes.count / 2) audio samples at peak \(peak).")
            }
        }
        func mediaPIDs() throws -> [pid_t] {
            let browserPID = browser?.processID
            let pids = try SoakProcess.children(getpid()).filter { $0 != browserPID }
            return try pids + pids.flatMap { try SoakProcess.descendants($0) }
        }
        func sampleMemory() async throws -> UInt64 {
            lastMemorySample = clock.now
            let pids = try mediaPIDs()
            var helpers: UInt64 = 0
            for pid in pids {
                guard let start = MacProcess.startTime(pid) else { continue }
                observedPIDs[pid] = start
                if let footprint = try? SoakProcess.footprint(pid) { helpers += footprint }
                else if MacProcess.startTime(pid) == start { throw SetbeamError.runtime("Could not sample helper \(pid).") }
            }
            let host = try SoakProcess.footprint(getpid())
            let video = preview.diagnostics
            let snapshot = await runtime.snapshot()
            try record("sample", ["hostBytes": host, "helperBytes": helpers, "mediaPIDs": pids,
                "width": video.width, "height": video.height, "presentedFrames": video.presentedFrames,
                "queueBytes": video.videoQueueBytes, "sourceAvailable": snapshot.sourceAvailable,
                "audienceAvailable": snapshot.audienceAvailable, "audienceRevision": snapshot.audienceRevision,
                "viewers": gateway.viewers.count])
            guard host < 1024 * MiB, helpers < 1536 * MiB, video.videoQueueBytes <= PreviewInbox.maximumVideoBytes else {
                throw SetbeamError.runtime("Mac footprint or native decode queue exceeded its limit.")
            }
            if phase != "warmup", warmupPeak > 0, host >= warmupPeak + 96 * MiB {
                throw SetbeamError.runtime("Mac host grew beyond its warm-up peak by 96 MiB.")
            }
            return host
        }
        func secondsBetween(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: end).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
        func stall(_ role: String, publisherIndex: Int) async throws {
            let before = await runtime.snapshot()
            let owned = await runtime.processIDs()
            guard owned.count == 3 else { throw SetbeamError.runtime("Expected a server and two owned publishers.") }
            let supervisor = owned[publisherIndex]
            let children = try SoakProcess.children(supervisor)
            guard try SoakProcess.children(getpid()).contains(supervisor), children.count == 1,
                  let helper = children.first, getpgid(helper) == supervisor,
                  let identity = MacProcess.startTime(helper) else {
                throw SetbeamError.runtime("Could not identify the owned \(role) helper.")
            }
            let priorFrames = preview.diagnostics.presentedFrames
            try changePhase("stall")
            // Leave the supervisor running so parent-exit cleanup still works during SIGSTOP.
            guard MacProcess.startTime(helper) == identity, getpgid(helper) == supervisor, kill(helper, SIGSTOP) == 0 else {
                throw SetbeamError.runtime("Could not pause the owned \(role) helper.")
            }
            let since = clock.now
            try record("helperPaused", ["role": role, "helperPID": helper, "supervisorPID": supervisor])
            var unavailableAt: ContinuousClock.Instant?
            var recoveredAt: ContinuousClock.Instant?
            try await wait(35, "The \(role) stall did not become unavailable and recover.") {
                let snapshot = await runtime.snapshot()
                if unavailableAt == nil, !(role == "source" ? snapshot.sourceAvailable : snapshot.audienceAvailable) {
                    let now = clock.now
                    unavailableAt = now
                    try record("publisherUnavailable", ["role": role, "sincePauseSeconds": secondsBetween(since, now)])
                }
                if role == "audience", !snapshot.sourceAvailable {
                    throw SetbeamError.runtime("An audience stall interrupted private monitoring.")
                }
                let pids = await runtime.processIDs()
                if recoveredAt == nil, unavailableAt != nil, snapshot.session.audience == .live,
                   snapshot.guestToken == before.guestToken, snapshot.audienceRevision > before.audienceRevision,
                   pids.count == 3, pids[publisherIndex] != supervisor, MacProcess.startTime(helper) != identity {
                    recoveredAt = clock.now
                }
                return recoveredAt != nil && browserVerified()
            }
            guard let recoveredAt, let unavailableAt else {
                throw SetbeamError.runtime("Missing the observed \(role) outage or recovery timestamp.")
            }
            guard since.duration(to: recoveredAt) >= .seconds(8) else {
                throw SetbeamError.runtime("The \(role) recovered after \(secondsBetween(since, recoveredAt)) seconds, below the eight-second stall floor.")
            }
            try changePhase("recover")
            try await wait(35, "The viewers did not decode moving video after the \(role) stall.") { browserVerified() }
            try await verifyPrivateFrames()
            if role == "audience", preview.diagnostics.presentedFrames <= priorFrames {
                throw SetbeamError.runtime("Private frames did not advance while the audience publisher recovered.")
            }
            let replacement = await runtime.processIDs()
            guard replacement.count == 3 else { throw SetbeamError.runtime("Publisher missing after \(role) recovery.") }
            try record("helperRecovered", ["role": role, "oldSupervisorPID": supervisor,
                "newSupervisorPID": replacement[publisherIndex], "pauseToRecoverySeconds": secondsBetween(since, recoveredAt),
                "observedUnavailableToRecoverySeconds": secondsBetween(unavailableAt, recoveredAt)])
        }
        func verifyPrivateFrames() async throws {
            let before = preview.diagnostics.presentedFrames
            try await Task.sleep(for: .seconds(2))
            let video = preview.diagnostics
            guard video.presentedFrames > before, video.width == 1920, video.height == 1080,
                  await runtime.snapshot().sourceAvailable else {
                throw SetbeamError.runtime("Private 1080p frames stopped advancing in \(phase).")
            }
            try record("privateFrames", ["before": before, "after": video.presentedFrames])
        }
        func shutdown() async {
            observations?.cancel()
            await observations?.value
            gateway.stop()
            preview.stop()
            await runtime.shutdown()
        }

        do {
            try record("started", ["targetLiveSeconds": seconds, "fixture": "testsrc2 1920x1080/30 with 440 Hz tone"])
            // Same generated moving screen pattern and tone used in check-preview-bridge.py.
            try await ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30", "-f", "lavfi", "-i",
                "sine=frequency=440:sample_rate=48000", "-t", "12", "-c:v", "h264_videotoolbox", "-realtime", "true",
                "-pix_fmt", "yuv420p", "-g", "30", "-bf", "0", "-c:a", "aac", sample.path], "Generate moving screen fixture")
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            let port = try await gateway.start(address: "127.0.0.1")
            let updates = await runtime.updates()
            observations = Task {
                for await snapshot in updates {
                    gateway.update(ViewerSession(token: snapshot.guestToken, title: "Generated screen endurance fixture",
                        sample: true, state: snapshot.session.audience, playback: snapshot.audience, revision: snapshot.audienceRevision))
                    preview.checkHealth(sourceAvailable: snapshot.sourceAvailable)
                }
            }
            try await wait(30, "The synthetic source did not become available.") { await runtime.snapshot().sourceAvailable }
            try preview.start(url: await runtime.localRTSP())
            _ = try await runtime.startSharing(approval: false)
            try await wait(30, "The audience publisher did not become available.") { await runtime.snapshot().audienceAvailable }
            let share = await runtime.snapshot()
            link = "http://127.0.0.1:\(port)/s/\(share.guestToken)/"
            try changePhase("warmup")
            // ManagedChild strips the environment. Resolve these local dependencies in the wrapper.
            let browserScript = root.appendingPathComponent("scripts/check-sharing-memory-browser.js").path
            browser = try ManagedChild(name: "Soak Chrome viewers", executable: URL(fileURLWithPath: node),
                arguments: [browserScript, control.path, report.appendingPathComponent("browser.ndjson").path, ack.path,
                            env["PLAYWRIGHT_MODULE"] ?? "", env["SETBEAM_TEST_CHROME"] ?? ""], directory: scratch)
            try await wait(55, "Both Chrome viewers did not decode the moving fixture.") { browserVerified() }
            guard gateway.viewers.count == 2 else { throw SetbeamError.runtime("Expected two separate viewer sessions.") }
            for _ in 0..<10 {
                warmupPeak = max(warmupPeak, try await sampleMemory())
                try await Task.sleep(for: .seconds(1))
            }
            try await audioPeak("live", silent: false)

            var liveFootprints: [UInt64] = []
            for segment in 0..<3 {
                try changePhase("live")
                try await wait(20, "The viewers did not start live segment \(segment + 1).") { browserVerified() }
                let duration = seconds / 3 + (segment == 2 ? seconds % 3 : 0)
                let deadline = clock.now + .seconds(duration)
                var previous = preview.diagnostics.presentedFrames
                repeat {
                    try await Task.sleep(until: min(deadline, clock.now + .seconds(5)), clock: clock)
                    guard browser?.isRunning == true else {
                        throw SetbeamError.runtime("Browser check failed: \(browser?.recentError ?? "")")
                    }
                    let footprint = try await sampleMemory()
                    liveFootprints.append(footprint)
                    let snapshot = await runtime.snapshot()
                    let current = preview.diagnostics.presentedFrames
                    guard snapshot.session.audience == .live, current > previous else {
                        throw SetbeamError.runtime("The live segment lost audience readiness or private frame progress.")
                    }
                    previous = current
                } while clock.now < deadline

                if segment == 0 {
                    try changePhase("hold")
                    try await runtime.setHold(true)
                    try await wait(30, "Hold was not confirmed by both viewers and the holding publisher.") {
                        let status = await runtime.snapshot()
                        return status.session.holding && status.audienceAvailable && browserVerified()
                    }
                    try await audioPeak("hold", silent: true)
                    try await verifyPrivateFrames()
                    try changePhase("recover")
                    try await runtime.setHold(false)
                    try await wait(30, "Viewers did not recover moving video after Resume.") { browserVerified() }
                    try await audioPeak("resumed", silent: false)
                    try await stall("audience", publisherIndex: 2)
                } else if segment == 1 {
                    try await stall("source", publisherIndex: 1)
                }
            }

            let quarter = max(1, liveFootprints.count / 4)
            func mean(_ values: ArraySlice<UInt64>) -> UInt64 { values.reduce(0, +) / UInt64(values.count) }
            let first = mean(liveFootprints.prefix(quarter)), last = mean(liveFootprints.suffix(quarter))
            try record("memoryTrend", ["firstQuarterMeanBytes": first, "finalQuarterMeanBytes": last, "warmupPeakBytes": warmupPeak])
            guard last <= first + 32 * MiB else { throw SetbeamError.runtime("Mac host final-quarter mean grew by over 32 MiB.") }

            try changePhase("stop")
            await runtime.stopSharing()
            let stopped = await runtime.snapshot()
            guard stopped.session.monitoring, !stopped.session.sharing, !stopped.audienceAvailable,
                  stopped.guestToken != share.guestToken else { throw SetbeamError.runtime("Stop did not retire the audience session.") }
            try await verifyPrivateFrames()
            try await wait(20, "Both viewers did not detach and show Sharing ended.") { browserVerified() }
            try await wait(45, "Headless Chrome did not close after both viewers ended.") { browser?.isRunning == false }
            guard browser?.terminationStatus == 0 else {
                throw SetbeamError.runtime("Browser check failed at Stop: \(browser?.recentError ?? "")")
            }
            _ = try await sampleMemory()
            await shutdown()
            try await wait(5, "An owned media process survived shutdown.") {
                observedPIDs.allSatisfy { MacProcess.startTime($0.key) != $0.value }
            }
            try record("cleanup", ["checkedMediaPIDs": observedPIDs.keys.sorted(), "remainingMediaPIDs": [Int]()])
            try record("passed", ["elapsedSeconds": began.duration(to: clock.now).components.seconds,
                                  "targetLiveSeconds": seconds])
        } catch {
            try? record("failed", ["error": Redaction.text(error.localizedDescription)])
            try? changePhase("abort")
            browser?.stop(timeout: 5)
            await shutdown()
            throw error
        }
    }
}
