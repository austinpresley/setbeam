import XCTest
import Network
import os
@testable import SetbeamCore

final class PyroHDiscoveryTests: XCTestCase {
    static let sdp = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=Test source\r\nt=0 0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=control:track1\r\nm=audio 0 RTP/AVP 97\r\na=rtpmap:97 MPEG4-GENERIC/48000/2\r\n"
    static func response(_ sdp: String = sdp) -> Data {
        Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Type: application/sdp\r\nContent-Length: \(sdp.utf8.count)\r\n\r\n\(sdp)".utf8)
    }

    func testDescriptionRequiresActualH264VideoAndCompleteBoundedRTSPFraming() {
        let valid = Self.response()
        XCTAssertEqual(PyroHDescription.parse(valid), .video(hasAudio: true))
        for size in [0, 7, 30, valid.count - 1] { XCTAssertEqual(PyroHDescription.parse(valid.prefix(size)), .incomplete) }
        let invalid = [
            String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "RTSP/1.0", with: "HTTP/1.1"),
            String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "200 OK", with: "401 Unauthorized"),
            String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "CSeq: 1", with: "CSeq: 2"),
            String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "CSeq: 1", with: "CSeq: 1\r\nCSeq: 1"),
            String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "application/sdp", with: "text/html"),
            "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Type: application/sdp\r\nContent-Length: 32769\r\n\r\n",
            "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Type: application/sdp\r\nContent-Length: -1\r\n\r\n"
        ]
        for value in invalid { XCTAssertEqual(PyroHDescription.parse(Data(value.utf8)), .rejected) }
        XCTAssertEqual(PyroHDescription.parse(Data(repeating: 65, count: 8193)), .rejected)
        XCTAssertEqual(PyroHDescription.parse(Data(repeating: 65, count: 40961)), .rejected)
        XCTAssertEqual(PyroHDescription.parse(Self.response(Self.sdp.replacingOccurrences(of: "H264/90000", with: "H265/90000"))), .rejected)
        XCTAssertEqual(PyroHDescription.parse(Self.response("v=0\r\nm=audio 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n")), .rejected)
        XCTAssertEqual(PyroHDescription.parse(Self.response("v=0\r\nm=video 0 RTP/AVP 97\r\na=rtpmap:96 H264/90000\r\n")), .rejected)
        XCTAssertEqual(PyroHDescription.parse(Self.response("v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n")), .video(hasAudio: false))
    }

    func testRouterSelectionStaysOnActualPrivateWiFiSubnet() {
        XCTAssertTrue(PyroHNetwork.isLocalRouter("192.168.218.1", address: "192.168.218.10", mask: "255.255.255.0"))
        XCTAssertTrue(PyroHNetwork.isLocalRouter("10.0.1.1", address: "10.0.1.10", mask: "255.255.0.0"))
        for router in ["192.168.219.1", "192.168.218.0", "192.168.218.255", "192.168.218.10", "127.0.0.1", "224.0.0.1", "example.com", "192.168.218.1\r\n"] {
            XCTAssertFalse(PyroHNetwork.isLocalRouter(router, address: "192.168.218.10", mask: "255.255.255.0"), router)
        }
        XCTAssertFalse(PyroHNetwork.isLocalRouter("8.8.8.1", address: "8.8.8.2", mask: "255.255.255.0"))
        XCTAssertFalse(PyroHNetwork.isLocalRouter("192.168.218.1", address: "192.168.218.10", mask: "255.0.255.0"))
        XCTAssertFalse(PyroHNetwork.isLocalRouter("192.168.218.1", address: "192.168.218.10", mask: "0.0.0.0"))
    }

    func testProbeTriesFallbackPortAndNeverOpensMediaOrAnotherSuccessfulPort() async throws {
        let wrong = try RTSPFixture(response: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8))
        let good = try RTSPFixture(response: Self.response(), fragmented: true)
        let unused = try RTSPFixture(response: Self.response())
        defer { wrong.stop(); good.stop(); unused.stop() }
        try await wrong.start(); try await good.start(); try await unused.start()
        let network = PyroHNetwork.loopbackFixture
        let found = await PyroHDiscovery.scan(networks: [network, network], ports: [wrong.port, wrong.port, good.port, unused.port], currentNetworks: { [network] })
        XCTAssertEqual(found.count, 1); XCTAssertEqual(found.first?.port, good.port); XCTAssertEqual(found.first?.hasAudio, true)
        XCTAssertEqual(found.first?.address, "rtsp://127.0.0.1:\(good.port)/live")
        try await waitFor { good.snapshot.closed == 1 }
        XCTAssertEqual(wrong.snapshot.requests.count, 1); XCTAssertEqual(unused.snapshot.requests.count, 0)
        let requests = good.snapshot.requests.joined()
        XCTAssertTrue(requests.hasPrefix("DESCRIBE rtsp://127.0.0.1:\(good.port)/live RTSP/1.0\r\n"))
        XCTAssertFalse(requests.contains("SETUP ")); XCTAssertFalse(requests.contains("PLAY "))
    }

    func testStalledProbeHasDeadlineAndCancellationClosesItsOwnedSocket() async throws {
        let server = try RTSPFixture(response: nil)
        defer { server.stop() }
        try await server.start()
        let network = PyroHNetwork.loopbackFixture
        let start = Date()
        let timedOut = await PyroHDiscovery.scan(networks: [network], ports: [server.port], timeout: 0.1, currentNetworks: { [network] })
        XCTAssertTrue(timedOut.isEmpty); XCTAssertLessThan(Date().timeIntervalSince(start), 0.8)
        try await waitFor { server.snapshot.closed == 1 }
        let pending = Task { await PyroHDiscovery.scan(networks: [network], ports: [server.port], timeout: 2, currentNetworks: { [network] }) }
        try await waitFor { server.snapshot.requests.count == 2 }
        let cancelledAt = Date(); pending.cancel()
        let cancelled = await pending.value
        XCTAssertTrue(cancelled.isEmpty); XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.8)
        try await waitFor { server.snapshot.closed == 2 }
        let invalidInterface = PyroHNetwork(interface: "setbeam-no-such-interface", address: "127.0.0.1", router: "127.0.0.1")
        let absent = await PyroHDiscovery.scan(networks: [invalidInterface], ports: [server.port])
        XCTAssertTrue(absent.isEmpty); XCTAssertEqual(server.snapshot.requests.count, 2)
    }

    func testLegacyPyroHSetupCannotFallBackToUnscopedRTSP() throws {
        let data = Data("""
            {"id":"EA60731B-59D0-4EE5-A958-70E22A72C994","kind":"network","name":"Hollyland Pyro H",
            "networkAddress":"rtsp://192.168.218.1:5554/live","sourceWiFi":"","inputPort":19350,"networkProfile":"pyroH"}
            """.utf8)
        let legacy = try JSONDecoder().decode(SourceSetup.self, from: data)
        XCTAssertThrowsError(try legacy.source(address: legacy.networkAddress))
    }

    func testProvenProfileRestoresExactEndpointAndOldSetupsStillDecode() throws {
        let source = PyroHSource(network: wifi, port: 5554, hasAudio: true)
        let suite = "Setbeam-pyro-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProvenSetupStore(defaults: defaults)
        try store.confirm(source.setup)
        let restored = try XCTUnwrap(store.setup)
        XCTAssertEqual(restored.networkProfile, .pyroH)
        XCTAssertEqual(restored.kind, .network)
        XCTAssertThrowsError(try restored.source())
        XCTAssertEqual(restored.pyroHRoute, source.route)
        XCTAssertEqual(try restored.source(address: source.address), .pyroH(source.route))
        XCTAssertThrowsError(try restored.source(address: "rtsp://192.168.218.1:554/live"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        json.removeValue(forKey: "pyroHRoute")
        json.removeValue(forKey: "networkProfile")
        let old = try JSONDecoder().decode(SourceSetup.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.networkProfile); XCTAssertEqual(old.id, restored.id)
        XCTAssertEqual(try old.source(address: source.address), .network(source.address))
        XCTAssertFalse(SessionState().sharing)
    }

    private var wifi: PyroHNetwork {
        .init(interface: "en0", address: "192.168.218.10", router: "192.168.218.1",
              subnetMask: "255.255.255.0", bssid: "00:11:22:33:44:55")
    }

    func testRouteRequiresMatchingInterfaceLocalAddressRouterSubnetAndBSSID() throws {
        let route = PyroHSource(network: wifi, port: 5554, hasAudio: true).route
        func network(interface: String = "en0", address: String = "192.168.218.10", router: String = "192.168.218.1",
                     mask: String = "255.255.255.0", bssid: String? = "00:11:22:33:44:55") -> PyroHNetwork {
            .init(interface: interface, address: address, router: router, subnetMask: mask, bssid: bssid)
        }
        let overlappingEthernet = network(interface: "en1")
        XCTAssertNoThrow(try route.requireCurrent([overlappingEthernet, wifi]))
        for changed in [overlappingEthernet, network(address: "192.168.218.11"), network(router: "192.168.218.2"),
                        network(mask: "255.255.0.0"), network(bssid: "00:11:22:33:44:66")] {
            XCTAssertThrowsError(try route.requireCurrent([changed])) {
                XCTAssertEqual($0.localizedDescription, PyroHRoute.changedWiFi)
            }
        }
        for unavailable in [[], [network(bssid: nil)], [network(bssid: "00:00:00:00:00:00")]] {
            XCTAssertThrowsError(try route.requireCurrent(unavailable)) {
                XCTAssertEqual($0.localizedDescription, PyroHRoute.verifyWiFi)
            }
        }
    }

    func testPlaybackRewritesRequestAndClosesBeforeRelayingARedirect() async throws {
        let redirected = try RTSPFixture(response: Self.response())
        defer { redirected.stop() }
        try await redirected.start()
        let response = Data("RTSP/1.0 302 Moved\r\nCSeq: 1\r\nLocation: rtsp://127.0.0.1:\(redirected.port)/live\r\n\r\n".utf8)
        let upstream = try RTSPFixture(response: response, fragmented: true)
        defer { upstream.stop() }
        try await upstream.start()
        let route = PyroHSource(network: .loopbackFixture, port: upstream.port, hasAudio: false).route
        let playback = try PyroHPlayback(route: route, currentNetworks: { [.loopbackFixture] })
        defer { playback.stop() }
        let port = try XCTUnwrap(URL(string: playback.inputURL)?.port)
        let client = NWConnection(host: "127.0.0.1", port: .init(rawValue: UInt16(port))!, using: .tcp)
        defer { client.cancel() }
        client.start(queue: .global())
        client.send(content: Data("OPTIONS \(playback.inputURL) RTSP/1.0\r\nCSeq: 1\r\n\r\n".utf8), completion: .idempotent)
        let closed = expectation(description: "The redirect closes the private connection")
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { bytes, _, complete, error in
            XCTAssertTrue(bytes?.isEmpty ?? true)
            XCTAssertTrue(complete || error != nil)
            closed.fulfill()
        }
        await fulfillment(of: [closed], timeout: 3)
        XCTAssertEqual(upstream.snapshot.requests, ["OPTIONS \(route.address) RTSP/1.0\r\nCSeq: 1\r\n\r\n"])
        XCTAssertTrue(redirected.snapshot.requests.isEmpty)
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("The RTSP fixture did not reach the expected state.")
    }
}

/// A real TCP peer exercises fragmentation, EOF, and cancellation without transmitter hardware.
private final class RTSPFixture: @unchecked Sendable {
    struct Stats { var requests: [String] = []; var closed = 0 }
    private let stats = OSAllocatedUnfairLock(initialState: Stats())
    private let queue = DispatchQueue(label: "setbeam.tests.rtsp")
    private let listener: NWListener
    private let response: Data?
    private let fragmented: Bool
    private var connections: [NWConnection] = [] // confined to queue
    var port: UInt16 { listener.port!.rawValue }
    var snapshot: Stats { stats.withLock { $0 } }
    init(response: Data?, fragmented: Bool = false) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.response = response; self.fragmented = fragmented
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            let finished = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let result: Result<Void, Error>
                switch state { case .ready: result = .success(()); case .failed(let error): result = .failure(error); default: return }
                if finished.withLock({ let old = $0; $0 = true; return !old }) { completion.resume(with: result) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection); connection.start(queue: self.queue)
                self.receive(connection, bytes: Data())
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            var collected = bytes; if let data { collected.append(data) }
            guard collected.count <= 8192 else { connection.cancel(); return }
            if collected.range(of: Data("\r\n\r\n".utf8)) != nil {
                let request = String(decoding: collected, as: UTF8.self)
                self.stats.withLock { $0.requests.append(request) }
                if let response = self.response {
                    if self.fragmented {
                        connection.send(content: response.prefix(17), completion: .contentProcessed { _ in
                            self.queue.asyncAfter(deadline: .now() + 0.02) {
                                connection.send(content: response.dropFirst(17), completion: .contentProcessed { _ in })
                            }
                        })
                    } else { connection.send(content: response, completion: .contentProcessed { _ in }) }
                }
                self.waitForClose(connection)
            } else if !complete && error == nil { self.receive(connection, bytes: collected) }
            else { self.stats.withLock { $0.closed += 1 }; connection.cancel() }
        }
    }
    private func waitForClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, complete, error in
            guard let self else { return }
            if complete || error != nil { self.stats.withLock { $0.closed += 1 }; connection.cancel() }
            else { self.waitForClose(connection) }
        }
    }
    func stop() { listener.cancel(); queue.sync { connections.forEach { $0.cancel() }; connections = [] } }
}
