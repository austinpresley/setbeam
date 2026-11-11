import AppKit
import Combine
import Darwin
import SetbeamCore
import XCTest
@testable import SetbeamApp

/// Opt-in endurance check of the same native preview and sharing runtime as the app.
/// SETBEAM_MEMORY_SOAK_SECONDS=1800 swift test -c release --filter SharingMemorySoakTests
final class SharingMemorySoakTests: XCTestCase {
    private func memory(_ pid: pid_t) throws -> UInt64 {
        var usage = rusage_info_v0()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return usage.ri_phys_footprint
    }

    private func descendants(_ parent: pid_t) throws -> [pid_t] {
        var children = [pid_t](repeating: 0, count: 64)
        let size = Int32(children.count * MemoryLayout<pid_t>.size)
        let count = children.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, size) }
        guard count >= 0, count < children.count else { throw SetbeamError.runtime("Could not enumerate all memory-test children.") }
        let direct = Array(children.prefix(Int(count))).filter { $0 > 0 }
        return try direct + direct.flatMap { try descendants($0) }
    }

    @MainActor func testSharingMemoryRemainsBounded() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["SETBEAM_MEMORY_SOAK_SECONDS"], let duration = Double(value), (30...14400).contains(duration) else {
            throw XCTSkip("Opt in with SETBEAM_MEMORY_SOAK_SECONDS=1800, from 30 seconds to 4 hours.")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent("Vendor/bin")
        let fixtures = environment["SETBEAM_MEMORY_FIXTURES"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Fixtures")
        let runtime = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        let player = NativePreview(), outgoing = NativePreview(audioEnabled: false, width: 480, frameRate: 8)
        let gateway = ViewerGateway(assets: AppAssets.viewerAssets)
        defer { if let path = environment["SETBEAM_MEMORY_CONTROL"] { try? FileManager.default.removeItem(atPath: path) } }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let main = NSWindow(contentRect: NSRect(x: 20, y: 40, width: 640, height: 360), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        let floating = NSWindow(contentRect: NSRect(x: 700, y: 40, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false; floating.isReleasedWhenClosed = false
        main.title = "Setbeam memory test · generated sample or selected display"
        floating.title = "Setbeam memory test · floating monitor"
        let mainPicture = PictureLayerView(), floatingPicture = PictureLayerView()
        main.contentView = mainPicture; floating.contentView = floatingPicture
        main.orderFrontRegardless(); floating.orderFrontRegardless()
        let frames = player.$picture.sink { picture in mainPicture.show(picture); floatingPicture.show(picture) }
        defer { frames.cancel(); mainPicture.show(nil); floatingPicture.show(nil); main.close(); floating.close() }
        var source: VideoSource = .sample
        if environment["SETBEAM_MEMORY_SOURCE"] == "screen" {
            guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("Screen Recording access is required for the display soak.") }
            source = .macScreen(displayUUID: try XCTUnwrap(MacDisplay.connected().first?.id))
        }
        func waitFor(_ predicate: (RuntimeSnapshot) -> Bool) async throws -> RuntimeSnapshot {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                let snapshot = await runtime.snapshot()
                if predicate(snapshot) { return snapshot }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            throw SetbeamError.runtime("Memory soak did not receive fresh media before its deadline.")
        }
        func publish(_ snapshot: RuntimeSnapshot) {
            gateway.update(ViewerSession(token: snapshot.guestToken, title: "Setbeam memory test", sample: source == .sample,
                                         state: snapshot.session.audience, playback: snapshot.audience, revision: snapshot.audienceRevision))
        }
        do {
            _ = try await runtime.prepare(source: source, viewerAddress: "127.0.0.1")
            _ = try await waitFor { $0.sourceAvailable }
            try player.start(url: await runtime.localRTSP())
            _ = try await runtime.startSharing()
            let initial = try await waitFor { $0.sourceAvailable && $0.audienceAvailable }
            try outgoing.start(url: await runtime.localRTSP("live"))
            publish(initial)
            let port = try await gateway.start(address: "127.0.0.1")
            if let path = environment["SETBEAM_MEMORY_CONTROL"] {
                let data = try JSONSerialization.data(withJSONObject: ["url": "http://127.0.0.1:\(port)/s/\(initial.guestToken)/", "pid": getpid()])
                FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
            }
            // Warm native renderer, decoder and encoder pools before measuring growth.
            // Large frame allocations can be cached after release. Measure the warm-up
            // envelope, rather than comparing a later peak with one low instant in that cycle.
            var warmupPeak = try memory(getpid())
            for _ in 0..<50 {
                warmupPeak = max(warmupPeak, try memory(getpid()))
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            let baseline = try memory(getpid()), began = Date()
            var peak = baseline, measurements: [[String: Any]] = [], previousFrames = player.diagnostics.presentedFrames
            var nextTransition = 0
            while Date().timeIntervalSince(began) < duration {
                let elapsed = Date().timeIntervalSince(began)
                // Repeat the lifecycle that leaves a floating preview alive but off screen.
                let phase = Int(elapsed / 15) % 4
                if phase == 1 { floating.orderOut(nil) }
                else if phase == 2 { main.orderOut(nil); floating.orderOut(nil) }
                else { main.orderFrontRegardless(); floating.orderFrontRegardless() }
                if elapsed >= Double(nextTransition + 1) * max(10, duration / 4), nextTransition < 3 {
                    nextTransition += 1
                    try await runtime.setHold(nextTransition % 2 == 1)
                    _ = try await waitFor { $0.sourceAvailable && $0.audienceAvailable }
                }
                let snapshot = await runtime.snapshot()
                publish(snapshot); player.checkHealth(sourceAvailable: snapshot.sourceAvailable)
                outgoing.checkHealth(sourceAvailable: snapshot.audienceAvailable)
                let footprint = try memory(getpid()); peak = max(peak, footprint)
                var heap = malloc_statistics_t()
                malloc_zone_statistics(nil, &heap)
                // Include native decoders and the media children of packaged supervisors.
                let pids = try descendants(getpid())
                let helperBytes = try pids.reduce(UInt64(0)) { try $0 + memory($1) }
                measurements.append(["seconds": elapsed, "appBytes": footprint, "runtimeBytes": helperBytes,
                                     "frames": player.diagnostics.presentedFrames, "queueBytes": player.diagnostics.videoQueueBytes,
                                     "mallocLiveBytes": UInt64(heap.size_in_use), "mallocReservedBytes": UInt64(heap.size_allocated),
                                     "width": player.diagnostics.width, "height": player.diagnostics.height,
                                     "hold": snapshot.session.holding, "viewerCount": gateway.viewers.count, "helperCount": pids.count])
                if let path = environment["SETBEAM_MEMORY_REPORT"] {
                    try JSONSerialization.data(withJSONObject: ["durationSeconds": elapsed, "source": source.label,
                                                                "baselineBytes": baseline, "warmupPeakBytes": warmupPeak, "peakBytes": peak, "samples": measurements],
                                               options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
                }
                guard footprint < warmupPeak + 96 * 1024 * 1024, footprint < 1024 * 1024 * 1024,
                      helperBytes < 1536 * 1024 * 1024 else { throw SetbeamError.runtime("Memory soak exceeded its app or runtime budget.") }
                XCTAssertTrue(snapshot.sourceAvailable, "Monitoring must continue while previews are hidden or the audience is held.")
                XCTAssertLessThanOrEqual(player.diagnostics.videoQueueBytes, PreviewInbox.maximumVideoBytes)
                print(String(format: "MEMORY %.0fs app %.1f MiB runtime %.1f MiB frames %d", elapsed,
                             Double(footprint) / 1048576, Double(helperBytes) / 1048576, player.diagnostics.presentedFrames))
                fflush(stdout)
                try await Task.sleep(nanoseconds: 5_000_000_000)
                XCTAssertGreaterThan(player.diagnostics.presentedFrames, previousFrames, "The allocation cap must not freeze playback.")
                previousFrames = player.diagnostics.presentedFrames
            }
            let quarter = max(1, measurements.count / 4)
            func mean(_ values: ArraySlice<[String: Any]>) -> Double {
                values.reduce(0) { $0 + Double($1["appBytes"] as! UInt64) } / Double(values.count)
            }
            XCTAssertLessThanOrEqual(mean(measurements.suffix(quarter)), mean(measurements.prefix(quarter)) + 32 * 1024 * 1024,
                                     "The final quarter must not retain the cumulative video bytes sent during the soak.")
            await runtime.stopSharing()
            let before = player.diagnostics.presentedFrames
            try await Task.sleep(nanoseconds: 2_000_000_000)
            XCTAssertGreaterThan(player.diagnostics.presentedFrames, before, "Stop Sharing must preserve local monitoring.")
            let summary: [String: Any] = ["durationSeconds": duration, "source": source.label,
                                        "baselineBytes": baseline, "warmupPeakBytes": warmupPeak, "peakBytes": peak, "samples": measurements]
            if let path = environment["SETBEAM_MEMORY_REPORT"] { try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
            gateway.stop(); player.stop(); outgoing.stop(); await runtime.shutdown()
            print("PASS: sharing memory stayed bounded through hidden previews, Hold and Stop.")
        } catch { gateway.stop(); player.stop(); outgoing.stop(); await runtime.shutdown(); throw error }
    }
}
