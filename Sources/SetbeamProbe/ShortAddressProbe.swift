import Foundation
import Darwin
import SetbeamCore

/// Types the bare local address against the real gateway, port 80 listener, and bundled media. The name
/// is registered for this Mac only, and the listener answers only connections to 127.0.0.1, so nothing
/// is announced or served to the network.
extension SetbeamProbe {
    static func testShortAddress(tools: URL, fixtures: URL, output: URL) async throws {
        let runtime = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/SetbeamApp/Resources")
        let assets = Dictionary(uniqueKeysWithValues: try FileManager.default.contentsOfDirectory(atPath: resources.path).map {
            ($0, try Data(contentsOf: resources.appendingPathComponent($0)))
        })
        let gateway = ViewerGateway(assets: assets)
        let publisher = LocalAddressPublisher()
        var listener = ShortAddressListener(port: ShortAddressListener.webPort, retryDelay: 1)
        let directory = output.appendingPathComponent("short-address", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let label = "setbeam-short-\(UInt32.random(in: 100_000...999_999))"
        let host = LocalAddressName.host(label)
        func waitFor(_ what: String, seconds: TimeInterval = 20, _ condition: () async -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !(await condition()) {
                guard Date() < deadline else { throw SetbeamError.runtime("Timed out waiting for \(what).") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        func session(_ snapshot: RuntimeSnapshot) -> ViewerSession {
            ViewerSession(token: snapshot.guestToken, title: "Short address probe", sample: true, state: snapshot.session.audience,
                          playback: snapshot.audience, revision: snapshot.audienceRevision)
        }
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            _ = try await runtime.startSharing()
            try await waitFor("the audience output") { let s = await runtime.snapshot(); return s.audienceAvailable && s.sourceAvailable }
            var snapshot = await runtime.snapshot()
            let port = try await gateway.start(address: "127.0.0.1")
            gateway.update(session(snapshot))
            gateway.setAccess(approval: true, pointers: false)
            try await runtime.setViewerAccess(approval: true, readers: gateway.desiredReaders)
            snapshot = await runtime.snapshot(); gateway.update(session(snapshot))
            publisher.publish(label: label, scope: .thisMacOnly, address: "127.0.0.1")
            try await waitFor("the local address") { publisher.state == .active(label) }
            guard resolve(host) == "127.0.0.1" else { throw SetbeamError.runtime("\(host) did not resolve.") }

            guard gateway.shortAddressPath == nil else { throw SetbeamError.runtime("The short address opened before the operator chose it.") }
            gateway.setShortAddress(open: true)
            let path = try unwrap(gateway.shortAddressPath, "The short address did not open under approval.")
            guard !path.contains(snapshot.guestToken) else { throw SetbeamError.runtime("The short-address path contains the viewing link's code.") }
            listener.serve(.init(address: "127.0.0.1", hosts: [host], port: port, path: path))
            try await waitFor("port 80", seconds: 5) { listener.state != .starting && listener.state != .stopped }
            if case .unavailable(let problem) = listener.state {
                // Another app holds port 80 or macOS refused it. The operator sees this; the link keeps working.
                let joined = try await http("http://127.0.0.1:\(port)/s/\(snapshot.guestToken)/join", json: ["name": "Link", "ask": true, "mobile": false])
                guard joined.status == 200 else { throw SetbeamError.runtime("The viewing link stopped working while port 80 was unavailable.") }
                print("PASS: port 80 is unavailable here (\(problem.rawValue)); the listener reports it, retries, and the viewing link keeps working")
                listener.stop()
                listener = ShortAddressListener(port: 0, retryDelay: 1)
                listener.serve(.init(address: "127.0.0.1", hosts: [host], port: port, path: path))
                try await waitFor("a substitute port") { listener.state == .active }
                print("NOTE: the remaining checks use substitute port \(listener.boundPort ?? 0) instead of port 80")
            } else {
                print("PASS: an unprivileged wildcard listener answers on port 80 while the short address is open")
            }
            let webPort = try unwrap(listener.boundPort, "The short address listener has no port.")

            let typed = try unwrap(raw("127.0.0.1", webPort, "GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n"), "Typing the name did not connect.")
            let location = typed.components(separatedBy: "\r\n").first { $0.hasPrefix("Location: ") }.map { String($0.dropFirst(10)) }
            guard typed.hasPrefix("HTTP/1.1 302"), location == "http://\(host):\(port)\(path)", !typed.contains(snapshot.guestToken) else {
                throw SetbeamError.runtime("Typing the name did not send the browser to the ask-only path: \(typed.prefix(200))")
            }
            let strangers = try ["GET / HTTP/1.1\r\nHost: elsewhere.example\r\n\r\n", "GET /viewer.js HTTP/1.1\r\nHost: \(host)\r\n\r\n",
                                 "GET /v3/config/global/get HTTP/1.1\r\nHost: \(host)\r\n\r\n"].map { try raw("127.0.0.1", webPort, $0) ?? "" }
            guard strangers.allSatisfy({ $0.hasPrefix("HTTP/1.1 404") && !$0.contains(path) && !$0.contains(snapshot.guestToken) }) else {
                throw SetbeamError.runtime("The short address served something other than its redirect.")
            }
            print("PASS: typing \(host) redirects only GET / to the ask-only path on the gateway; other hosts and paths get 404 and neither code")

            if let other = NetworkAddress.available().first(where: { $0.address != "127.0.0.1" }) {
                let reply = try raw(other.address, webPort, "GET / HTTP/1.1\r\nHost: \(other.address)\r\n\r\n")
                guard reply == "" else { throw SetbeamError.runtime("Port \(webPort) answered a connection to \(other.interface).") }
                print("PASS: the wildcard listener closes connections to this Mac's other addresses without a reply")
            }

            let page = try await http(location!)
            let state = try await http(location! + "state.json")
            guard page.status == 200, String(decoding: page.body, as: UTF8.self).contains("viewer.js"), state.json["approval"] as? Bool == true else {
                throw SetbeamError.runtime("The ask-only path did not open the viewer join page under approval.")
            }
            let nameless = try await http(location! + "join", json: ["mobile": true])
            let saved = try await http(location! + "join", json: ["mobile": true, "name": "Saved"])
            let request = try await http(location! + "join", json: ["mobile": true, "name": "Typed", "ask": true])
            guard nameless.status == 400, saved.status == 400, let waiting = request.json["pass"] as? String,
                  request.json["admission"] as? String == "pending", let number = request.json["number"] as? Int,
                  try await http(location! + "config.json", pass: waiting).status == 403,
                  try await whep(snapshot.audience.whepURL, "guest", snapshot.guestToken) == 401 else {
                throw SetbeamError.runtime("The short address let a viewer in without Ask to join and Admit.")
            }
            guard gateway.viewers.first(where: { $0.number == number })?.shortAddress == true else {
                throw SetbeamError.runtime("The operator's row does not say the request came from the short address.")
            }
            print("PASS: a typed-name viewer must ask with a name, waits as pending without playback details, and the link's code alone is refused by media")

            gateway.approve(number: number)
            try await runtime.setViewerAccess(approval: true, readers: gateway.desiredReaders)
            gateway.confirm(readers: gateway.desiredReaders)
            let admitted = try await http(location! + "config.json", pass: waiting)
            guard admitted.status == 200, let user = admitted.json["user"] as? String, user != "guest",
                  let password = admitted.json["pass"] as? String, password != snapshot.guestToken,
                  (admitted.json["whepURL"] as? String)?.hasPrefix("http://127.0.0.1:") == true,
                  try await whep(admitted.json["whepURL"] as! String, user, password) != 401 else {
                throw SetbeamError.runtime("An admitted typed-name viewer did not receive its own reader.")
            }
            let frames = try await decodedFrames(tools: tools, directory: directory, rtsp: await runtime.localRTSP("live"), user: user, password: password)
            guard frames >= 30 else { throw SetbeamError.runtime("Only \(frames) audience frames decoded with the admitted reader.") }
            print("PASS: after Admit the typed-name viewer gets its own read-only reader for the IP address; \(frames) real audience frames decode")

            try await runtime.setHold(true)
            try await waitFor("holding output") { let s = await runtime.snapshot(); return s.session.holding && s.audienceAvailable }
            snapshot = await runtime.snapshot(); gateway.update(session(snapshot))
            let held = try await http(location! + "state.json")
            guard held.json["state"] as? String == "holding", snapshot.sourceAvailable else {
                throw SetbeamError.runtime("Hold was not reported on the short-address path, or local monitoring stopped.")
            }
            try await runtime.setHold(false)
            snapshot = await runtime.snapshot(); gateway.update(session(snapshot))
            print("PASS: Hold reaches typed-name viewers while local monitoring continues")

            // Approval off: the app stops port 80 and closes the short address with it.
            let second = try await http(location! + "join", json: ["mobile": true, "name": "Second", "ask": true])
            let secondPass = try unwrap(second.json["pass"] as? String, "A second typed-name request was refused.")
            listener.stop(); gateway.setAccess(approval: false, pointers: false)
            try await runtime.setViewerAccess(approval: false, readers: gateway.desiredReaders)
            let declined = try await http(location! + "heartbeat", json: ["pass": secondPass, "mobile": true])
            let late = try await http(location! + "join", json: ["mobile": true, "name": "Late", "ask": true])
            let stillAdmitted = try await http(location! + "config.json", pass: waiting)
            let closedPort = try raw("127.0.0.1", webPort, "GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            guard declined.json["admission"] as? String == "declined", late.status == 404, gateway.shortAddressPath == nil,
                  stillAdmitted.status == 200, closedPort == nil || closedPort?.contains(path) == false else {
                throw SetbeamError.runtime("Turning approval off let a typed-name request in or left the short address open.")
            }
            print("PASS: turning approval off stops port 80, declines waiting typed-name requests, refuses new ones, and keeps the admitted viewer")

            let oldPath = path, oldToken = snapshot.guestToken
            publisher.stop(); await publisher.settle()
            await runtime.stopSharing()
            snapshot = await runtime.snapshot(); gateway.update(session(snapshot))
            let ended = try await http("http://127.0.0.1:\(port)\(oldPath)")
            let endedLink = try await http("http://127.0.0.1:\(port)/s/\(oldToken)/")
            guard ended.status == 404, endedLink.status == 404, gateway.shortAddressPath == nil, snapshot.sourceAvailable, !snapshot.session.sharing else {
                throw SetbeamError.runtime("Stop Sharing left the short-address path usable or interrupted monitoring.")
            }
            print("PASS: Stop Sharing retires the short-address path with the link, and local monitoring continues")

            listener.stop(); publisher.stop(); gateway.stop(); await publisher.settle()
            await runtime.shutdown()
        } catch {
            listener.stop(); publisher.stop(); gateway.stop()
            await runtime.shutdown(); throw error
        }
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SetbeamError.runtime(message) }
        return value
    }

    /// One raw request to an IPv4 address, read until the server closes. Nil when nothing listens.
    private static func raw(_ address: String, _ port: UInt16, _ request: String) throws -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw SetbeamError.runtime("No socket.") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian; target.sin_addr.s_addr = inet_addr(address)
        let connected = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { return nil }
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var received = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            received.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: received, as: UTF8.self)
    }
}
