import AppKit
import SetbeamCore

/// Generated, labeled window content in a separate owned process. Commands arrive one per line in a file.
enum WindowFixture {
    static let colors: [String: (NSColor, [UInt8])] = ["green": (NSColor(srgbRed: 0, green: 0.78, blue: 0.35, alpha: 1), [0, 199, 89]),
                                                       "magenta": (NSColor(srgbRed: 0.9, green: 0, blue: 0.78, alpha: 1), [230, 0, 199])]
    final class Pattern: NSView {
        var tick = 0, color = NSColor.green
        override func draw(_ dirtyRect: NSRect) {
            color.setFill(); bounds.fill()
            NSColor.white.setFill(); NSRect(x: CGFloat(tick * 4 % max(1, Int(bounds.width - 40))), y: 20, width: 40, height: 40).fill()
            ("SETBEAM WINDOW PROBE · generated test content · \(tick)" as NSString).draw(at: NSPoint(x: 12, y: bounds.height - 30),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.black])
        }
    }
    @MainActor static func run(_ values: [String]) -> Never {
        func value(_ name: String) -> String? { values.firstIndex(of: name).flatMap { $0 + 1 < values.count ? values[$0 + 1] : nil } }
        let frame = (value("--frame") ?? "200,200,640,400").split(separator: ",").compactMap { Double($0) }
        let color = colors[value("--color") ?? "green"]?.0 ?? .green
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        var current: NSWindow!
        func open() {
            let window = NSWindow(contentRect: NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = Pattern(); view.color = color; window.contentView = view
            // A reopened window takes the previous window's title, as a reopened document would.
            window.title = current?.title ?? value("--title") ?? "Window probe"; window.orderFrontRegardless()
            current = window
            print("window \(window.windowNumber)"); fflush(stdout)
        }
        open()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { _ in
            MainActor.assumeIsolated { for window in app.windows { (window.contentView as? Pattern)?.tick += 1; window.contentView?.needsDisplay = true } }
        }
        var handled = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let file = value("--commands"), let text = try? String(contentsOfFile: file, encoding: .utf8) else { return }
                let lines = text.split(separator: "\n").map(String.init)
                while handled < lines.count {
                    let parts = lines[handled].split(separator: " ").map(String.init); handled += 1
                    switch parts.first {
                    case "close": current.close()
                    case "open": open()
                    case "mini": current.miniaturize(nil)
                    case "restore": current.deminiaturize(nil); current.orderFrontRegardless()
                    case "title": current.title = parts.dropFirst().joined(separator: " ")
                    case "resize": current.setContentSize(NSSize(width: Double(parts[1]) ?? 640, height: Double(parts[2]) ?? 400))
                    case "move": current.setFrameOrigin(NSPoint(x: Double(parts[1]) ?? 0, y: Double(parts[2]) ?? 0))
                    case "front": current.orderFrontRegardless()
                    case "quit": exit(0)
                    default: break
                    }
                    print("did \(parts.joined(separator: " "))"); fflush(stdout)
                }
            }
        }
        app.run()
        exit(0)
    }
}

extension SetbeamProbe {
    /// Real ScreenCaptureKit capture of one generated window through the bundled runtime.
    /// Opt-in: requires Screen Recording access for the process running the probe.
    static func testWindowSource(tools: URL, fixtures: URL, output: URL) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw SetbeamError.unavailable("NOT RUN: grant Screen Recording to the process running the probe.")
        }
        let directory = output.appendingPathComponent("window-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let commands = directory.appendingPathComponent("commands"), occluderCommands = directory.appendingPathComponent("occluder")
        try Data().write(to: commands); try Data().write(to: occluderCommands)
        let fixture = try ManagedChild(name: "Window fixture", executable: probe, arguments: ["--window-fixture", "--commands", commands.path, "--title", "Probe document A", "--color", "green", "--frame", "200,260,640,400"], directory: directory)
        let occluder = try ManagedChild(name: "Occluding fixture", executable: probe, arguments: ["--window-fixture", "--commands", occluderCommands.path, "--title", "Unrelated window", "--color", "magenta", "--frame", "520,160,500,300"], directory: directory)
        let runtime = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        defer { fixture.stop(); occluder.stop() }
        func send(_ line: String, to file: URL = commands) throws {
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            handle.seekToEndOfFile(); handle.write(Data((line + "\n").utf8))
        }
        func windowNumbers(_ child: ManagedChild) -> [UInt32] {
            child.capturedOutput.split(separator: "\n").compactMap { $0.hasPrefix("window ") ? UInt32($0.dropFirst(7)) : nil }
        }
        func until(_ seconds: TimeInterval, _ message: String, _ condition: () async throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if try await condition() { return }; try await Task.sleep(nanoseconds: 200_000_000) }
            throw SetbeamError.runtime(message)
        }
        try await until(10, "The fixture windows did not open.") { !windowNumbers(fixture).isEmpty && !windowNumbers(occluder).isEmpty }
        let start = try XCTUnwrapProbe(MacProcess.startTime(fixture.processID), "fixture start time")
        let identity = MacWindowIdentity(windowID: windowNumbers(fixture)[0], processID: fixture.processID, processStart: start)
        try await until(10, "The fixture window is not on screen.") { MacWindowLocator.status(of: identity).presence == .visible }
        let listed = try await MacWindow.shareable().map(\.window)
        guard let entry = listed.first(where: { $0.identity == identity }), entry.title == "Probe document A",
              !listed.contains(where: { $0.identity.processID == getpid() }) else {
            throw SetbeamError.runtime("The window list did not identify the fixture window exactly.")
        }
        print("PASS: the chooser list identifies the fixture window by number, process, and start time")

        /// Fraction of sampled pixels near each fixture colour in one decoded frame of a relay path.
        func colours(_ path: String) async throws -> (window: Double, unrelated: Double, bars: Double, size: String) {
            let url = await runtime.localRTSP(path), still = directory.appendingPathComponent("\(path)-\(UUID()).jpg")
            let streams = String(decoding: try await run(tools: tools, args: ["-v", "error", "-rtsp_transport", "tcp", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", url], directory: directory, executable: "ffprobe"), as: UTF8.self)
            _ = try await run(tools: tools, args: ["-nostdin", "-v", "error", "-rtsp_transport", "tcp", "-i", url, "-frames:v", "1", "-pix_fmt", "yuvj420p", "-q:v", "2", "-y", still.path], directory: directory)
            // The bundled FFmpeg has no raw muxer; decode its JPEG into 160 by 100 RGBA samples.
            guard let source = CGImageSourceCreateWithURL(still as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let context = CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 640, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw SetbeamError.runtime("Could not decode a \(path) frame.") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 100))
            let rgba = [UInt8](UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 160 * 100 * 4))
            let bytes = stride(from: 0, to: rgba.count, by: 4).flatMap { rgba[$0..<$0 + 3] }
            func near(_ target: [UInt8]) -> Double {
                var count = 0
                for index in stride(from: 0, to: bytes.count - 2, by: 3) where zip(bytes[index..<index + 3], target).allSatisfy({ abs(Int($0) - Int($1)) < 45 }) { count += 1 }
                return Double(count) / Double(max(1, bytes.count / 3))
            }
            // Share of sample rows that are almost entirely black: the bar ScreenCaptureKit leaves when it fits a reshaped window whole.
            let bars = Double((0..<100).filter { row in
                (0..<160).filter { column in bytes[(row * 160 + column) * 3..<(row * 160 + column) * 3 + 3].allSatisfy { $0 < 24 } }.count >= 144
            }.count) / 100
            return (near(WindowFixture.colors["green"]!.1), near(WindowFixture.colors["magenta"]!.1), bars, streams.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        do {
            _ = try await runtime.prepare(source: .macWindow(identity), viewerAddress: "127.0.0.1")
            try await until(20, "The window source did not become available.") { await runtime.snapshot().sourceAvailable }
            let local = try await colours("local")
            guard local.window > 0.5, local.unrelated < 0.01 else { throw SetbeamError.runtime("Local relay content was not only the selected window: \(local)") }
            print("PASS: one capture supplies the local relay at \(local.size); \(Int(local.window * 100))% fixture colour, \(String(format: "%.2f", local.unrelated * 100))% of the overlapping window")

            _ = try await runtime.startSharing()
            try await until(25, "Audience output did not start.") { await runtime.snapshot().audienceAvailable }
            let live = try await colours("live")
            guard live.window > 0.5, live.unrelated < 0.01 else { throw SetbeamError.runtime("Audience output did not carry only the window: \(live)") }
            try await runtime.setHold(true)
            try await until(25, "Holding output did not start.") { await runtime.snapshot().audienceAvailable }
            let held = try await colours("live")
            guard held.window < 0.05, await runtime.snapshot().sourceAvailable else { throw SetbeamError.runtime("Hold still carried the window or stopped monitoring: \(held)") }
            try await runtime.setHold(false)
            try await until(25, "Audience did not resume.") { await runtime.snapshot().audienceAvailable }
            await runtime.stopSharing()
            guard await runtime.snapshot().sourceAvailable else { throw SetbeamError.runtime("Stop Sharing interrupted local monitoring.") }
            print("PASS: sharing carried only the window; Hold replaced it (\(Int(held.window * 100))% fixture colour) while local monitoring continued; Stop kept monitoring")

            try send("title Probe document A, renamed"); try send("move 260 300"); try send("resize 900 520")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let moved = try await colours("local")
            guard await runtime.snapshot().sourceAvailable, MacWindowLocator.status(of: identity).title == "Probe document A, renamed",
                  moved.size == local.size, moved.unrelated < 0.01, moved.window > 0.5, local.bars < 0.02, moved.bars > 0.05 else {
                throw SetbeamError.runtime("Rename, move, or resize changed the source: before \(local), after \(moved)")
            }
            print("PASS: a renamed, moved, and resized window remains the same source at its starting size \(moved.size); the wider window is fitted whole beside a \(Int(moved.bars * 100))% black bar, not cropped")

            try send("mini")
            try await until(15, "A minimized window still looked available.") { !(await runtime.snapshot().sourceAvailable) }
            guard MacWindowLocator.status(of: identity).presence == .hidden else { throw SetbeamError.runtime("A minimized window was not reported as hidden.") }
            try send("restore")
            try await until(30, "The restored window did not return.") { await runtime.snapshot().sourceAvailable }
            print("PASS: minimizing paused the picture without substitution; restoring returned the same window")

            // A retained AppKit window keeps its number after closing, like a minimized one. A new
            // window with the same title is a different window and must never be captured.
            try send("close")
            try await until(15, "A closed window still looked available.") { !(await runtime.snapshot().sourceAvailable) }
            try send("open")
            try await until(10, "The replacement window did not open.") { windowNumbers(fixture).count == 2 }
            await runtime.retrySource()
            try await Task.sleep(nanoseconds: 8_000_000_000)
            guard !(await runtime.snapshot().sourceAvailable), windowNumbers(fixture)[1] != identity.windowID else {
                throw SetbeamError.runtime("A new window with the same title replaced the closed window.")
            }
            print("PASS: closing paused the source; a new window with the same title in the same app was not substituted")

            fixture.stop()
            try await until(10, "The ended window was not reported as closed.") { MacWindowLocator.status(of: identity).presence == .closed }
            await runtime.retrySource()
            try await until(10, "The closed window did not explain itself.") { await runtime.snapshot().message == MacWindowLocator.closedMessage }
            guard !(await runtime.snapshot().sourceAvailable) else { throw SetbeamError.runtime("A closed window's source became available.") }
            let processes = await runtime.processIDs()
            await runtime.shutdown()
            try await Task.sleep(nanoseconds: 500_000_000)
            guard processes.allSatisfy({ kill($0, 0) != 0 }) else { throw SetbeamError.runtime("Owned media processes outlived shutdown.") }
            print("PASS: a quit owner reports the window closed, nothing else is captured, and shutdown cleans owned processes")
        } catch { await runtime.shutdown(); throw error }
    }

    private static func XCTUnwrapProbe<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw SetbeamError.runtime("Missing \(name).") }
        return value
    }
}
