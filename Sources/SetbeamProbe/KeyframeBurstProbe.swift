import Foundation
import SetbeamCore

extension SetbeamProbe {
    /// A detailed, mostly static picture, like a desktop or full-screen photograph, encodes
    /// keyframes many times larger than its P frames. Each keyframe reaches the relay as one
    /// burst of RTP packets, and every reader must receive it intact while sharing.
    static func testKeyframeBursts(tools: URL, fixtures: URL, output: URL) async throws {
        let runtime = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        let directory = output.appendingPathComponent("keyframes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        // One random 1080p picture repeated at 60 fps: incompressible keyframes, small P frames.
        let (width, height) = (1920, 1080)
        // Random luma within video range over neutral chroma. VideoToolbox emits no frames for
        // full-range random bytes in every plane.
        var pixels = [UInt8](repeating: 128, count: width * height * 3 / 2)
        arc4random_buf(&pixels, width * height)
        for index in 0..<(width * height) { pixels[index] = pixels[index] & 0x7f + 48 }
        let picture = directory.appendingPathComponent("detail.yuv")
        try Data(pixels).write(to: picture)
        // The same monitoring-quality encoder settings as This Mac's screen at 1080p60. A file
        // carries the parameter sets that a direct VideoToolbox RTSP publish omits.
        let fixture = directory.appendingPathComponent("detail.mp4")
        _ = try await run(tools: tools, args: ["-nostdin", "-hide_banner", "-loglevel", "error", "-stream_loop", "-1",
            "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", "\(width)x\(height)", "-framerate", "60", "-i", picture.path, "-frames:v", "240",
            "-c:v", "h264_videotoolbox", "-realtime", "1", "-b:v", "41472k", "-bf", "0", "-g", "60", "-profile:v", "baseline", fixture.path],
            directory: directory, timeout: 30)
        let port = try NetworkAddress.freeTCPPort()
        var controlPort = try NetworkAddress.freeTCPPort()
        while controlPort == port { controlPort = try NetworkAddress.freeTCPPort() }
        let password = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // The fixture server's own queue is generous so only the runtime's relay is under test.
        let configuration: [String: Any] = ["logLevel": "warn", "api": true, "apiAddress": "127.0.0.1:\(controlPort)",
            "rtspAddress": "127.0.0.1:\(port)", "rtspTransports": ["tcp"], "rtmp": false, "hls": false,
            "webrtc": false, "srt": false, "moq": false, "writeQueueSize": 16384,
            "authInternalUsers": [["user": "fixture", "pass": password, "ips": ["127.0.0.1"],
                "permissions": [["action": "publish", "path": "fixture"], ["action": "read", "path": "fixture"], ["action": "api"]]]],
            "paths": ["fixture": ["source": "publisher", "overridePublisher": false]]]
        let configurationURL = directory.appendingPathComponent("mediamtx.json")
        try JSONSerialization.data(withJSONObject: configuration).write(to: configurationURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
        let upstream = "rtsp://fixture:\(password)@127.0.0.1:\(port)/fixture"
        let server = try ManagedChild(name: "Keyframe fixture server", executable: tools.appendingPathComponent("mediamtx"), arguments: [configurationURL.path], directory: directory)
        var sender: ManagedChild?
        defer { sender?.stop(); server.stop() }
        func waitFor(_ predicate: (RuntimeSnapshot) -> Bool) async throws {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if predicate(await runtime.snapshot()) { return }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            throw SetbeamError.runtime("Keyframe check did not reach the expected state. \(sender?.recentError ?? "") \(await runtime.diagnosticStatus())")
        }
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(controlPort)/v3/paths/get/fixture")!, timeoutInterval: 2)
            request.setValue("Basic " + Data("fixture:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            let serverDeadline = Date().addingTimeInterval(5)
            while Date() < serverDeadline, (try? await URLSession.shared.data(for: request)).map({ ($0.1 as? HTTPURLResponse)?.statusCode == 200 }) != true {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard server.isRunning else { throw SetbeamError.runtime("Keyframe fixture server failed. \(server.recentError)") }
            sender = try ManagedChild(name: "Keyframe fixture sender", executable: tools.appendingPathComponent("ffmpeg"),
                arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-re", "-stream_loop", "-1", "-i", fixture.path,
                    "-c", "copy", "-f", "rtsp", "-rtsp_transport", "tcp", upstream], directory: directory)
            _ = try await runtime.prepare(source: .network(upstream), viewerAddress: "127.0.0.1")
            try await waitFor { $0.sourceAvailable }
            _ = try await runtime.startSharing()
            try await waitFor { $0.sourceAvailable && $0.audienceAvailable }
            let local = await runtime.localRTSP()

            let sizes = try await run(tools: tools, args: ["-v", "error", "-rtsp_transport", "tcp", "-select_streams", "v:0", "-read_intervals", "%+3",
                "-show_entries", "packet=size,flags", "-of", "csv=p=0", local], directory: directory, executable: "ffprobe", timeout: 16)
            let keyframes = String(decoding: sizes, as: UTF8.self).split(separator: "\n").compactMap { line -> Int? in
                let fields = line.split(separator: ",")
                return fields.count >= 2 && fields[1].hasPrefix("K") ? Int(fields[0]) : nil
            }
            // MediaMTX's default reader queue holds 512 packets, about 750 KB of RTP payload.
            guard let largest = keyframes.max(), largest > 1_000_000 else {
                throw SetbeamError.runtime("The keyframe fixture did not produce bursts larger than the default reader queue (\(keyframes)).")
            }

            let frames = FrameCounter(frameBytes: width * height * 3 / 2 + 64)
            let monitor = try ManagedChild(name: "Keyframe monitor", executable: tools.appendingPathComponent("setbeam-preview"),
                arguments: [local, "--silent"], directory: directory, onOutput: { frames.add($0.count) })
            try await Task.sleep(nanoseconds: 7_000_000_000)
            let running = monitor.isRunning
            monitor.stop()
            let errors = monitor.recentError.split(separator: "\n").filter { $0.hasPrefix("[h264") }
            guard running, errors.isEmpty, frames.count >= 300 else {
                throw SetbeamError.runtime("Keyframes of \(largest / 1024) KB reached local monitoring damaged while sharing: \(frames.count) frames, \(errors.count) decoder errors. First: \(errors.first ?? "none")")
            }
            print("PASS: \(largest / 1024) KB keyframes reach local monitoring intact while sharing (\(frames.count) frames in 7 s, no decoder errors)")
            let pids = await runtime.processIDs()
            await runtime.shutdown()
            guard pids.allSatisfy({ kill($0, 0) != 0 }) else { throw SetbeamError.runtime("Keyframe check left owned media processes running.") }
        } catch { await runtime.shutdown(); throw error }
    }
}

private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let frameBytes: Int
    private var bytes = 0
    init(frameBytes: Int) { self.frameBytes = frameBytes }
    func add(_ count: Int) { lock.lock(); bytes += count; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return bytes / frameBytes }
}
