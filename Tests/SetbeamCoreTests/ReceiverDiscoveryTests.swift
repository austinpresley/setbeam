import XCTest
import Darwin
import dnssd
@testable import SetbeamCore

final class ReceiverAdvertisementTests: XCTestCase {
    private let id = String(repeating: "ab", count: 16)
    private let askPath = "/s/\(String(repeating: "c", count: 64))/"

    private func current(open: Bool = true, listener: ShortAddressListener.State = .active, local: LocalAddressState = .active("setbeam"),
                         askPath: String?? = .none, interface: String = "en0", id: String? = nil) -> ReceiverAdvertisement? {
        ReceiverAdvertisement.current(shortAddressOpen: open, listener: listener, localAddress: local,
                                      askPath: askPath ?? self.askPath, interface: interface, installationID: id ?? self.id)
    }

    func testAdvertisesOnlyWhileTypingTheShortAddressWorks() throws {
        let ad = try XCTUnwrap(current())
        XCTAssertEqual(ad, ReceiverAdvertisement(label: "setbeam", scope: .interface("en0"), port: 80, installationID: id))
        XCTAssertEqual(ad.host, "setbeam.local")
        // Every eligibility input withdraws on its own.
        XCTAssertNil(current(open: false), "Short address closed: approval, local address, sharing, or the operator's choice is off")
        for state in [ShortAddressListener.State.stopped, .starting, .unavailable(.inUse), .unavailable(.denied), .unavailable(.unavailable)] {
            XCTAssertNil(current(listener: state), "Port 80 not answering: \(state)")
        }
        for state in [LocalAddressState.stopped, .checking("setbeam"), .unavailable(.inUse), .unavailable(.interface), .unavailable(.service(-1))] {
            XCTAssertNil(current(local: state), "Name not active: \(state)")
        }
        XCTAssertNil(current(askPath: .some(nil)), "No ask-only path for the current link")
        XCTAssertNil(current(interface: "lo0"), "This Mac only is not a network receivers can join")
        XCTAssertNil(current(interface: ""))
        for bad in ["", "AB" + String(repeating: "a", count: 30), String(repeating: "a", count: 31), String(repeating: "g", count: 32)] {
            XCTAssertNil(current(id: bad), bad)
        }
        // A renamed local address advertises the name it actually holds.
        XCTAssertEqual(current(local: .active("setbeam-2"))?.host, "setbeam-2.local")
    }

    func testTXTCarriesOnlyPublicDiscoveryFacts() throws {
        let ad = try XCTUnwrap(current())
        XCTAssertEqual(ad.txt.map(\.key), ["v", "path", "host", "id"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: ad.txt.map { ($0.key, $0.value) }),
                       ["v": "1", "path": "/", "host": "setbeam.local", "id": id])
        // Wire format: length-prefixed key=value strings, parsed back exactly.
        XCTAssertEqual(Self.parse(ad.txtRecord), ["v=1", "path=/", "host=setbeam.local", "id=\(id)"])
        // Nothing a typed name could not already reach: no code, pass, or credential-shaped value.
        let wire = String(decoding: ad.txtRecord, as: UTF8.self)
        XCTAssertFalse(wire.contains(askPath)); XCTAssertFalse(wire.contains("/s/"))
        XCTAssertNil(wire.range(of: "[0-9a-f]{48,}", options: .regularExpression), "No viewing-link token, ask code, or pass")
        XCTAssertEqual(ReceiverAdvertisement.serviceType, "_setbeam._tcp")
    }

    func testInstallationIDsAreRandomLowercaseHex() {
        let first = ReceiverAdvertisement.newInstallationID(), second = ReceiverAdvertisement.newInstallationID()
        XCTAssertTrue(ReceiverAdvertisement.isInstallationID(first)); XCTAssertTrue(ReceiverAdvertisement.isInstallationID(second))
        XCTAssertNotEqual(first, second)
    }

    static func parse(_ data: Data) -> [String] {
        var items: [String] = [], index = data.startIndex
        while index < data.endIndex {
            let length = Int(data[index]); index += 1
            items.append(String(decoding: data[index..<min(index + length, data.endIndex)], as: UTF8.self)); index += length
        }
        return items
    }
}

final class ReceiverDiscoveryPublisherTests: XCTestCase {
    private let ad = ReceiverAdvertisement(label: "setbeam", scope: .interface("en0"), installationID: String(repeating: "0", count: 32))

    func testRegistersOnTheViewingInterfaceAndWithdraws() async throws {
        let registrar = FakeServiceRegistrar()
        let (publisher, states) = make(registrar)
        publisher.publish(ad)
        await publisher.settle()
        XCTAssertEqual(publisher.state, .registering("setbeam"))
        XCTAssertEqual(registrar.live.map(\.interfaceIndex), [7], "Only the selected viewing interface")
        XCTAssertEqual(registrar.live.first?.advertisement.port, 80)
        await registrar.deliver(.registered(name: "setbeam (2)"), on: publisher)
        XCTAssertEqual(publisher.state, .active("setbeam (2)"), "DNS-SD's own rename is reported")
        // Repeating the same advertisement keeps the registration.
        publisher.publish(ad); await publisher.settle()
        XCTAssertEqual(registrar.registrations, 1)

        // A new viewing interface or name replaces it; no stale record remains.
        var moved = ad; moved.scope = .interface("en1")
        publisher.publish(moved); await publisher.settle()
        XCTAssertEqual(registrar.live.map(\.interfaceIndex), [8])
        XCTAssertEqual(registrar.registrations, 2)

        let pending = try XCTUnwrap(registrar.live.first)
        publisher.publish(nil); await publisher.settle()
        XCTAssertEqual(publisher.state, .stopped)
        XCTAssertTrue(registrar.live.isEmpty, "Withdrawal removes the service")
        await withCheckedContinuation { done in pending.queue.async { pending.events(.registered(name: "setbeam")); done.resume() } }
        XCTAssertEqual(publisher.state, .stopped, "A late callback cannot re-advertise")
        XCTAssertEqual(states.values, [.registering("setbeam"), .active("setbeam (2)"), .registering("setbeam"), .stopped])
    }

    func testFailuresAndMissingInterfaceRetryOnlyWhileWanted() async throws {
        let registrar = FakeServiceRegistrar()
        let (publisher, _) = make(registrar, retryDelay: 0.05)
        var missing = ad; missing.scope = .interface("missing0")
        publisher.publish(missing); await publisher.settle()
        XCTAssertEqual(publisher.state, .unavailable(.interface)); XCTAssertEqual(registrar.registrations, 0)

        registrar.refusal = ReceiverServiceRefusal(-65563)
        publisher.publish(ad); await publisher.settle()
        XCTAssertEqual(publisher.state, .unavailable(.service(-65563)))
        registrar.refusal = nil
        try await Task.sleep(nanoseconds: 200_000_000); await publisher.settle()
        XCTAssertEqual(publisher.state, .registering("setbeam"), "Asked again after a bounded delay")

        await registrar.deliver(.failed(-65548), on: publisher)
        XCTAssertEqual(publisher.state, .unavailable(.service(-65548))); XCTAssertTrue(registrar.live.isEmpty)
        publisher.stop(); await publisher.settle()
        try await Task.sleep(nanoseconds: 150_000_000); await publisher.settle()
        XCTAssertEqual(publisher.state, .stopped, "Stop cancels a scheduled retry")
        XCTAssertTrue(registrar.live.isEmpty)
    }

    /// Uses the real system responder, confined to this Mac so the test never announces on the network.
    func testSystemResponderAdvertisesTXTAndForgetsOnStop() async throws {
        let label = "setbeam-test-\(UInt32.random(in: 100_000...999_999))"
        let id = ReceiverAdvertisement.newInstallationID()
        let publisher = ReceiverDiscoveryPublisher()
        defer { publisher.stop() }
        let browser = try LocalServiceBrowser()
        publisher.publish(ReceiverAdvertisement(label: label, scope: .thisMacOnly, installationID: id))
        try await waitFor { publisher.state == .active(label) }
        try await waitFor { browser.names.contains(label) }

        let resolved = try XCTUnwrap(LocalServiceBrowser.resolve(label))
        XCTAssertEqual(resolved.port, 80)
        XCTAssertEqual(resolved.target.lowercased(), "\(label).local.")
        XCTAssertEqual(Set(ReceiverAdvertisementTests.parse(resolved.txt)), ["v=1", "path=/", "host=\(label).local", "id=\(id)"])

        publisher.stop(); await publisher.settle()
        XCTAssertEqual(publisher.state, .stopped)
        try await waitFor { !browser.names.contains(label) }
    }

    private func make(_ registrar: FakeServiceRegistrar, retryDelay: TimeInterval = 60) -> (ReceiverDiscoveryPublisher, DiscoveryStateLog) {
        let publisher = ReceiverDiscoveryPublisher(registrar: registrar, retryDelay: retryDelay,
                                                   resolveInterface: { ["en0": 7, "en1": 8][$0] ?? 0 })
        let log = DiscoveryStateLog()
        publisher.onChange = { log.append($0) }
        return (publisher, log)
    }
}

/// A receiver's whole first contact against the real short-address listener and gateway admission,
/// using only what the advertisement says. Nothing here bypasses the operator.
final class ReceiverAdmissionCompatibilityTests: XCTestCase {
    func testDiscoveredRootLeadsOnlyToAnAskThatWaitsForTheOperator() async throws {
        let token = String(repeating: "7", count: 64)
        let gateway = ViewerGateway(assets: ["viewer.html": Data("viewer".utf8), "expired.html": Data("<html>expired".utf8)])
        func session(_ token: String, revision: Int = 1) -> ViewerSession {
            ViewerSession(token: token, title: "Stage", sample: true, state: .live,
                          playback: PlaybackDescriptor(origin: "http://127.0.0.1:8889", path: "live", user: "guest", password: token), revision: revision)
        }
        gateway.update(session(token))
        let gatewayPort = try await gateway.start(address: "127.0.0.1")
        defer { gateway.stop() }
        let listener = ShortAddressListener(port: 0, retryDelay: 0.2)
        defer { listener.stop() }
        let id = ReceiverAdvertisement.newInstallationID()
        func advertisement(open: Bool) -> ReceiverAdvertisement? {
            ReceiverAdvertisement.current(shortAddressOpen: open, listener: listener.state, localAddress: .active("setbeam-test"),
                                          askPath: gateway.shortAddressPath, interface: "en0", installationID: id)
        }

        // Approval off: the short address cannot open, so nothing is advertised.
        gateway.setShortAddress(open: true)
        XCTAssertNil(advertisement(open: true))
        gateway.setAccess(approval: true, pointers: false)
        gateway.setShortAddress(open: true)
        let askPath = try XCTUnwrap(gateway.shortAddressPath)
        XCTAssertNil(advertisement(open: true), "Not until port 80 is ready")
        listener.serve(.init(address: "127.0.0.1", hosts: ["setbeam-test.local"], port: gatewayPort, path: askPath))
        try await waitFor { listener.state == .active }
        let ad = try XCTUnwrap(advertisement(open: true))
        let rootPort = try XCTUnwrap(listener.boundPort)

        // Root: the advertised host and path give a redirect to the ask-only path, never the link.
        let host = try XCTUnwrap(ad.txt.first { $0.key == "host" }?.value)
        let path = try XCTUnwrap(ad.txt.first { $0.key == "path" }?.value)
        let root = try XCTUnwrap(RawHTTP.exchange(port: rootPort, "GET \(path) HTTP/1.1\r\nHost: \(host)\r\n\r\n"))
        XCTAssertTrue(root.hasPrefix("HTTP/1.1 302 Found\r\n"), root)
        XCTAssertFalse(root.contains(token))
        let location = try XCTUnwrap(RawHTTP.header("Location", in: root))
        XCTAssertEqual(location, "http://\(host):\(gatewayPort)\(askPath)")
        // The numeric viewing address is an accepted Host too, so a receiver can stay off .local resolution.
        let numeric = try XCTUnwrap(RawHTTP.exchange(port: rootPort, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
        XCTAssertEqual(RawHTTP.header("Location", in: numeric), "http://127.0.0.1:\(gatewayPort)\(askPath)")
        let base = "http://127.0.0.1:\(gatewayPort)\(askPath)"

        // A receiver that only shows up does not create a request; it must name itself and ask.
        let (silent, _) = try await request(base + "join", json: ["name": "Stage TV", "mobile": false])
        XCTAssertEqual(silent, 400)
        XCTAssertTrue(gateway.viewers.isEmpty)
        let (asked, body) = try await request(base + "join", json: ["name": "Stage TV", "ask": true, "color": "teal", "mobile": false])
        XCTAssertEqual(asked, 200)
        let joined = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let pass = try XCTUnwrap(joined["pass"] as? String)
        XCTAssertEqual(joined["admission"] as? String, "pending"); XCTAssertEqual(joined["ready"] as? Bool, false)
        XCTAssertEqual(gateway.viewers.map(\.shortAddress), [true])
        let (waiting, refusal) = try await request(base + "config.json", pass: pass)
        XCTAssertEqual(waiting, 403); XCTAssertEqual(refusal, #"{"admission":"pending"}"#)
        // Polling with the pass resumes the same request rather than asking again.
        for _ in 0..<3 { _ = try await request(base + "join", json: ["pass": pass, "mobile": false]) }
        let (_, beat) = try await request(base + "heartbeat", json: ["pass": pass, "playing": false, "health": "connecting", "revision": -1, "mobile": false])
        XCTAssertTrue(beat.contains(#""admission":"pending""#), beat)
        XCTAssertEqual(gateway.viewers.count, 1)

        // Admit: its own read-only user, only after the media server accepts it.
        let number = try XCTUnwrap(joined["number"] as? Int)
        XCTAssertTrue(gateway.approve(number: number))
        let (notReady, _) = try await request(base + "config.json", pass: pass)
        XCTAssertEqual(notReady, 503)
        gateway.confirm(readers: gateway.desiredReaders)
        let (playable, configBody) = try await request(base + "config.json", pass: pass)
        XCTAssertEqual(playable, 200)
        let config = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(configBody.utf8)) as? [String: Any])
        XCTAssertEqual(config["whepURL"] as? String, "http://127.0.0.1:8889/live/whep", "Media stays on the numeric address")
        XCTAssertNotEqual(config["user"] as? String, "guest"); XCTAssertNotEqual(config["pass"] as? String, token)
        XCTAssertFalse(configBody.contains(token))

        // Decline a second receiver: it stays refused however often it comes back with its pass.
        let (_, otherBody) = try await request(base + "join", json: ["name": "Other TV", "ask": true, "mobile": false])
        let other = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(otherBody.utf8)) as? [String: Any])
        XCTAssertTrue(gateway.decline(number: try XCTUnwrap(other["number"] as? Int)))
        let (_, again) = try await request(base + "join", json: ["pass": try XCTUnwrap(other["pass"] as? String), "mobile": false])
        XCTAssertTrue(again.contains(#""admission":"declined""#), again)
        XCTAssertEqual(gateway.viewers.filter { $0.admission == .pending }.count, 0)

        // Remove: the pass is refused at once.
        XCTAssertTrue(gateway.remove(number: number))
        let (removed, removedBody) = try await request(base + "config.json", pass: pass)
        XCTAssertEqual(removed, 403); XCTAssertEqual(removedBody, #"{"admission":"removed"}"#)

        // Closing the short address withdraws discovery and refuses new asks.
        gateway.setShortAddress(open: false)
        XCTAssertNil(advertisement(open: true), "No ask path, no advertisement")
        let (closed, _) = try await request(base + "join", json: ["name": "Late TV", "ask": true, "mobile": false])
        XCTAssertEqual(closed, 404)

        // A new share rotates the ask path; the old one is gone and the root leads to the new one.
        gateway.update(session(String(repeating: "8", count: 64), revision: 2))
        gateway.setShortAddress(open: true)
        let next = try XCTUnwrap(gateway.shortAddressPath)
        XCTAssertNotEqual(next, askPath)
        listener.serve(.init(address: "127.0.0.1", hosts: ["setbeam-test.local"], port: gatewayPort, path: next))
        let (retired, _) = try await request(base + "state.json")
        XCTAssertEqual(retired, 404)
        let rotated = try XCTUnwrap(RawHTTP.exchange(port: rootPort, "GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n"))
        XCTAssertEqual(RawHTTP.header("Location", in: rotated), "http://\(host):\(gatewayPort)\(next)")
        XCTAssertEqual(advertisement(open: true), ad, "The advertisement itself is unchanged by a new share")

        listener.stop()
        XCTAssertNil(advertisement(open: true), "Stopping port 80 withdraws discovery at once")
    }

    private func request(_ url: String, json: [String: Any]? = nil, pass: String? = nil) async throws -> (Int, String) {
        var value = URLRequest(url: URL(string: url)!)
        if let json { value.httpMethod = "POST"; value.httpBody = try JSONSerialization.data(withJSONObject: json)
            value.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let pass { value.setValue(pass, forHTTPHeaderField: "X-Setbeam-Pass") }
        let (data, response) = try await URLSession.shared.data(for: value)
        return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
    }
}

private func waitFor(_ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition() {
        guard Date() < deadline else { XCTFail("Timed out"); throw SetbeamError.unavailable("Timed out") }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

private enum RawHTTP {
    /// Sends one request to 127.0.0.1 and reads until the server closes. Nil when refused.
    static func exchange(port: UInt16, _ request: String) throws -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw SetbeamError.unavailable("socket") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian; target.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { return nil }
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var received = Data(), buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            received.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: received, as: UTF8.self)
    }
    static func header(_ name: String, in response: String) -> String? {
        response.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
            .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
    }
}

private final class FakeServiceRegistrar: ReceiverServiceRegistrar, @unchecked Sendable {
    // Test fake: every property is set once at creation; the queue confines event delivery.
    final class Registration: LocalNameRegistration, @unchecked Sendable {
        let advertisement: ReceiverAdvertisement, interfaceIndex: UInt32, queue: DispatchQueue
        let events: (ReceiverServiceEvent) -> Void
        weak var owner: FakeServiceRegistrar?
        init(_ advertisement: ReceiverAdvertisement, _ index: UInt32, _ queue: DispatchQueue, _ events: @escaping (ReceiverServiceEvent) -> Void) {
            self.advertisement = advertisement; interfaceIndex = index; self.queue = queue; self.events = events
        }
        func cancel() { owner?.remove(self) }
    }
    private let lock = NSLock()
    private var items: [Registration] = []
    private var count = 0
    private var refused: ReceiverServiceRefusal?
    var refusal: ReceiverServiceRefusal? { get { lock.withLock { refused } } set { lock.withLock { refused = newValue } } }
    var live: [Registration] { lock.withLock { items } }
    var registrations: Int { lock.withLock { count } }

    func register(_ advertisement: ReceiverAdvertisement, interfaceIndex: UInt32, queue: DispatchQueue,
                  events: @escaping (ReceiverServiceEvent) -> Void) -> Result<LocalNameRegistration, ReceiverServiceRefusal> {
        if let refusal { return .failure(refusal) }
        let registration = Registration(advertisement, interfaceIndex, queue, events)
        registration.owner = self
        lock.withLock { items.append(registration); count += 1 }
        return .success(registration)
    }
    func remove(_ registration: Registration) { lock.withLock { items.removeAll { $0 === registration } } }
    func deliver(_ event: ReceiverServiceEvent, on publisher: ReceiverDiscoveryPublisher) async {
        guard let target = live.last else { return }
        await withCheckedContinuation { done in target.queue.async { target.events(event); done.resume() } }
        await publisher.settle()
    }
}

private final class DiscoveryStateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ReceiverDiscoveryState] = []
    func append(_ state: ReceiverDiscoveryState) { lock.withLock { items.append(state) } }
    var values: [ReceiverDiscoveryState] { lock.withLock { items } }
}

/// Browses `_setbeam._tcp` on this Mac only, through the system responder, as a receiver would on its network.
private final class LocalServiceBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.setbeam.browse")
    private let lock = NSLock()
    private var found: Set<String> = []
    private var reference: DNSServiceRef?
    var names: Set<String> { lock.withLock { found } }

    init() throws {
        let status = DNSServiceBrowse(&reference, 0, UInt32(kDNSServiceInterfaceIndexLocalOnly), ReceiverAdvertisement.serviceType, "local.",
            { _, flags, _, error, name, _, _, context in
                guard error == kDNSServiceErr_NoError, let name, let context else { return }
                let browser = Unmanaged<LocalServiceBrowser>.fromOpaque(context).takeUnretainedValue()
                let value = String(cString: name)
                browser.lock.withLock {
                    if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 { _ = browser.found.insert(value) } else { browser.found.remove(value) }
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        guard status == kDNSServiceErr_NoError, let reference else { throw SetbeamError.unavailable("browse \(status)") }
        DNSServiceSetDispatchQueue(reference, queue)
    }
    deinit { if let reference { queue.sync { DNSServiceRefDeallocate(reference) } } }

    struct Resolved { var target: String; var port: UInt16; var txt: Data }
    private final class Box: @unchecked Sendable { var value: Resolved?; let done = DispatchSemaphore(value: 0) }

    static func resolve(_ name: String) -> Resolved? {
        let box = Box(), queue = DispatchQueue(label: "test.setbeam.resolve")
        var reference: DNSServiceRef?
        let status = DNSServiceResolve(&reference, 0, UInt32(kDNSServiceInterfaceIndexLocalOnly), name, ReceiverAdvertisement.serviceType, "local.",
            { _, _, _, error, _, target, port, length, txt, context in
                guard let context else { return }
                let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
                if error == kDNSServiceErr_NoError, box.value == nil, let target {
                    box.value = Resolved(target: String(cString: target), port: UInt16(bigEndian: port),
                                         txt: txt.map { Data(bytes: $0, count: Int(length)) } ?? Data())
                    box.done.signal()
                }
            }, Unmanaged.passUnretained(box).toOpaque())
        guard status == kDNSServiceErr_NoError, let reference else { return nil }
        DNSServiceSetDispatchQueue(reference, queue)
        _ = box.done.wait(timeout: .now() + 5)
        queue.sync { DNSServiceRefDeallocate(reference) }
        return queue.sync { box.value }
    }
}
