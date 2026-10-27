import XCTest
import Network
@testable import SetbeamCore

final class ViewerGatewayTests: XCTestCase {
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
        func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, Int) {
            var value = URLRequest(url: URL(string: origin + path)!)
            value.httpMethod = method; value.httpBody = body
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
        let (config, _) = try await request(prefix + "config.json")
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: config) as? [String: Any])
        XCTAssertEqual(values["user"] as? String, "guest")
        XCTAssertEqual(values["pass"] as? String, "read-only-test-value")
        XCTAssertEqual(values.count, 5)
        let (_, rejected) = try await request(prefix + "state.json", method: "POST")
        XCTAssertEqual(rejected, 405)
        XCTAssertTrue(host.viewers.isEmpty)
        let body = Data(#"{"id":"browser-test-01","mobile":true,"playing":true,"revision":0}"#.utf8)
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
