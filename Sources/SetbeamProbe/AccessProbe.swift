import Foundation
import SetbeamCore

/// Verifies viewer approval against the real bundled media server: which credentials can read the
/// audience output, and that removing one admitted reader ends its active session only.
extension SetbeamProbe {
    static func testViewerAccess(tools: URL, fixtures: URL, output: URL) async throws {
        let runtime = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        let directory = output.appendingPathComponent("access", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var readers: [ManagedChild] = []
        func waitFor(_ label: String, _ predicate: (RuntimeSnapshot) -> Bool) async throws {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if predicate(await runtime.snapshot()) { return }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            throw SetbeamError.runtime("Timed out waiting for the \(label).")
        }
        do {
            _ = try await runtime.prepare(source: .sample, viewerAddress: "127.0.0.1")
            _ = try await runtime.startSharing()
            try await waitFor("audience output") { $0.audienceAvailable && $0.sourceAvailable }
            let snapshot = await runtime.snapshot()
            func url(_ user: String, _ password: String) async -> String {
                var parts = URLComponents(string: await runtime.localRTSP("live"))!
                parts.user = user; parts.password = password
                return parts.string!
            }
            func readable(_ user: String, _ password: String) async throws -> Bool {
                let result = try await run(tools: tools, args: ["-v", "error", "-rtsp_transport", "tcp", "-show_streams", "-of", "json", await url(user, password)],
                                           directory: directory, executable: "ffprobe", expectSuccess: false)
                // A refused read reports its authorization error; an accepted one prints nothing on stderr.
                return String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            func whepStatus(_ user: String, _ password: String) async throws -> Int {
                let descriptor = snapshot.audience
                // MediaMTX delays failed authentication, so allow longer than its pause.
                var request = URLRequest(url: URL(string: descriptor.whepURL)!, timeoutInterval: 10)
                request.httpMethod = "POST"; request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
                request.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
                request.httpBody = Data("v=0\r\n".utf8)
                let (_, response) = try await URLSession.shared.data(for: request)
                return (response as! HTTPURLResponse).statusCode
            }
            guard try await readable("guest", snapshot.guestToken), try await whepStatus("guest", snapshot.guestToken) != 401 else {
                throw SetbeamError.runtime("The shared viewing credential did not read the audience output without approval.")
            }
            print("PASS: without approval, the shared viewing credential reads the audience output")

            let a = ViewerReader(user: "viewer1xprobe", password: UUID().uuidString), b = ViewerReader(user: "viewer2xprobe", password: UUID().uuidString)
            let revision = snapshot.audienceRevision
            try await runtime.setViewerAccess(approval: true, readers: [a, b])
            guard await runtime.snapshot().audienceRevision > revision else {
                throw SetbeamError.runtime("Turning approval on did not move viewers to a new publisher revision.")
            }
            let guestRTSP = try await readable("guest", snapshot.guestToken), guestWHEP = try await whepStatus("guest", snapshot.guestToken)
            guard !guestRTSP, guestWHEP == 401 else {
                throw SetbeamError.runtime("The viewing link's shared credential still reads media under approval.")
            }
            guard try await readable(a.user, a.password), try await readable(b.user, b.password),
                  try await whepStatus(a.user, a.password) != 401 else {
                throw SetbeamError.runtime("An admitted viewer's own credential could not read the audience output.")
            }
            print("PASS: under approval, only admitted viewers' own credentials read the audience output (RTSP and WHEP)")

            func reader(_ credential: ViewerReader) async throws -> ManagedChild {
                let child = try ManagedChild(name: "Probe reader", executable: tools.appendingPathComponent("ffmpeg"),
                    arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-rtsp_transport", "tcp", "-i", await url(credential.user, credential.password),
                                "-t", "60", "-f", "null", "-"], directory: directory)
                readers.append(child)
                return child
            }
            let readerA = try await reader(a), readerB = try await reader(b)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            guard readerA.isRunning, readerB.isRunning else { throw SetbeamError.runtime("Admitted readers did not stay connected.") }
            try await runtime.setViewerAccess(approval: true, readers: [b])
            let deadline = Date().addingTimeInterval(5)
            while readerA.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            guard !readerA.isRunning else { throw SetbeamError.runtime("Removing a viewer did not end its active media session.") }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            guard readerB.isRunning else { throw SetbeamError.runtime("Removing one viewer interrupted another.") }
            guard try await !readable(a.user, a.password), try await whepStatus(a.user, a.password) == 401 else {
                throw SetbeamError.runtime("A removed viewer's credential can read media again.")
            }
            let state = await runtime.snapshot()
            guard state.sourceAvailable, state.session.sharing, !state.session.holding else {
                throw SetbeamError.runtime("Viewer removal disturbed local monitoring or sharing.")
            }
            print("PASS: removing one admitted viewer ends its active reader within 5 s, refuses reconnection, and leaves the other reader and local monitoring running")

            try await runtime.setHold(true)
            try await waitFor("holding output") { $0.audienceAvailable && $0.session.holding }
            guard try await readable(b.user, b.password), try await !readable(a.user, a.password) else {
                throw SetbeamError.runtime("Hold changed which viewers can read.")
            }
            try await runtime.setHold(false)
            try await waitFor("resumed output") { $0.audienceAvailable && !$0.session.holding }
            try await testJoinBoundary(runtime: runtime, snapshot: await runtime.snapshot(), keep: b, readable: readable, whepStatus: whepStatus)
            await runtime.stopSharing()
            guard try await !readable(b.user, b.password), await runtime.snapshot().sourceAvailable else {
                throw SetbeamError.runtime("Stop Sharing left a viewer credential usable or interrupted monitoring.")
            }
            print("PASS: Hold keeps admitted access; Stop Sharing revokes every viewer credential while local monitoring continues")
            readers.forEach { $0.stop() }
            await runtime.shutdown()
        } catch {
            readers.forEach { $0.stop() }
            await runtime.shutdown(); throw error
        }

    }

    /// Drives the browser's join and playback-details requests through a real gateway in front of
    /// the real media server, as the app does: a saved name never asks, a request plays only after
    /// Admit with its own reader, Decline stays refused, and Remove refuses that reader again.
    static func testJoinBoundary(runtime: MediaRuntime, snapshot: RuntimeSnapshot, keep: ViewerReader,
                                 readable: (String, String) async throws -> Bool, whepStatus: (String, String) async throws -> Int) async throws {
        let gateway = ViewerGateway(assets: [:])
        gateway.update(ViewerSession(token: "access-probe-link", title: "Access probe", sample: true, state: .live,
                                     playback: snapshot.audience, revision: snapshot.audienceRevision))
        gateway.setAccess(approval: true, pointers: false)
        defer { gateway.stop() }
        let origin = "http://127.0.0.1:\(try await gateway.start(address: "127.0.0.1"))/s/access-probe-link/"
        func call(_ path: String, _ body: [String: Any]? = nil, pass: String? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: origin + path)!, timeoutInterval: 5)
            if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body) }
            if let pass { request.setValue(pass, forHTTPHeaderField: "X-Setbeam-Pass") }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }
        func apply() async throws {
            let readers = gateway.desiredReaders
            try await runtime.setViewerAccess(approval: true, readers: readers.union([keep]))
            gateway.confirm(readers: readers)
        }
        guard try await call("join", ["name": "Sam", "mobile": false]).0 == 400, gateway.viewers.isEmpty else {
            throw SetbeamError.runtime("A saved name started an approval request without Ask to join.")
        }
        let (_, first) = try await call("join", ["name": "Sam", "ask": true, "mobile": false])
        let (_, second) = try await call("join", ["name": "Sam", "ask": true, "mobile": true])
        guard let passA = first["pass"] as? String, let passB = second["pass"] as? String, first["admission"] as? String == "pending",
              let numberA = first["number"] as? Int, let numberB = second["number"] as? Int, numberA != numberB,
              first["user"] == nil, first["whepURL"] == nil else {
            throw SetbeamError.runtime("Two equal names did not become two numbered pending requests.")
        }
        guard try await call("config.json", pass: passA).0 == 403, try await call("join", ["pass": passA, "mobile": false]).1["number"] as? Int == numberA,
              gateway.viewers.count == 2 else {
            throw SetbeamError.runtime("A pending request obtained playback details or a resumed page asked again.")
        }
        print("PASS: through the gateway, a saved name does not ask, Ask to join creates numbered pending requests, and a waiting page gets no playback details")

        gateway.approve(number: numberA); gateway.decline(number: numberB)
        try await apply()
        let (status, config) = try await call("config.json", pass: passA)
        guard status == 200, let user = config["user"] as? String, let password = config["pass"] as? String, user != "guest" else {
            throw SetbeamError.runtime("An admitted request received no playback details of its own (HTTP \(status)).")
        }
        let rtsp = try await readable(user, password), whep = try await whepStatus(user, password)
        guard rtsp, whep != 401 else {
            throw SetbeamError.runtime("An admitted request's own playback details did not read the audience output (RTSP \(rtsp), WHEP \(whep)).")
        }
        guard try await call("config.json", pass: passB).0 == 403, try await call("join", ["pass": passB, "mobile": true]).1["admission"] as? String == "declined" else {
            throw SetbeamError.runtime("A declined request obtained playback details or was readmitted on reload.")
        }
        print("PASS: Admit gives that request its own reader for real RTSP and WHEP playback; Decline stays refused after reload")

        gateway.remove(number: numberA)
        try await apply()
        guard try await call("config.json", pass: passA).0 == 403, try await !readable(user, password), try await whepStatus(user, password) == 401,
              try await readable(keep.user, keep.password) else {
            throw SetbeamError.runtime("Removing an admitted request left its reader usable or interrupted another viewer.")
        }
        print("PASS: Remove refuses that request's playback details and reader while another admitted reader continues")
    }
}
