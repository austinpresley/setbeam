import XCTest
import Darwin
@testable import SetbeamCore

final class ShortAddressReplyTests: XCTestCase {
    private let route = ShortAddressListener.Route(address: "192.168.1.20", hosts: ["setbeam.local"], port: 50_123,
                                                    path: "/s/\(String(repeating: "e", count: 64))/")

    private func reply(_ text: String) -> String {
        String(decoding: ShortAddressListener.reply(to: Data(text.utf8), route: route), as: UTF8.self)
    }

    func testTypedNameIsSentToTheAskOnlyPathOnTheSameHost() {
        let answer = reply("GET / HTTP/1.1\r\nHost: setbeam.local\r\nUser-Agent: test\r\n\r\n")
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 302 Found\r\n"), answer)
        XCTAssertTrue(answer.contains("\r\nLocation: http://setbeam.local:50123/s/\(String(repeating: "e", count: 64))/\r\n"))
        XCTAssertTrue(answer.contains("Cache-Control: no-store"), "A redirect to a per-session path must not be cached")
        XCTAssertTrue(answer.contains("Referrer-Policy: no-referrer"))
        // Case, port 80, a trailing dot, a query, and the numeric address all mean the same place.
        for request in ["GET /?from=qr HTTP/1.1\r\nhost: SetBeam.Local.:80\r\n\r\n", "GET / HTTP/1.0\r\nHost: 192.168.1.20\r\n\r\n"] {
            XCTAssertTrue(reply(request).hasPrefix("HTTP/1.1 302"), request)
        }
        XCTAssertTrue(reply("GET / HTTP/1.1\r\nHost: 192.168.1.20\r\n\r\n").contains("Location: http://192.168.1.20:50123/"))
        let head = reply("HEAD / HTTP/1.1\r\nHost: setbeam.local\r\n\r\n")
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 302") && head.hasSuffix("\r\n\r\n"), "HEAD has no body")
    }

    func testEverythingElseIsRefusedWithoutTheEntryPath() {
        let cases = [
            "GET /viewer.js HTTP/1.1\r\nHost: setbeam.local\r\n\r\n",
            "GET /s/\(String(repeating: "e", count: 64))/ HTTP/1.1\r\nHost: setbeam.local\r\n\r\n",
            "GET /v3/config/global/get HTTP/1.1\r\nHost: setbeam.local\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: attacker.example\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: setbeam.local:8080\r\n\r\n",
            "GET / HTTP/1.1\r\n\r\n",
        ]
        for request in cases {
            let answer = reply(request)
            XCTAssertTrue(answer.hasPrefix("HTTP/1.1 404"), request)
            XCTAssertFalse(answer.contains(String(repeating: "e", count: 64)), "Only a typed name at the root learns the entry path")
        }
        XCTAssertTrue(reply("POST / HTTP/1.1\r\nHost: setbeam.local\r\nContent-Length: 0\r\n\r\n").hasPrefix("HTTP/1.1 405"))
        XCTAssertTrue(reply("GET /\r\n\r\n").hasPrefix("HTTP/1.1 400"))
    }

    /// Review round 1: the parser refuses an oversized header itself, before reading any line of it.
    func testTheParserRefusesHeadersOverTheLimit() {
        let limit = ShortAddressListener.headerLimit
        XCTAssertTrue(reply(ShortAddressListenerTests.request(padTo: limit, host: "setbeam.local")).hasPrefix("HTTP/1.1 302"))
        for size in [limit + 1, 6059] {
            XCTAssertTrue(reply(ShortAddressListenerTests.request(padTo: size, host: "setbeam.local")).hasPrefix("HTTP/1.1 431 "), "\(size) bytes")
        }
        XCTAssertTrue(reply("GET / HTTP/1.1\r\nHost: setbeam.local\r\nX-Pad: \(String(repeating: "p", count: limit))").hasPrefix("HTTP/1.1 431 "),
                      "An unterminated header past the limit is too large, not merely malformed")
    }

    func testPortErrorsAreNamedForTheOperator() {
        XCTAssertEqual(ShortAddressListener.problem(NWErrorFactory.posix(.EADDRINUSE)), .inUse)
        XCTAssertEqual(ShortAddressListener.problem(NWErrorFactory.posix(.EACCES)), .denied)
        XCTAssertEqual(ShortAddressListener.problem(NWErrorFactory.posix(.EPERM)), .denied)
        XCTAssertEqual(ShortAddressListener.problem(NWErrorFactory.posix(.ENETDOWN)), .unavailable)
    }
}

import Network
private enum NWErrorFactory { static func posix(_ code: POSIXErrorCode) -> Error { NWError.posix(code) } }

final class ShortAddressListenerTests: XCTestCase {
    func testAnswersOnlyConnectionsToTheViewingAddressAndStopsAtOnce() async throws {
        let listener = ShortAddressListener(port: 0, retryDelay: 0.2)
        let path = "/s/\(String(repeating: "a", count: 64))/"
        listener.serve(.init(address: "127.0.0.1", hosts: ["setbeam-test.local"], port: 41_000, path: path))
        try await waitUntil { listener.state == .active }
        let port = try XCTUnwrap(listener.boundPort)
        let answer = try XCTUnwrap(try exchange(address: "127.0.0.1", port: port, "GET / HTTP/1.1\r\nHost: setbeam-test.local\r\n\r\n"))
        XCTAssertTrue(answer.contains("Location: http://setbeam-test.local:41000\(path)"), answer)

        // The wildcard listener sees connections to every local address. Only the viewing address is answered.
        if let other = NetworkAddress.available().first(where: { $0.address != "127.0.0.1" }) {
            let refused = try exchange(address: other.address, port: port, "GET / HTTP/1.1\r\nHost: \(other.address)\r\n\r\n")
            XCTAssertEqual(refused, "", "A connection to \(other.interface) must close without a reply")
            // Following the viewing address to another interface moves the answer with it.
            listener.serve(.init(address: other.address, hosts: ["setbeam-test.local"], port: 41_000, path: path))
            XCTAssertEqual(try exchange(address: other.address, port: port, "GET / HTTP/1.1\r\nHost: setbeam-test.local\r\n\r\n")?.hasPrefix("HTTP/1.1 302"), true)
            XCTAssertEqual(try exchange(address: "127.0.0.1", port: port, "GET / HTTP/1.1\r\nHost: setbeam-test.local\r\n\r\n"), "")
        }

        listener.stop()
        XCTAssertEqual(listener.state, .stopped)
        try await waitUntil { (try? self.exchange(address: "127.0.0.1", port: port, "GET / HTTP/1.1\r\nHost: setbeam-test.local\r\n\r\n")) == nil }
    }

    func testAPortHeldByAnotherAppIsReportedAndRetriedWithoutSharingIt() async throws {
        let (holder, port) = try bindWildcard()
        let states = StateLog()
        let listener = ShortAddressListener(port: port, retryDelay: 0.2)
        listener.onChange = { states.append($0) }
        listener.serve(.init(address: "127.0.0.1", hosts: ["setbeam-test.local"], port: 41_000, path: "/s/x/"))
        try await waitUntil { listener.state == .unavailable(.inUse) }
        // While the other app holds the port, nothing from Setbeam answers on it.
        XCTAssertNil(listener.boundPort)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(listener.state, .unavailable(.inUse), "Retries keep reporting the same problem without flapping")
        XCTAssertEqual(states.values.filter { $0 == .starting }.count, 1)
        close(holder)
        try await waitUntil { listener.state == .active }
        XCTAssertEqual(listener.boundPort, port)
        listener.stop()
        try await waitUntil { states.values.last == .stopped }
    }

    func testStopThenServeAgainReusesThePortPromptly() async throws {
        let listener = ShortAddressListener(port: 0, retryDelay: 5)
        listener.serve(.init(address: "127.0.0.1", hosts: ["a.local"], port: 1, path: "/s/x/"))
        try await waitUntil { listener.state == .active }
        let port = try XCTUnwrap(listener.boundPort)
        listener.stop()
        let again = ShortAddressListener(port: port, retryDelay: 5)
        again.serve(.init(address: "127.0.0.1", hosts: ["a.local"], port: 1, path: "/s/x/"))
        try await waitUntil { again.state == .active }
        again.stop()
    }

    func testRepeatedImmediatePortHandoff() async throws {
        let route = ShortAddressListener.Route(address: "127.0.0.1", hosts: ["a.local"], port: 1, path: "/s/x/")
        var listener = ShortAddressListener(port: 0, retryDelay: 5)
        listener.serve(route)
        try await waitUntil { listener.state == .active }
        let port = try XCTUnwrap(listener.boundPort)
        defer { listener.stop() }
        for index in 0..<200 {
            if index % 10 == 0 {
                XCTAssertTrue(try exchange(address: "127.0.0.1", port: port, "GET / HTTP/1.1\r\nHost: a.local\r\n\r\n")?.hasPrefix("HTTP/1.1 302") == true)
            }
            listener.stop()
            listener = ShortAddressListener(port: port, retryDelay: 5)
            listener.serve(route)
            let deadline = ContinuousClock.now + .milliseconds(500)
            while listener.state != .active && ContinuousClock.now < deadline {
                try await Task.sleep(nanoseconds: 100_000)
            }
            XCTAssertEqual(listener.state, .active, "Handoff \(index) must not wait for the five-second occupied-port retry")
            if listener.state != .active { return }
        }
    }

    func testStoppingDuringPortHandoffCancelsTheFastRetry() async throws {
        let (holder, port) = try bindWildcard()
        defer { close(holder) }
        let listener = ShortAddressListener(port: port, retryDelay: 5)
        defer { listener.stop() }
        listener.serve(.init(address: "127.0.0.1", hosts: ["a.local"], port: 1, path: "/s/x/"))
        try await waitUntil { listener.state == .starting }
        listener.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(listener.state, .stopped)
        XCTAssertNil(listener.boundPort)
    }

    /// Review round 1: a request still being read when the viewing address moves must not be answered.
    func testAnOpenRequestIsNotAnsweredAfterTheViewingAddressMoves() async throws {
        let listener = ShortAddressListener(port: 0, retryDelay: 0.2)
        let path = "/s/\(String(repeating: "b", count: 64))/"
        listener.serve(.init(address: "127.0.0.1", hosts: ["setbeam-test.local"], port: 41_000, path: path))
        try await waitUntil { listener.state == .active }
        let port = try XCTUnwrap(listener.boundPort)
        defer { listener.stop() }

        let moved = try RawClient(address: "127.0.0.1", port: port)
        moved.send("GET / HTTP/1.1\r\nHost: setbeam-test.local\r\n")
        // Long enough for the connection to pass the destination check while the old address is selected.
        try await Task.sleep(nanoseconds: 300_000_000)
        listener.serve(.init(address: "127.0.0.2", hosts: ["setbeam-test.local"], port: 41_000, path: path))
        try await Task.sleep(nanoseconds: 100_000_000)
        moved.send("\r\n")
        XCTAssertEqual(moved.readAll(), "", "A connection to an address that is no longer the viewing address must close without a reply")

        // A new name or path at the same address keeps open requests and answers with the current route.
        listener.serve(.init(address: "127.0.0.1", hosts: ["setbeam-test.local"], port: 41_000, path: path))
        let kept = try RawClient(address: "127.0.0.1", port: port)
        kept.send("GET / HTTP/1.1\r\nHost: renamed-test.local\r\n")
        try await Task.sleep(nanoseconds: 300_000_000)
        listener.serve(.init(address: "127.0.0.1", hosts: ["renamed-test.local"], port: 41_000, path: "/s/next/"))
        try await Task.sleep(nanoseconds: 100_000_000)
        kept.send("\r\n")
        XCTAssertTrue(kept.readAll().contains("Location: http://renamed-test.local:41000/s/next/\r\n"))
    }

    /// Review round 1: the 4 KB limit covers the whole header, however it is split into packets.
    func testHeadersOverTheLimitAreRefusedHoweverTheyArrive() async throws {
        let listener = ShortAddressListener(port: 0, retryDelay: 0.2)
        listener.serve(.init(address: "127.0.0.1", hosts: ["setbeam-test.local"], port: 41_000, path: "/s/x/"))
        try await waitUntil { listener.state == .active }
        let port = try XCTUnwrap(listener.boundPort)
        defer { listener.stop() }

        func send(_ request: String, in pieces: Int) async throws -> String {
            let client = try RawClient(address: "127.0.0.1", port: port)
            let bytes = Array(request.utf8), size = (bytes.count + pieces - 1) / pieces
            for start in stride(from: 0, to: bytes.count, by: size) {
                client.send(String(decoding: bytes[start..<min(start + size, bytes.count)], as: UTF8.self))
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            return client.readAll()
        }
        let limit = ShortAddressListener.headerLimit
        for pieces in [1, 7] {
            let fits = try await send(Self.request(padTo: limit), in: pieces)
            XCTAssertTrue(fits.hasPrefix("HTTP/1.1 302"), "A \(limit)-byte header in \(pieces) pieces is within the limit: \(fits.prefix(40))")
            for size in [limit + 1, 6059] {
                let answer = try await send(Self.request(padTo: size), in: pieces)
                XCTAssertFalse(answer.contains("302"), "A \(size)-byte header in \(pieces) pieces must not be redirected")
                // The reply can be lost to a reset when unread bytes remain, but it is never anything else.
                XCTAssertTrue(answer.isEmpty || answer.hasPrefix("HTTP/1.1 431 "), "\(size) bytes, \(pieces) pieces: \(answer.prefix(40))")
            }
        }
    }

    /// A `GET /` for `host` whose header, ending included, is exactly `size` bytes.
    static func request(padTo size: Int, host: String = "setbeam-test.local") -> String {
        let head = "GET / HTTP/1.1\r\nHost: \(host)\r\nX-Pad: ", tail = "\r\n\r\n"
        return head + String(repeating: "p", count: size - head.utf8.count - tail.utf8.count) + tail
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("The short address listener did not reach its expected state")
        throw SetbeamError.unavailable("Timed out")
    }

    /// Sends one request and reads until the server closes. Nil when the connection is refused.
    private func exchange(address: String, port: UInt16, _ request: String) throws -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw SetbeamError.unavailable("socket") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian; target.sin_addr.s_addr = inet_addr(address)
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

    /// Another app's ordinary listener on the IPv4 wildcard address.
    private func bindWildcard() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY; address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw SetbeamError.unavailable("bind") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return (fd, UInt16(bigEndian: address.sin_port))
    }
}

/// A blocking client that can send a request in pieces and read until the server closes.
private final class RawClient {
    private let fd: Int32
    init(address: String, port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw SetbeamError.unavailable("socket") }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian; target.sin_addr.s_addr = inet_addr(address)
        let connected = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { close(fd); throw SetbeamError.unavailable("connect") }
    }
    deinit { close(fd) }
    func send(_ text: String) { _ = text.withCString { Darwin.send(fd, $0, strlen($0), 0) } }
    func readAll() -> String {
        var received = Data(), buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            received.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: received, as: UTF8.self)
    }
}

private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ShortAddressListener.State] = []
    func append(_ state: ShortAddressListener.State) { lock.withLock { items.append(state) } }
    var values: [ShortAddressListener.State] { lock.withLock { items } }
}

final class ShortAddressAdmissionTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 9_000)

    private func joined(_ outcome: ViewerAccessLedger.JoinOutcome, file: StaticString = #filePath, line: UInt = #line) -> ViewerAccessLedger.Record? {
        if case .joined(let record) = outcome { return record }
        XCTFail("Expected a joined session, got \(outcome)", file: file, line: line); return nil
    }

    func testTheShortAddressOnlyAsksAndOnlyWhileOpenUnderApproval() throws {
        var ledger = ViewerAccessLedger()
        ledger.setShortAddress(open: true)
        XCTAssertFalse(ledger.shortAddressOpen, "It never opens without approval")
        guard case .closed = ledger.join(pass: nil, name: "Sam", asking: true, color: nil, mobile: true, local: false, shortAddress: true, now: now) else {
            return XCTFail("With approval off the short address must not admit anyone")
        }
        ledger.setApproval(true)
        guard case .closed = ledger.join(pass: nil, name: "Sam", asking: true, color: nil, mobile: true, local: false, shortAddress: true, now: now) else {
            return XCTFail("Approval alone does not open the short address")
        }
        ledger.setShortAddress(open: true)
        guard case .nameRequired = ledger.join(pass: nil, name: "Sam", color: nil, mobile: true, local: false, shortAddress: true, now: now) else {
            return XCTFail("A request still needs Ask to join")
        }
        let request = try XCTUnwrap(joined(ledger.join(pass: nil, name: "Sam", asking: true, color: .teal, mobile: true, local: false, shortAddress: true, now: now)))
        XCTAssertEqual(request.admission, .pending); XCTAssertTrue(request.shortAddress); XCTAssertFalse(request.mediaReady)
        XCTAssertEqual(ledger.activity(session: nil, now: now).first?.shortAddress, true)
        XCTAssertTrue(ledger.readers.isEmpty)
        XCTAssertTrue(ledger.approve(number: request.number))
        XCTAssertNotNil(ledger.record(request.pass)?.reader, "Admitted short-address viewers play with their own reader")
    }

    func testClosingOrTurningApprovalOffDeclinesWaitingShortAddressRequestsOnly() throws {
        var ledger = ViewerAccessLedger(); ledger.setApproval(true); ledger.setShortAddress(open: true)
        let typed = try XCTUnwrap(joined(ledger.join(pass: nil, name: "Typed", asking: true, color: nil, mobile: true, local: false, shortAddress: true, now: now)))
        let admitted = try XCTUnwrap(joined(ledger.join(pass: nil, name: "Admitted", asking: true, color: nil, mobile: true, local: false, shortAddress: true, now: now)))
        let linked = try XCTUnwrap(joined(ledger.join(pass: nil, name: "Linked", asking: true, color: nil, mobile: false, local: false, now: now)))
        ledger.approve(number: admitted.number)
        ledger.setShortAddress(open: false)
        XCTAssertEqual(ledger.record(typed.pass)?.admission, .declined)
        XCTAssertEqual(ledger.record(admitted.pass)?.admission, .admitted, "The operator's admission stands")
        XCTAssertEqual(ledger.record(linked.pass)?.admission, .pending, "Requests from the link keep waiting")
        // A known pass still resumes through the closed short address; a new tab cannot ask.
        XCTAssertEqual(try XCTUnwrap(joined(ledger.join(pass: admitted.pass, name: nil, color: nil, mobile: true, local: false, shortAddress: true, now: now))).admission, .admitted)
        guard case .closed = ledger.join(pass: nil, name: "Late", asking: true, color: nil, mobile: true, local: false, shortAddress: true, now: now) else { return XCTFail() }

        ledger.setShortAddress(open: true)
        let waiting = try XCTUnwrap(joined(ledger.join(pass: nil, name: "Waiting", asking: true, color: nil, mobile: true, local: false, shortAddress: true, now: now)))
        ledger.setApproval(false)
        XCTAssertFalse(ledger.shortAddressOpen)
        XCTAssertEqual(ledger.record(waiting.pass)?.admission, .declined, "Turning approval off never admits someone who only typed the name")
        XCTAssertEqual(ledger.record(linked.pass)?.admission, .admitted, "Link holders are admitted as before")
        guard case .closed = ledger.join(pass: nil, name: "Late", asking: true, color: nil, mobile: true, local: false, shortAddress: true, now: now) else { return XCTFail() }
        ledger.setApproval(true)
        XCTAssertFalse(ledger.shortAddressOpen, "Turning approval back on waits for the operator's short-address choice")
    }

    func testShortAddressRequestsLeaveRoomForLinkHolders() throws {
        var ledger = ViewerAccessLedger(); ledger.setApproval(true); ledger.setShortAddress(open: true)
        for index in 0..<ViewerAccessLedger.maxShortAddressPending {
            XCTAssertNotNil(joined(ledger.join(pass: nil, name: "T\(index)", asking: true, color: nil, mobile: true, local: false, shortAddress: true, now: now)))
        }
        guard case .full = ledger.join(pass: nil, name: "More", asking: true, color: nil, mobile: true, local: false, shortAddress: true, now: now) else { return XCTFail() }
        XCTAssertNotNil(joined(ledger.join(pass: nil, name: "Link", asking: true, color: nil, mobile: false, local: false, now: now)))
        ledger.reset()
        XCTAssertFalse(ledger.shortAddressOpen, "A new link starts with the short address closed until its owner opens it")
    }
}

final class ShortAddressGatewayTests: XCTestCase {
    func testTheAskOnlyPathNeverRevealsTheViewingLinkAndCloses() async throws {
        let token = String(repeating: "7", count: 64)
        let gateway = ViewerGateway(assets: ["viewer.html": Data("viewer page".utf8), "expired.html": Data("<html>expired".utf8)])
        gateway.update(ViewerSession(token: token, title: "Studio", sample: true, state: .live,
            playback: PlaybackDescriptor(origin: "http://127.0.0.1:8889", path: "live", user: "guest", password: token)))
        let port = try await gateway.start(address: "127.0.0.1")
        defer { gateway.stop() }
        XCTAssertNil(gateway.shortAddressPath, "Closed until approval and the operator's choice")
        gateway.setShortAddress(open: true)
        XCTAssertNil(gateway.shortAddressPath, "Never open without approval")
        gateway.setAccess(approval: true, pointers: false)
        gateway.setShortAddress(open: true)
        let path = try XCTUnwrap(gateway.shortAddressPath)
        XCTAssertFalse(path.contains(token)); XCTAssertEqual(path.count, "/s/".count + 64 + 1)
        let base = "http://127.0.0.1:\(port)\(path)"
        func request(_ url: String, json: [String: Any]? = nil, pass: String? = nil) async throws -> (Int, String) {
            var value = URLRequest(url: URL(string: url)!)
            if let json { value.httpMethod = "POST"; value.httpBody = try JSONSerialization.data(withJSONObject: json) }
            if let pass { value.setValue(pass, forHTTPHeaderField: "X-Setbeam-Pass") }
            let (data, response) = try await URLSession.shared.data(for: value)
            return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
        }
        let (pageStatus, page) = try await request(base)
        XCTAssertEqual(pageStatus, 200); XCTAssertEqual(page, "viewer page")
        let (_, state) = try await request(base + "state.json")
        XCTAssertFalse(state.contains(token)); XCTAssertTrue(state.contains(#""approval":true"#))
        let (joinStatus, joined) = try await request(base + "join", json: ["name": "Sam", "ask": true, "mobile": true])
        XCTAssertEqual(joinStatus, 200); XCTAssertFalse(joined.contains(token))
        let pass = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(joined.utf8)) as? [String: Any])?["pass"] as? String)
        XCTAssertEqual(gateway.viewers.first?.shortAddress, true); XCTAssertEqual(gateway.viewers.first?.admission, .pending)
        let (waiting, refused) = try await request(base + "config.json", pass: pass)
        XCTAssertEqual(waiting, 403); XCTAssertFalse(refused.contains(token))

        // Closing declines the waiting request and refuses new ones; the link itself is unchanged.
        gateway.setShortAddress(open: false)
        XCTAssertNil(gateway.shortAddressPath)
        let (_, beat) = try await request(base + "heartbeat", json: ["pass": pass, "mobile": true])
        XCTAssertTrue(beat.contains(#""admission":"declined""#), beat)
        let (closed, _) = try await request(base + "join", json: ["name": "Kai", "ask": true, "mobile": true])
        XCTAssertEqual(closed, 404, "A closed short address shows the link as no longer active")
        let (linkStatus, _) = try await request("http://127.0.0.1:\(port)/s/\(token)/join", json: ["name": "Ana", "ask": true, "mobile": false])
        XCTAssertEqual(linkStatus, 200)

        // A new link and Stop retire the path, so a typed address learned earlier stops working.
        gateway.setShortAddress(open: true)
        let earlier = try XCTUnwrap(gateway.shortAddressPath)
        gateway.update(ViewerSession(token: String(repeating: "8", count: 64), title: "Studio", sample: true, state: .live,
            playback: PlaybackDescriptor(origin: "http://127.0.0.1:8889", path: "live", user: "guest", password: "next")))
        XCTAssertNil(gateway.shortAddressPath)
        gateway.setShortAddress(open: true)
        XCTAssertNotEqual(gateway.shortAddressPath, earlier)
        let (retired, _) = try await request("http://127.0.0.1:\(port)\(earlier)")
        XCTAssertEqual(retired, 404)
    }
}
