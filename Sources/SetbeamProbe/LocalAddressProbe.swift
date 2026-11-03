import Foundation
import Darwin
import SetbeamCore

/// Opens the real viewer gateway and bundled media through a published `.local` name. The name is
/// registered for this Mac only, so the check never announces anything on the network.
extension SetbeamProbe {
    static func testLocalAddress(tools: URL, fixtures: URL, output: URL) async throws {
        let runtime = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/SetbeamApp/Resources")
        let assets = Dictionary(uniqueKeysWithValues: try FileManager.default.contentsOfDirectory(atPath: resources.path).map {
            ($0, try Data(contentsOf: resources.appendingPathComponent($0)))
        })
        let gateway = ViewerGateway(assets: assets)
        let publisher = LocalAddressPublisher(), rival = LocalAddressPublisher()
        let directory = output.appendingPathComponent("local-address", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let label = "setbeam-probe-\(UInt32.random(in: 100_000...999_999))"
        let host = LocalAddressName.host(label)
        func waitFor(_ what: String, seconds: TimeInterval = 20, _ condition: () async -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !(await condition()) {
                guard Date() < deadline else { throw SetbeamError.runtime("Timed out waiting for \(what).") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        func session(_ snapshot: RuntimeSnapshot) -> ViewerSession {
            ViewerSession(token: snapshot.guestToken, title: "Local address probe", sample: true, state: snapshot.session.audience,
                          playback: snapshot.audience, revision: snapshot.audienceRevision)
        }
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            _ = try await runtime.startSharing()
            try await waitFor("the audience output") { let s = await runtime.snapshot(); return s.audienceAvailable && s.sourceAvailable }
            var snapshot = await runtime.snapshot()
            let port = try await gateway.start(address: "127.0.0.1")
            gateway.update(session(snapshot))
            publisher.publish(label: label, scope: .thisMacOnly, address: "127.0.0.1")
            try await waitFor("the local address") { publisher.state == .active(label) }
            guard resolve(host) == "127.0.0.1" else { throw SetbeamError.runtime("\(host) did not resolve to the viewing address.") }
            print("PASS: \(host) registers with the system responder and resolves to the viewing address")

            let base = "http://\(host):\(port)"
            let page = try await http("\(base)/s/\(snapshot.guestToken)/")
            guard page.status == 200, String(decoding: page.body, as: UTF8.self).contains("viewer.js") else {
                throw SetbeamError.runtime("The viewer page did not open at the local address.")
            }
            let wrong = try await http("\(base)/s/\(String(repeating: "0", count: 64))/"), bare = try await http("\(base)/")
            guard wrong.status == 404, bare.status == 404, !String(decoding: wrong.body + bare.body, as: UTF8.self).contains(snapshot.guestToken) else {
                throw SetbeamError.runtime("The local address served a session without its private code.")
            }
            print("PASS: the local address opens the viewer only with the session's private code; the name alone and other codes get 404")

            let join = try await http("\(base)/s/\(snapshot.guestToken)/join", json: ["mobile": false])
            guard let pass = join.json["pass"] as? String, join.json["admission"] as? String == "admitted" else {
                throw SetbeamError.runtime("Joining through the local address did not admit the viewer.")
            }
            let config = try await http("\(base)/s/\(snapshot.guestToken)/config.json", pass: pass)
            guard config.status == 200, let user = config.json["user"] as? String, let password = config.json["pass"] as? String,
                  (config.json["whepURL"] as? String)?.hasPrefix("http://127.0.0.1:") == true else {
                throw SetbeamError.runtime("Playback details were not issued through the local address.")
            }
            // Media stays on the IP address, so playback never depends on name resolution.
            guard try await whep(config.json["whepURL"] as! String, user, password) != 401 else {
                throw SetbeamError.runtime("The playback credential issued through the local address was refused.")
            }
            let frames = try await decodedFrames(tools: tools, directory: directory, rtsp: await runtime.localRTSP("live"), user: user, password: password)
            guard frames >= 30 else { throw SetbeamError.runtime("Only \(frames) audience frames decoded with the issued credential.") }
            print("PASS: a viewer joined at the local address receives playback details for the IP address; WHEP accepts them and \(frames) real audience frames decode")

            let origin = presenceStatus(host: host, port: port, token: snapshot.guestToken, origin: "http://\(host):\(port)")
            let crossOrigin = presenceStatus(host: host, port: port, token: snapshot.guestToken, origin: "http://127.0.0.1:\(port)")
            gateway.setAccess(approval: false, pointers: true)
            let pointing = presenceStatus(host: host, port: port, token: snapshot.guestToken, origin: "http://\(host):\(port)")
            guard origin == 503, crossOrigin == 400, pointing == 101 else {
                throw SetbeamError.runtime("Presence same-origin handling changed at the local address: \(origin), \(crossOrigin), \(pointing).")
            }
            print("PASS: shared pointers accept the local address as their own origin (101) and still refuse another origin (400) and pointers-off (503)")

            gateway.setAccess(approval: true, pointers: true)
            try await runtime.setViewerAccess(approval: true, readers: gateway.desiredReaders)
            snapshot = await runtime.snapshot(); gateway.update(session(snapshot))
            let nameless = try await http("\(base)/s/\(snapshot.guestToken)/join", json: ["mobile": false])
            let request = try await http("\(base)/s/\(snapshot.guestToken)/join", json: ["mobile": false, "name": "Probe"])
            guard nameless.status == 400, let waiting = request.json["pass"] as? String, request.json["admission"] as? String == "pending",
                  let number = request.json["number"] as? Int,
                  try await http("\(base)/s/\(snapshot.guestToken)/config.json", pass: waiting).status == 403,
                  try await whep(config.json["whepURL"] as! String, "guest", snapshot.guestToken) == 401 else {
                throw SetbeamError.runtime("Viewer approval was bypassed at the local address.")
            }
            gateway.approve(number: number)
            try await runtime.setViewerAccess(approval: true, readers: gateway.desiredReaders)
            gateway.confirm(readers: gateway.desiredReaders)
            let admitted = try await http("\(base)/s/\(snapshot.guestToken)/config.json", pass: waiting)
            guard admitted.status == 200, let own = admitted.json["user"] as? String, own != "guest",
                  try await whep(config.json["whepURL"] as! String, own, admitted.json["pass"] as? String ?? "") != 401 else {
                throw SetbeamError.runtime("An admitted viewer at the local address did not receive its own reader.")
            }
            print("PASS: with approval on, the local address requires a name, withholds playback until Admit, and the shared code alone is refused by media")

            try await runtime.setHold(true)
            try await waitFor("holding output") { let s = await runtime.snapshot(); return s.session.holding && s.audienceAvailable }
            snapshot = await runtime.snapshot(); gateway.update(session(snapshot))
            let held = try await http("\(base)/s/\(snapshot.guestToken)/state.json")
            guard held.json["state"] as? String == "holding", snapshot.sourceAvailable else {
                throw SetbeamError.runtime("Hold was not reported at the local address, or local monitoring stopped.")
            }
            try await runtime.setHold(false)
            print("PASS: Hold is reported at the local address while local monitoring continues")

            rival.publish(label: label, scope: .thisMacOnly, address: "127.0.0.2")
            try await waitFor("the rival's renamed address") { rival.state == .active("\(label)-2") }
            guard publisher.state == .active(label), resolve(host) == "127.0.0.1", resolve(LocalAddressName.host("\(label)-2")) == "127.0.0.2" else {
                throw SetbeamError.runtime("A second registrant took over or failed to rename.")
            }
            rival.stop(); await rival.settle()
            print("PASS: a second registrant with another address becomes \(label)-2; the first keeps \(host)")

            publisher.publish(label: label, scope: .thisMacOnly, address: "127.0.0.3")
            try await waitFor("the new address") { publisher.state == .active(label) && resolve(host) == "127.0.0.3" }
            publisher.publish(label: label, scope: .thisMacOnly, address: "127.0.0.1")
            try await waitFor("the viewing address again") { publisher.state == .active(label) && resolve(host) == "127.0.0.1" }
            print("PASS: an address change keeps the name and resolves to the new address")

            let oldToken = snapshot.guestToken
            publisher.stop(); await publisher.settle()
            await runtime.stopSharing()
            snapshot = await runtime.snapshot(); gateway.update(session(snapshot))
            try await waitFor("the name to stop resolving", seconds: 10) { resolve(host) == nil }
            let ended = try await http("http://127.0.0.1:\(port)/s/\(oldToken)/")
            guard ended.status == 404, String(decoding: ended.body, as: UTF8.self).contains("<html"), snapshot.sourceAvailable, !snapshot.session.sharing else {
                throw SetbeamError.runtime("Stop Sharing left the old link usable or interrupted monitoring.")
            }
            print("PASS: Stop Sharing removes the name; the old link gets the expired page and local monitoring continues")

            _ = try await runtime.startSharing()
            snapshot = await runtime.snapshot(); gateway.update(session(snapshot))
            publisher.publish(label: label, scope: .thisMacOnly, address: "127.0.0.1")
            try await waitFor("the local address after restart") { publisher.state == .active(label) }
            let stale = try await http("\(base)/s/\(oldToken)/"), fresh = try await http("\(base)/s/\(snapshot.guestToken)/")
            guard snapshot.guestToken != oldToken, stale.status == 404, fresh.status == 200 else {
                throw SetbeamError.runtime("Restarted sharing reused or revived the expired link.")
            }
            print("PASS: sharing again returns the same name with a new private code; the expired link stays expired")

            publisher.stop(); rival.stop(); gateway.stop(); await publisher.settle()
            await runtime.shutdown()
        } catch {
            publisher.stop(); rival.stop(); gateway.stop()
            await runtime.shutdown(); throw error
        }
    }

    static func resolve(_ host: String) -> String? {
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "80", &hints, &result) == 0, let result else { return nil }
        defer { freeaddrinfo(result) }
        let address = result.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        return String(cString: inet_ntoa(address))
    }

    private struct Reply { let status: Int; let body: Data; var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] } }

    private static func http(_ url: String, json: [String: Any]? = nil, pass: String? = nil) async throws -> Reply {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 10)
        if let json {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        if let pass { request.setValue(pass, forHTTPHeaderField: "X-Setbeam-Pass") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return Reply(status: (response as! HTTPURLResponse).statusCode, body: data)
    }

    private static func whep(_ url: String, _ user: String, _ password: String) async throws -> Int {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 10)
        request.httpMethod = "POST"; request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.httpBody = Data("v=0\r\n".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as! HTTPURLResponse).statusCode
    }

    private static func decodedFrames(tools: URL, directory: URL, rtsp: String, user: String, password: String) async throws -> Int {
        var parts = URLComponents(string: rtsp)!; parts.user = user; parts.password = password
        let data = try await run(tools: tools, args: ["-v", "error", "-rtsp_transport", "tcp", "-read_intervals", "%+3", "-select_streams", "v:0",
                                                       "-count_frames", "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", parts.string!],
                                 directory: directory, executable: "ffprobe")
        return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first ?? "") ?? 0
    }

    /// The status of a presence WebSocket upgrade sent to the name, with the given Origin.
    private static func presenceStatus(host: String, port: UInt16, token: String, origin: String) -> Int {
        guard let address = resolve(host) else { return 0 }
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian; target.sin_addr.s_addr = inet_addr(address)
        let connected = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { return 0 }
        let request = "GET /s/\(token)/presence HTTP/1.1\r\nHost: \(host):\(port)\r\nOrigin: \(origin)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 12 else { return 0 }
        let line = String(decoding: buffer[0..<count], as: UTF8.self)
        return Int(line.split(separator: " ").dropFirst().first ?? "") ?? 0
    }
}
