import XCTest
@testable import SetbeamCore

/// A browser-like presence client using URLSession's own WebSocket implementation.
private final class PresenceSocket: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    init(port: UInt16, token: String, origin: String? = nil) {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/s/\(token)/presence")!)
        request.setValue(origin ?? "http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
        task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        pump()
    }
    func send(_ object: [String: Any]) async throws {
        try await task.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)))
    }
    func sendRaw(_ text: String) async throws { try await task.send(.string(text)) }
    private let lock = NSLock()
    private var inbox: [[String: Any]] = []
    private(set) var closed = false
    /// Receives continuously, so a timed-out wait never leaves a callback that swallows a message.
    private func pump() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
                self.lock.withLock { self.inbox.append(message) }
                self.pump()
            case .success: self.pump()
            case .failure: self.lock.withLock { self.closed = true }
            }
        }
    }
    /// The next message, or nil after the timeout or once the channel closed.
    func receive(timeout: TimeInterval = 2) async -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let (message, ended) = lock.withLock { () -> ([String: Any]?, Bool) in
                inbox.isEmpty ? (nil, closed) : (inbox.removeFirst(), false)
            }
            if let message { return message }
            if ended || Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    /// Skips messages until one satisfies the predicate.
    func first(timeout: TimeInterval = 3, where predicate: ([String: Any]) -> Bool) async -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let message = await receive(timeout: deadline.timeIntervalSinceNow) else { return nil }
            if predicate(message) { return message }
        }
        return nil
    }
    func close() { task.cancel(with: .goingAway, reason: nil) }
}

private final class PointerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[SharedPointer]] = []
    func append(_ value: [SharedPointer]) { lock.withLock { values.append(value) } }
    var last: [SharedPointer]? { lock.withLock { values.last } }
}

final class PresenceChannelTests: XCTestCase {
    private var host: ViewerGateway!
    private var port: UInt16 = 0
    private let token = "presence-test-token"
    private let native = PointerLog()

    private func session(revision: Int = 1, state: AudienceState = .live, token: String? = nil) -> ViewerSession {
        ViewerSession(token: token ?? self.token, title: "Studio", sample: true, state: state,
            playback: PlaybackDescriptor(origin: "http://127.0.0.1:8889", path: "live", user: "guest", password: "shared"), revision: revision)
    }
    override func setUp() async throws {
        host = ViewerGateway(assets: [:])
        host.update(session())
        host.setAccess(approval: false, pointers: true)
        let log = native
        host.onPointers = { log.append($0) }
        port = try await host.start(address: "127.0.0.1")
    }
    override func tearDown() { host.stop(); host = nil }

    private func join(_ name: String? = nil) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/s/\(token)/join")!)
        request.httpMethod = "POST"
        var body: [String: Any] = ["mobile": false]; body["name"] = name
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["pass"] as? String)
    }
    private func participant(_ name: String, color: String = "blue") async throws -> (PresenceSocket, Int) {
        let pass = try await join()
        let socket = PresenceSocket(port: port, token: token)
        try await socket.send(["t": "hello", "pass": pass, "name": name, "color": color])
        let welcome = await socket.first { $0["t"] as? String == "welcome" }
        return (socket, try XCTUnwrap(welcome?["n"] as? Int))
    }
    private func items(_ message: [String: Any]?) -> [[String: Any]] { message?["items"] as? [[String: Any]] ?? [] }

    func testParticipantsShareNamedPointersWithOthersButNotThemselves() async throws {
        let (a, numberA) = try await participant("Sam", color: "pink")
        let (b, numberB) = try await participant("Sam", color: "pink")
        defer { a.close(); b.close() }
        XCTAssertNotEqual(numberA, numberB)
        try await a.send(["t": "move", "x": 0.25, "y": 0.75, "r": 1])
        let seen = await b.first { !self.items($0).isEmpty }
        let item = try XCTUnwrap(items(seen).first)
        XCTAssertEqual(item["n"] as? Int, numberA)
        XCTAssertEqual(item["label"] as? String, "Sam · \(numberA)", "Equal names and colors stay distinguishable")
        XCTAssertEqual(item["color"] as? String, "pink")
        XCTAssertEqual(item["x"] as? Double, 0.25); XCTAssertEqual(item["y"] as? Double, 0.75)
        XCTAssertNil(item["pass"]); XCTAssertNil(item["health"])
        let own = await a.first(timeout: 0.5) { message in self.items(message).contains { $0["n"] as? Int == numberA } }
        XCTAssertNil(own, "A participant is not sent its own pointer")
        // The operator's native overlay receives the same presence.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(native.last?.map(\.number), [numberA])
        XCTAssertEqual(host.viewers.filter(\.pointing).count, 2)
    }

    func testInvalidCoordinatesStaleRevisionsAndOffPictureMovesAreNotShared() async throws {
        let (a, _) = try await participant("Ana")
        let (b, _) = try await participant("Ben")
        defer { a.close(); b.close() }
        for move: [String: Any] in [["x": 1.5, "y": 0.5, "r": 1], ["x": -0.1, "y": 0.5, "r": 1], ["x": "0.5", "y": 0.5, "r": 1],
                                    ["x": true, "y": 0.5, "r": 1], ["x": 0.5, "y": 0.5, "r": 0], ["x": 0.5, "y": 0.5]] {
            var message = move; message["t"] = "move"
            try await a.send(message)
        }
        try await a.sendRaw(#"{"t":"move","x":1e999,"y":0.5,"r":1}"#)
        let leaked = await b.first(timeout: 0.6) { !self.items($0).isEmpty }
        XCTAssertNil(leaked)
        XCTAssertTrue(native.last?.isEmpty ?? true)
    }

    func testHoldPublisherRevisionAndRemovalClearPointers() async throws {
        host.setAccess(approval: true, pointers: true)
        // Under approval, participants need admission first.
        func admitted(_ name: String) async throws -> (PresenceSocket, Int) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/s/\(token)/join")!)
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let pass = try XCTUnwrap(json["pass"] as? String), number = try XCTUnwrap(json["number"] as? Int)
            let early = PresenceSocket(port: port, token: token)
            try await early.send(["t": "hello", "pass": pass, "name": name])
            let denied = await early.first { _ in true }
            XCTAssertEqual(denied?["reason"] as? String, "access", "A waiting request cannot join presence")
            host.approve(number: number); host.confirm(readers: host.desiredReaders)
            let socket = PresenceSocket(port: port, token: token)
            try await socket.send(["t": "hello", "pass": pass, "name": "Renamed"])
            let welcome = await socket.first { $0["t"] as? String == "welcome" }
            XCTAssertEqual(welcome?["name"] as? String, name, "The admitted name is kept")
            return (socket, number)
        }
        let (a, numberA) = try await admitted("Ana")
        let (b, _) = try await admitted("Ben")
        defer { a.close(); b.close() }
        try await a.send(["t": "move", "x": 0.5, "y": 0.5, "r": 1])
        let awaited1 = await b.first { !self.items($0).isEmpty }
        XCTAssertNotNil(awaited1)

        host.update(session(revision: 2))
        let replaced = await b.first { $0["r"] as? Int == 2 }
        XCTAssertEqual(items(replaced).count, 0, "A replacement picture starts without old positions")
        try await a.send(["t": "move", "x": 0.6, "y": 0.6, "r": 1])
        let awaited2 = await b.first(timeout: 0.5) { !self.items($0).isEmpty }
        XCTAssertNil(awaited2, "Late moves for the old picture are dropped")
        try await a.send(["t": "move", "x": 0.6, "y": 0.6, "r": 2])
        let awaited3 = await b.first { !self.items($0).isEmpty }
        XCTAssertNotNil(awaited3)

        host.update(session(revision: 3, state: .holding))
        let awaited4 = await b.first { self.items($0).isEmpty }
        XCTAssertNotNil(awaited4)
        try await a.send(["t": "move", "x": 0.7, "y": 0.7, "r": 3])
        let awaited5 = await b.first(timeout: 0.5) { !self.items($0).isEmpty }
        XCTAssertNil(awaited5, "Nothing is shared during Hold")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(native.last?.isEmpty == true)

        host.update(session(revision: 4))
        try await a.send(["t": "move", "x": 0.2, "y": 0.2, "r": 4])
        let awaited6 = await b.first { !self.items($0).isEmpty }
        XCTAssertNotNil(awaited6)
        XCTAssertTrue(host.remove(number: numberA))
        let awaited7 = await b.first { self.items($0).isEmpty }
        XCTAssertNotNil(awaited7, "Removal clears that pointer for everyone")
        while await a.receive(timeout: 1) != nil {}
        XCTAssertTrue(a.closed, "The removed page's channel is closed")
        XCTAssertFalse(host.viewers.contains { $0.number == numberA })
    }

    func testIdleExpiryNeedsNoFinalHideAndIgnoresRepeatedCoordinates() async throws {
        let (a, _) = try await participant("Ana")
        let (b, _) = try await participant("Ben")
        defer { a.close(); b.close() }
        try await a.send(["t": "move", "x": 0.4, "y": 0.4, "r": 1])
        let shown = await b.first { !self.items($0).isEmpty }
        let ttl = try XCTUnwrap(items(shown).first?["ttl"] as? Int)
        XCTAssertGreaterThan(ttl, 3_000); XCTAssertLessThanOrEqual(ttl, 4_000)
        // Repeat the same position, like a heartbeat, without ever sending hide.
        let started = Date()
        while Date().timeIntervalSince(started) < 4.4 {
            try await a.send(["t": "move", "x": 0.4, "y": 0.4, "r": 1])
            try await a.send(["t": "ping"])
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(native.last?.isEmpty == true, "The server expired the stationary pointer")
        let cleared = await b.first(timeout: 1) { self.items($0).isEmpty }
        XCTAssertNotNil(cleared)
    }

    func testChannelRequiresSameOriginPointerOptionAndBoundedFrames() async throws {
        let pass = try await join()
        let foreign = PresenceSocket(port: port, token: token, origin: "http://attacker.example")
        try? await foreign.send(["t": "hello", "pass": pass, "name": "X"])
        let awaited9 = await foreign.receive(timeout: 1)
        XCTAssertNil(awaited9, "Cross-origin pages cannot open the channel")

        let silent = PresenceSocket(port: port, token: token)
        try await silent.send(["t": "move", "x": 0.5, "y": 0.5, "r": 1])
        let awaited10 = await silent.receive()?["reason"] as? String
        XCTAssertEqual(awaited10, "access", "The first message must authenticate")

        let unnamed = PresenceSocket(port: port, token: token)
        try await unnamed.send(["t": "hello", "pass": pass, "name": "  \n "])
        let awaited11 = await unnamed.receive()?["reason"] as? String
        XCTAssertEqual(awaited11, "name")

        let (large, numberLarge) = try await participant("Ana")
        XCTAssertTrue(host.viewers.contains { $0.number == numberLarge && $0.pointing })
        try? await large.sendRaw(String(repeating: "x", count: 600))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(host.viewers.contains { $0.number == numberLarge && $0.pointing }, "An oversized frame closes the channel")

        host.setAccess(approval: false, pointers: false)
        let off = PresenceSocket(port: port, token: token)
        try? await off.send(["t": "hello", "pass": pass, "name": "Y"])
        let awaited12 = await off.receive(timeout: 1)
        XCTAssertNil(awaited12, "No presence while the operator has pointers off")
    }

    func testFloodingClosesTheChannelWithoutAffectingOthers() async throws {
        let (a, _) = try await participant("Ana")
        let (b, _) = try await participant("Ben")
        defer { a.close(); b.close() }
        for index in 0..<200 { try? await a.send(["t": "move", "x": Double(index % 100) / 100, "y": 0.5, "r": 1]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(host.viewers.filter(\.pointing).count, 1, "The flooding channel was closed")
        // The other participant's channel still works.
        let (c, _) = try await participant("Cy")
        defer { c.close() }
        try await b.send(["t": "move", "x": 0.3, "y": 0.3, "r": 1])
        let awaited13 = await c.first { !self.items($0).isEmpty }
        XCTAssertNotNil(awaited13)
    }

    func testSlowReceiverGetsOnlyTheNewestStateAndAStuckOneIsClosed() async throws {
        let (a, _) = try await participant("Ana")
        let (b, numberB) = try await participant("Ben")
        defer { a.close(); b.close() }
        try await a.send(["t": "move", "x": 0.1, "y": 0.1, "r": 1])
        _ = await b.first { !self.items($0).isEmpty }
        // Hold B's channel as if its previous send had not finished, then keep moving.
        let slow = try XCTUnwrap(host.lock.withLock { host.presenceClients.values.first { $0.number == numberB } })
        host.lock.withLock { slow.sending = true; slow.sendStartedAt = Date() }
        for step in 1...20 {
            try await a.send(["t": "move", "x": Double(step) / 40, "y": 0.5, "r": 1])
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        while await b.receive(timeout: 0.2) != nil {}
        XCTAssertTrue(host.lock.withLock { slow.dirty }, "Updates during a send coalesce into one pending state")
        host.presenceSent(slow, error: nil)
        let next = await b.first { !self.items($0).isEmpty }
        XCTAssertEqual(items(next).first?["x"] as? Double, 0.5, "Only the newest position follows")
        let extra = await b.receive(timeout: 0.3)
        XCTAssertNil(extra, "Nothing older was queued behind it")
        // A receiver whose send never completes is closed rather than buffered.
        host.lock.withLock { slow.sending = true; slow.sendStartedAt = Date().addingTimeInterval(-10) }
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertFalse(host.viewers.contains { $0.number == numberB && $0.pointing })
    }

    func testANewViewingLinkClosesEveryChannel() async throws {
        let (a, _) = try await participant("Ana")
        defer { a.close() }
        host.update(session(revision: 1, token: "another-link"))
        while await a.receive(timeout: 1) != nil {}
        XCTAssertTrue(a.closed, "Channels of the previous link close")
        XCTAssertTrue(host.viewers.isEmpty)
    }
}
