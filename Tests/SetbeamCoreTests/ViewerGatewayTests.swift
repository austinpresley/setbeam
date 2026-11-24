import XCTest
import Network
@testable import SetbeamCore

final class ViewerGatewayTests: XCTestCase {
    func testExpiredNavigationHasAGenericSelfContainedPageWithoutGrantingAssetOrAPIAccess() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try Data(contentsOf: root.appendingPathComponent("Sources/SetbeamApp/Resources/expired.html"))
        let host = ViewerGateway(assets: ["expired.html": page, "viewer.html": Data("private viewer".utf8)])
        let port = try await host.start(address: "127.0.0.1")
        defer { host.stop() }
        func request(_ suffix: String) async throws -> (Data, HTTPURLResponse) {
            let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)" + suffix)!)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }
        for configured in [false, true] {
            if configured { host.update(session(token: "current-private-token")) }
            for path in ["/s/old-token/", "/s/old-token/viewer.html"] {
                let (data, response) = try await request(path)
                XCTAssertEqual(response.statusCode, 404)
                XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
                XCTAssertEqual(response.value(forHTTPHeaderField: "Cache-Control"), "no-store")
                XCTAssertEqual(data, page, "The same generic page must not disclose whether a session exists")
                let html = String(decoding: data, as: UTF8.self)
                XCTAssertTrue(html.contains("Ask for the current link or QR code."))
                XCTAssertFalse(html.contains("current-private-token"))
                XCTAssertFalse(html.contains("src=")); XCTAssertFalse(html.contains("href="))
            }
        }
        for path in ["/s/old-token/config.json", "/s/old-token/state.json", "/s/old-token/events", "/s/old-token/viewer.css"] {
            let (data, response) = try await request(path)
            XCTAssertEqual(response.statusCode, 404)
            XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/plain")
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("current-private-token"))
        }
        XCTAssertTrue(host.viewers.isEmpty)
    }

    func testFailedListenerRecoversOnItsOwnWithTheSamePortAndSession() async throws {
        let factory = GatewayListenerFactory()
        let host = ViewerGateway(assets: [:], retryDelay: 0.05, listenerFactory: factory.make)
        let token = UUID().uuidString
        host.update(session(token: token))
        let port = try await host.start(address: "127.0.0.1")
        defer { host.stop() }

        let first = try XCTUnwrap(factory.latest)
        first.cancel()
        // Make no start calls or status reads while the core replaces the failed listener.
        try await waitUntil { factory.count >= 2 }
        let state = try await waitForState(port: port, token: token)
        XCTAssertEqual(state["state"] as? String, "holding")
        XCTAssertEqual(state["revision"] as? Int, 7)
        XCTAssertTrue(host.isRunning)
        XCTAssertEqual(factory.ports.dropFirst(), [port])
        XCTAssertEqual(factory.addresses, ["127.0.0.1", "127.0.0.1"])
    }

    func testInitialFailureKeepsRetryingWithoutAnotherStartCall() async throws {
        let factory = GatewayListenerFactory(failures: 1)
        let host = ViewerGateway(assets: [:], retryDelay: 0.05, listenerFactory: factory.make)
        let token = UUID().uuidString
        host.update(session(token: token))
        let port = try NetworkAddress.freeTCPPort()
        defer { host.stop() }
        do {
            _ = try await host.start(address: "127.0.0.1", port: port)
            XCTFail("The first listener construction should report its failure")
        } catch {
            XCTAssertEqual(error as? SetbeamError, .unavailable("Synthetic listener failure"))
        }
        let state = try await waitForState(port: port, token: token)
        XCTAssertEqual(state["title"] as? String, "Studio")
        XCTAssertEqual(factory.ports, [port, port])
        XCTAssertEqual(factory.addresses, ["127.0.0.1", "127.0.0.1"])
    }

    func testStopCancelsScheduledRecoveryAndIgnoresOldListenerCallbacks() async throws {
        let factory = GatewayListenerFactory()
        let host = ViewerGateway(assets: [:], retryDelay: 0.25, listenerFactory: factory.make)
        _ = try await host.start(address: "127.0.0.1")
        try XCTUnwrap(factory.latest).cancel()
        try await waitUntil { !host.isRunning }
        host.stop()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(host.isRunning)
        XCTAssertEqual(factory.count, 1, "A stopped gateway must not create a recovery listener")
    }

    func testNewStartReplacesTheAddressAndPortOfAPendingRecovery() async throws {
        let factory = GatewayListenerFactory(failures: 1)
        let host = ViewerGateway(assets: [:], retryDelay: 0.25, listenerFactory: factory.make)
        let oldPort = try NetworkAddress.freeTCPPort()
        do {
            _ = try await host.start(address: "127.0.0.2", port: oldPort)
            XCTFail("The injected first listener should fail")
        } catch { }
        let token = UUID().uuidString
        host.update(session(token: token))
        let port = try await host.start(address: "127.0.0.1")
        defer { host.stop() }
        _ = try await waitForState(port: port, token: token)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(factory.count, 2, "The replaced request must not revive its listener")
        XCTAssertEqual(factory.addresses, ["127.0.0.2", "127.0.0.1"])
    }

    func testStartupTimeoutIsBoundedAndStopCancelsItsRecovery() async throws {
        let factory = GatewayListenerFactory()
        let host = ViewerGateway(assets: [:], retryDelay: 0.25, startupTimeout: 0.05, listenerFactory: factory.make)
        let began = Date()
        do {
            _ = try await host.start(address: "192.0.2.1", port: try NetworkAddress.freeTCPPort())
            XCTFail("An address not assigned to this Mac must not become ready")
        } catch { }
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
        host.stop()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(host.isRunning)
        XCTAssertEqual(factory.count, 1)
    }

    func testReplacingAWaitingStartDoesNotLetItsDeadlineStopTheNewListener() async throws {
        let factory = GatewayListenerFactory()
        let host = ViewerGateway(assets: [:], retryDelay: 0.25, startupTimeout: 0.15, listenerFactory: factory.make)
        let waiting = Task { try await host.start(address: "192.0.2.1", port: try NetworkAddress.freeTCPPort()) }
        try await waitUntil { factory.count == 1 }
        let token = UUID().uuidString
        host.update(session(token: token))
        let port = try await host.start(address: "127.0.0.1")
        defer { host.stop() }
        do {
            _ = try await waiting.value
            XCTFail("The replaced start must finish with an error")
        } catch { }
        try await Task.sleep(nanoseconds: 400_000_000)
        _ = try await waitForState(port: port, token: token)
        XCTAssertTrue(host.isRunning)
        XCTAssertEqual(factory.count, 2)
    }

    func testStopCompletesAWaitingStartAndPreventsItsDeadlineFromRetrying() async throws {
        let factory = GatewayListenerFactory()
        let host = ViewerGateway(assets: [:], retryDelay: 0.1, startupTimeout: 0.15, listenerFactory: factory.make)
        let waiting = Task { try await host.start(address: "192.0.2.1", port: try NetworkAddress.freeTCPPort()) }
        try await waitUntil { factory.count == 1 }
        host.stop()
        do {
            _ = try await waiting.value
            XCTFail("Stop must finish the waiting start with an error")
        } catch { }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(host.isRunning)
        XCTAssertEqual(factory.count, 1)
    }

    func testAutonomousRecoveryDoesNotRetainTheGateway() async throws {
        let factory = GatewayListenerFactory(failures: 1)
        var host: ViewerGateway? = ViewerGateway(assets: [:], retryDelay: 0.25, listenerFactory: factory.make)
        weak let released = host
        do { _ = try await host?.start(address: "127.0.0.1") } catch { }
        host = nil
        // The start continuation can resume before its queue callback releases the
        // temporary receiver. A retained retry loop must still fail this deadline.
        let deadline = Date().addingTimeInterval(1)
        while released != nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(released)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(factory.count, 1)
    }

    func testListenerRestartKeepsThePortAndSession() async throws {
        let host = ViewerGateway(assets: ["viewer.html": Data("viewer".utf8)])
        let token = UUID().uuidString
        host.update(ViewerSession(token: token, title: "Studio", sample: true, state: .holding,
            playback: PlaybackDescriptor(origin: "http://127.0.0.1:8889", path: "live", user: "guest", password: "synthetic")))
        let port = try await host.start(address: "127.0.0.1")
        defer { host.stop() }
        host.stop()
        let restored = try await host.start(address: "127.0.0.1", port: port)
        XCTAssertEqual(restored, port)
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/s/\(token)/state.json")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(state["state"] as? String, "holding")
        XCTAssertTrue(host.isRunning)
    }

    func testViewerRoutesAndReadOnlyCredentialBoundary() async throws {
        let host = ViewerGateway(assets: ["viewer.html": Data("sample viewer".utf8)])
        let token = UUID().uuidString
        host.update(ViewerSession(token: token, title: "Studio", sample: true, state: .live,
            playback: PlaybackDescriptor(origin: "http://127.0.0.1:8889", path: "live", user: "guest", password: "read-only-test-value")))
        let port = try await host.start(address: "127.0.0.1")
        defer { host.stop() }
        let origin = "http://127.0.0.1:\(port)"
        func request(_ path: String, method: String = "GET", body: Data? = nil, pass: String? = nil) async throws -> (Data, Int) {
            var value = URLRequest(url: URL(string: origin + path)!)
            value.httpMethod = method; value.httpBody = body
            if let pass { value.setValue(pass, forHTTPHeaderField: "X-Setbeam-Pass") }
            let (data, response) = try await URLSession.shared.data(for: value)
            return (data, (response as! HTTPURLResponse).statusCode)
        }
        for path in ["/", "/config.json", "/v3/config/global/get", "/s/wrong/", "/s/\(token)/LICENSE", "/s/\(token)/%2e%2e/config.json"] {
            let (_, status) = try await request(path)
            XCTAssertEqual(status, 404, path)
        }
        let prefix = "/s/\(token)/"
        let (html, status) = try await request(prefix)
        XCTAssertEqual(status, 200); XCTAssertEqual(String(decoding: html, as: UTF8.self), "sample viewer")
        let (_, withoutPass) = try await request(prefix + "config.json")
        XCTAssertEqual(withoutPass, 403, "Playback details need a gateway-issued pass")
        let (joined, _) = try await request(prefix + "join", method: "POST", body: Data(#"{"mobile":true}"#.utf8))
        let pass = try XCTUnwrap((JSONSerialization.jsonObject(with: joined) as? [String: Any])?["pass"] as? String)
        let (config, _) = try await request(prefix + "config.json", pass: pass)
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: config) as? [String: Any])
        XCTAssertEqual(values["user"] as? String, "guest")
        XCTAssertEqual(values["pass"] as? String, "read-only-test-value")
        XCTAssertEqual(values["revision"] as? Int, 0)
        let initialState = try await waitForState(port: port, token: token)
        XCTAssertEqual(values["sequence"] as? Int, initialState["sequence"] as? Int)
        let (_, rejected) = try await request(prefix + "state.json", method: "POST")
        XCTAssertEqual(rejected, 405)
        let body = Data(#"{"pass":"\#(pass)","mobile":true,"playing":true,"revision":0}"#.utf8)
        _ = try await request(prefix + "heartbeat", method: "POST", body: body)
        XCTAssertEqual(host.viewers.count, 1); XCTAssertEqual(host.viewers.first?.playing, true)
        XCTAssertEqual(host.viewers.first?.onThisMac, true, "A local mobile-emulated browser must not count as another device")
        host.update(ViewerSession(token: token, title: "Studio", sample: true, state: .live,
            playback: PlaybackDescriptor(origin: "http://127.0.0.1:8889", path: "live", user: "guest", password: "read-only-test-value"), revision: 1))
        XCTAssertEqual(host.viewers.first?.playing, false, "Playback of an old source revision must not pass the setup check")
        host.update(ViewerSession(token: "rotated-session", title: "Studio", sample: true, state: .stopped,
            playback: PlaybackDescriptor(origin: "http://127.0.0.1:8889", path: "live", user: "guest", password: "rotated")))
        let (_, expired) = try await request(prefix + "config.json")
        XCTAssertEqual(expired, 404)
    }

    func testStateStreamPushesChangesAndOutlivesTheRequestDeadline() async throws {
        let host = ViewerGateway(assets: [:], retryDelay: 0.05, requestTimeout: 0.3, keepaliveInterval: 0.4) { try NWListener(using: $0, on: $1) }
        let token = UUID().uuidString
        host.update(session(token: token))
        let port = try await host.start(address: "127.0.0.1")
        defer { host.stop() }
        let stream = try await StateStream(port: port, token: token)
        XCTAssertEqual(stream.status, 200)
        XCTAssertEqual(stream.contentType, "text/event-stream")
        let initial = try await stream.next()
        XCTAssertEqual(initial?["state"] as? String, "holding")
        XCTAssertEqual(initial?["revision"] as? Int, 7)
        let initialSequence = try XCTUnwrap(initial?["sequence"] as? Int)
        var live = session(token: token); live.state = .live; live.revision = 8
        host.update(live)
        let pushed = try await stream.next()
        XCTAssertEqual(pushed?["state"] as? String, "live")
        XCTAssertEqual(pushed?["revision"] as? Int, 8)
        let publishedSequence = try XCTUnwrap(pushed?["sequence"] as? Int)
        XCTAssertGreaterThan(publishedSequence, initialSequence)
        host.update(live)
        // Keepalives keep arriving well after an ordinary request would have been closed.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let keepalive = try await stream.next()
        XCTAssertEqual(keepalive?["state"] as? String, "live")
        XCTAssertEqual(keepalive?["sequence"] as? Int, publishedSequence)
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/s/\(token)/state.json")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Polling remains available as the fallback")
    }

    func testStateStreamCoalescesWhileSendingAndClosesAtTheDeadline() async throws {
        let host = ViewerGateway(assets: [:], retryDelay: 0.05, keepaliveInterval: 0.1) { try NWListener(using: $0, on: $1) }
        let token = UUID().uuidString
        host.update(session(token: token))
        let port = try await host.start(address: "127.0.0.1")
        defer { host.stop() }
        let stream = try await StateStream(port: port, token: token)
        let initial = try await stream.next()
        let initialSequence = try XCTUnwrap(initial?["sequence"] as? Int)
        try await waitUntil { host.lock.withLock { host.streams.values.first?.deadline == nil } }
        let sender = try XCTUnwrap(host.lock.withLock { host.streams.values.first })
        host.lock.withLock { sender.deadline = .now() + 5 }
        host.setAccess(approval: true, pointers: true)
        for revision in 8...24 {
            var next = session(token: token)
            next.revision = revision
            host.update(next)
        }
        XCTAssertTrue(host.lock.withLock { sender.dirty })
        host.stateSent(sender, error: nil)
        let latest = try await stream.next()
        XCTAssertEqual(latest?["revision"] as? Int, 24)
        XCTAssertEqual(latest?["approval"] as? Bool, true)
        XCTAssertEqual(latest?["sequence"] as? Int, initialSequence + 18)
        try await waitUntil { host.lock.withLock { sender.deadline == nil } }
        host.lock.withLock { sender.deadline = .now() - 1 }
        try await waitUntil { host.lock.withLock { host.streams.isEmpty } }
    }

    func testBindingReplacementClosesOldStreamsAndKeepsTheShare() async throws {
        let host = ViewerGateway(assets: [:])
        let token = UUID().uuidString
        host.update(session(token: token))
        host.setAccess(approval: true, pointers: false)
        host.setShortAddress(open: true)
        XCTAssertNil(host.readyBinding)
        let firstPort = try await host.start(address: "127.0.0.1")
        defer { host.stop() }
        let first = try XCTUnwrap(host.readyBinding)
        XCTAssertEqual(first.address, "127.0.0.1")
        XCTAssertEqual(first.port, firstPort)
        XCTAssertNotNil(first.shortAddressPath)
        let stream = try await StateStream(port: firstPort, token: token)
        _ = try await stream.next()
        let nextPort = try await host.start(address: "127.0.0.1", port: NetworkAddress.freeTCPPort())
        let next = try XCTUnwrap(host.readyBinding)
        XCTAssertNotEqual(first.id, next.id)
        XCTAssertEqual(next.port, nextPort)
        XCTAssertEqual(next.shortAddressPath, first.shortAddressPath)
        let closed = try await stream.next()
        XCTAssertNil(closed)
        _ = try await waitForState(port: nextPort, token: token)
        host.stop()
        XCTAssertNil(host.readyBinding)
        XCTAssertNil(host.shortAddressPath)
    }

    func testTokenChangeAndStopCloseStateStreams() async throws {
        let host = ViewerGateway(assets: [:], retryDelay: 0.05, requestTimeout: 0.3) { try NWListener(using: $0, on: $1) }
        let token = UUID().uuidString
        host.update(session(token: token))
        let port = try await host.start(address: "127.0.0.1")
        defer { host.stop() }
        let rotated = try await StateStream(port: port, token: token)
        _ = try await rotated.next()
        let current = UUID().uuidString
        host.update(session(token: current))
        let afterRotation = try await rotated.next()
        XCTAssertNil(afterRotation, "A replaced viewing link must end its open streams")
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/s/\(token)/events")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)

        let stopped = try await StateStream(port: port, token: current)
        _ = try await stopped.next()
        host.stop()
        let afterStop = try await stopped.next()
        XCTAssertNil(afterStop, "Stop must end open streams")
    }

    func testStateStreamCapFallsBackToPolling() async throws {
        let host = ViewerGateway(assets: [:], retryDelay: 0.05, maxStreams: 1) { try NWListener(using: $0, on: $1) }
        let token = UUID().uuidString
        host.update(session(token: token))
        let port = try await host.start(address: "127.0.0.1")
        defer { host.stop() }
        let first = try await StateStream(port: port, token: token)
        _ = try await first.next()
        let second = try await StateStream(port: port, token: token)
        XCTAssertEqual(second.status, 503)
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/s/\(token)/state.json")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testOrdinaryConnectionBudgetIsReleasedAfterTheRequestDeadline() async throws {
        let host = ViewerGateway(assets: [:], retryDelay: 0.05, requestTimeout: 0.4, maxRequests: 1) {
            try NWListener(using: $0, on: $1)
        }
        let token = UUID().uuidString
        host.update(session(token: token))
        let port = try await host.start(address: "127.0.0.1")
        defer { host.stop() }
        let state = try await StateStream(port: port, token: token)
        _ = try await state.next()
        let endpoint = NWEndpoint.Port(rawValue: port)!
        let queue = DispatchQueue(label: "test.viewer.request-budget")
        let incomplete = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
        defer { incomplete.cancel() }
        incomplete.start(queue: queue)
        incomplete.send(content: Data("GET /s/".utf8), completion: .contentProcessed { _ in })
        try await waitUntil { host.ordinaryConnectionCount == 1 }

        let excess = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
        defer { excess.cancel() }
        let closed = expectation(description: "connection above the cap closes")
        excess.start(queue: queue)
        excess.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, complete, error in
            XCTAssertNil(data)
            XCTAssertTrue(complete || error != nil)
            closed.fulfill()
        }
        await fulfillment(of: [closed], timeout: 2)
        try await waitUntil { host.ordinaryConnectionCount == 0 }
        _ = try await waitForState(port: port, token: token)
    }

    func testJoinRetriesAndOperatorActionsStayScopedToTheirShare() async throws {
        let host = ViewerGateway(assets: [:])
        let first = UUID().uuidString, second = UUID().uuidString
        host.update(session(token: first))
        host.setAccess(approval: true, pointers: false)
        let port = try await host.start(address: "127.0.0.1")
        defer { host.stop() }
        let id = UUID().uuidString
        func ask(_ token: String) async throws -> String {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/s/\(token)/join")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["ask": true, "name": "Sam", "requestID": id])
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["pass"] as? String)
        }
        let pass = try await ask(first)
        let retry = try await ask(first)
        XCTAssertEqual(pass, retry)
        XCTAssertEqual(host.viewers.count, 1)
        let stale = try XCTUnwrap(host.viewers.first)
        host.update(session(token: second))
        let currentPass = try await ask(second)
        XCTAssertNotEqual(currentPass, pass)
        let current = try XCTUnwrap(host.viewers.first)
        XCTAssertEqual(stale.number, current.number)
        XCTAssertFalse(host.approve(stale))
        XCTAssertFalse(host.decline(stale))
        XCTAssertTrue(host.approve(current))
        XCTAssertFalse(host.remove(stale))
        XCTAssertTrue(host.remove(current))
    }

    private func session(token: String) -> ViewerSession {
        ViewerSession(token: token, title: "Studio", sample: true, state: .holding,
            playback: PlaybackDescriptor(origin: "http://127.0.0.1:8889", path: "live", user: "guest", password: "synthetic"), revision: 7)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("The listener did not reach its expected state")
        throw SetbeamError.unavailable("Timed out waiting for listener recovery")
    }

    private func waitForState(port: UInt16, token: String) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/s/\(token)/state.json")!)
            request.timeoutInterval = 0.25
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return state }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("The original viewing link did not recover")
        throw SetbeamError.unavailable("Timed out waiting for listener recovery")
    }
}

private final class GatewayListenerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [NWListener] = []
    private var requestedPorts: [UInt16] = []
    private var requestedAddresses: [String] = []
    private var failures: Int
    init(failures: Int = 0) { self.failures = failures }
    var latest: NWListener? { lock.withLock { listeners.last } }
    var count: Int { lock.withLock { requestedPorts.count } }
    var ports: [UInt16] { lock.withLock { requestedPorts } }
    var addresses: [String] { lock.withLock { requestedAddresses } }

    func make(_ parameters: NWParameters, _ port: NWEndpoint.Port) throws -> NWListener {
        let fail = lock.withLock {
            requestedPorts.append(port.rawValue)
            if case .hostPort(let host, _) = parameters.requiredLocalEndpoint { requestedAddresses.append(String(describing: host)) }
            if failures > 0 { failures -= 1; return true }
            return false
        }
        if fail { throw SetbeamError.unavailable("Synthetic listener failure") }
        let listener = try NWListener(using: parameters, on: port)
        lock.withLock { listeners.append(listener) }
        return listener
    }
}

/// Reads server-sent state events with a bounded wait per event.
private final class StateStream: @unchecked Sendable {
    let status: Int
    let contentType: String?
    private var lines: AsyncLineSequence<URLSession.AsyncBytes>.AsyncIterator

    init(port: UInt16, token: String) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/s/\(token)/events?id=stream-test-01")!)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        status = http.statusCode
        contentType = http.value(forHTTPHeaderField: "Content-Type")
        lines = bytes.lines.makeAsyncIterator()
    }

    /// The next state object, or nil when the server ended the stream.
    func next(timeout: TimeInterval = 3) async throws -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let line: String?
            do { line = try await nextLine(timeout: deadline.timeIntervalSinceNow) } catch is CancellationError { break } catch { return nil }
            guard let line else { return nil }
            guard line.hasPrefix("data: ") else { continue }
            return try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any]
        }
        XCTFail("No state event arrived in time")
        throw SetbeamError.unavailable("Timed out waiting for a state event")
    }

    private func nextLine(timeout: TimeInterval) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { [self] in try await self.lines.next() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                throw CancellationError()
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }
}
