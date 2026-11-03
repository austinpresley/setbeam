import XCTest
import Darwin
@testable import SetbeamCore

final class LocalAddressTests: XCTestCase {
    func testNamesAcceptPortableHostLabelsOnly() {
        XCTAssertEqual(try LocalAddressName.validated("  Stage-A ").get(), "stage-a")
        XCTAssertEqual(try LocalAddressName.validated("dit2.local").get(), "dit2")
        XCTAssertEqual(try LocalAddressName.validated("DIT2.LOCAL.").get(), "dit2")
        XCTAssertEqual(try LocalAddressName.validated(String(repeating: "a", count: 40)).get().count, 40)
        XCTAssertEqual(LocalAddressName.validated(""), .failure(.empty))
        XCTAssertEqual(LocalAddressName.validated(".local"), .failure(.empty))
        XCTAssertEqual(LocalAddressName.validated(String(repeating: "a", count: 41)), .failure(.tooLong))
        for bad in ["stage a", "stage_a", "stage.a", "café", "stage/a", "set:beam", "ａｂ"] {
            XCTAssertEqual(LocalAddressName.validated(bad), .failure(.characters), bad)
        }
        XCTAssertEqual(LocalAddressName.validated("-stage"), .failure(.hyphenEdge))
        XCTAssertEqual(LocalAddressName.validated("stage-"), .failure(.hyphenEdge))
        XCTAssertEqual(LocalAddressName.candidate("setbeam", attempt: 1), "setbeam")
        XCTAssertEqual(LocalAddressName.candidate("setbeam", attempt: 2), "setbeam-2")
        XCTAssertEqual(LocalAddressName.host("setbeam-2"), "setbeam-2.local")
    }

    func testConflictsTryNumberedAlternativesThenReportInUse() async {
        let registrar = FakeRegistrar()
        registrar.refuse = ["setbeam.local": .conflict]
        let (publisher, states) = make(registrar, maxCandidates: 3)
        publisher.publish(label: "setbeam", scope: .interface("en0"), address: "192.168.1.20")
        await publisher.settle()
        XCTAssertEqual(publisher.state, .checking("setbeam-2"), "A synchronous conflict moves straight to the next name")
        await registrar.deliver(.conflict, to: "setbeam-2.local", on: publisher)
        XCTAssertEqual(publisher.state, .checking("setbeam-3"))
        await registrar.deliver(.registered, to: "setbeam-3.local", on: publisher)
        XCTAssertEqual(publisher.state, .active("setbeam-3"))
        XCTAssertEqual(registrar.live.map(\.host), ["setbeam-3.local"], "Only the held name stays registered")
        XCTAssertEqual(registrar.live.first?.interfaceIndex, 7, "The record answers on the selected interface only")
        XCTAssertEqual(registrar.live.first?.address, "192.168.1.20")

        // Another Mac claims the name later. The held name must be given up and the next tried.
        await registrar.deliver(.conflict, to: "setbeam-3.local", on: publisher)
        XCTAssertEqual(publisher.state, .unavailable(.inUse), "Every allowed alternative was taken")
        XCTAssertTrue(registrar.live.isEmpty)
        XCTAssertEqual(states.values, [.checking("setbeam-2"), .checking("setbeam-3"), .active("setbeam-3"), .unavailable(.inUse)])
    }

    func testAddressChangeKeepsHeldNameAndRenameStartsOver() async {
        let registrar = FakeRegistrar()
        let (publisher, _) = make(registrar)
        publisher.publish(label: "setbeam", scope: .interface("en0"), address: "192.168.1.20")
        await publisher.settle()
        await registrar.deliver(.conflict, to: "setbeam.local", on: publisher)
        await registrar.deliver(.registered, to: "setbeam-2.local", on: publisher)
        // A repeated identical request keeps the registration.
        publisher.publish(label: "setbeam", scope: .interface("en0"), address: "192.168.1.20")
        await publisher.settle()
        XCTAssertEqual(registrar.registrations, 2)
        // DHCP moved the Mac. Links already sent with setbeam-2 should keep their name.
        publisher.publish(label: "setbeam", scope: .interface("en0"), address: "192.168.1.44")
        await publisher.settle()
        XCTAssertEqual(publisher.state, .checking("setbeam-2"))
        XCTAssertEqual(registrar.live.map(\.address), ["192.168.1.44"])
        await registrar.deliver(.registered, to: "setbeam-2.local", on: publisher)
        XCTAssertEqual(publisher.state, .active("setbeam-2"))
        // A new operator name starts again from the plain name.
        publisher.publish(label: "stage", scope: .interface("en0"), address: "192.168.1.44")
        await publisher.settle()
        XCTAssertEqual(publisher.state, .checking("stage"))
        XCTAssertEqual(registrar.live.map(\.host), ["stage.local"])
    }

    func testStopRemovesTheRecordAndIgnoresLateCallbacks() async {
        let registrar = FakeRegistrar()
        let (publisher, _) = make(registrar)
        publisher.publish(label: "setbeam", scope: .interface("en0"), address: "192.168.1.20")
        await publisher.settle()
        let pending = registrar.live.first!
        publisher.stop()
        await publisher.settle()
        XCTAssertEqual(publisher.state, .stopped)
        XCTAssertTrue(registrar.live.isEmpty)
        await withCheckedContinuation { done in pending.queue.async { pending.events(.registered); done.resume() } }
        XCTAssertEqual(publisher.state, .stopped, "A callback for a removed record cannot make the name active again")
    }

    func testServiceFailureAndMissingInterfaceFallBackAndRetry() async throws {
        let registrar = FakeRegistrar()
        let (publisher, _) = make(registrar, retryDelay: 0.05)
        publisher.publish(label: "setbeam", scope: .interface("missing0"), address: "192.168.1.20")
        await publisher.settle()
        XCTAssertEqual(publisher.state, .unavailable(.interface))
        XCTAssertEqual(registrar.registrations, 0)
        publisher.publish(label: "setbeam", scope: .interface("en0"), address: "192.168.1.20")
        await publisher.settle()
        await registrar.deliver(.failed(-65563), to: "setbeam.local", on: publisher)
        XCTAssertEqual(publisher.state, .unavailable(.service(-65563)))
        XCTAssertTrue(registrar.live.isEmpty)
        try await Task.sleep(nanoseconds: 200_000_000)
        await publisher.settle()
        XCTAssertEqual(publisher.state, .checking("setbeam"), "The responder is asked again after a bounded delay")
        XCTAssertEqual(registrar.live.count, 1)
        publisher.stop(); await publisher.settle()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(publisher.state, .stopped, "Stop cancels a scheduled retry")
        XCTAssertTrue(registrar.live.isEmpty)
    }

    /// Uses the real system responder, confined to this Mac so tests never announce names on the network.
    func testSystemResponderResolvesRenamesOnConflictAndForgetsOnStop() async throws {
        let label = "setbeam-test-\(UInt32.random(in: 100_000...999_999))"
        let first = LocalAddressPublisher(), second = LocalAddressPublisher()
        defer { first.stop(); second.stop() }
        first.publish(label: label, scope: .thisMacOnly, address: "127.0.0.1")
        try await waitFor { first.state == .active(label) }
        XCTAssertEqual(Self.resolve(LocalAddressName.host(label)), "127.0.0.1")

        // A second registrant with a different address is another host claiming the name.
        second.publish(label: label, scope: .thisMacOnly, address: "127.0.0.2")
        try await waitFor { second.state == .active("\(label)-2") }
        XCTAssertEqual(first.state, .active(label), "The existing holder keeps its name")
        XCTAssertEqual(Self.resolve(LocalAddressName.host(label)), "127.0.0.1")
        XCTAssertEqual(Self.resolve(LocalAddressName.host("\(label)-2")), "127.0.0.2")

        first.stop(); await first.settle()
        try await waitFor { Self.resolve(LocalAddressName.host(label)) == nil }
        XCTAssertEqual(Self.resolve(LocalAddressName.host("\(label)-2")), "127.0.0.2")
    }

    private func make(_ registrar: FakeRegistrar, retryDelay: TimeInterval = 60, maxCandidates: Int = 20) -> (LocalAddressPublisher, StateLog) {
        let publisher = LocalAddressPublisher(registrar: registrar, retryDelay: retryDelay, maxCandidates: maxCandidates,
                                              resolveInterface: { $0 == "en0" ? 7 : 0 })
        let log = StateLog()
        publisher.onChange = { log.append($0) }
        return (publisher, log)
    }

    private func waitFor(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
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
}

private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LocalAddressState] = []
    func append(_ state: LocalAddressState) { lock.withLock { items.append(state) } }
    var values: [LocalAddressState] { lock.withLock { items } }
}

private final class FakeRegistrar: LocalNameRegistrar, @unchecked Sendable {
    final class Entry: LocalNameRegistration {
        let host: String, interfaceIndex: UInt32, address: String, queue: DispatchQueue
        let events: (LocalNameEvent) -> Void
        weak var owner: FakeRegistrar?
        init(host: String, interfaceIndex: UInt32, address: String, queue: DispatchQueue, events: @escaping (LocalNameEvent) -> Void) {
            self.host = host; self.interfaceIndex = interfaceIndex; self.address = address; self.queue = queue; self.events = events
        }
        func cancel() { owner?.remove(self) }
    }
    private let lock = NSLock()
    var refuse: [String: LocalNameRefusal] = [:]
    private var entries: [Entry] = []
    private(set) var registrations = 0
    var live: [Entry] { lock.withLock { entries } }

    func register(host: String, interfaceIndex: UInt32, address: in_addr, queue: DispatchQueue,
                  events: @escaping (LocalNameEvent) -> Void) -> Result<LocalNameRegistration, LocalNameRefusal> {
        if let refusal = refuse[host] { return .failure(refusal) }
        let entry = Entry(host: host, interfaceIndex: interfaceIndex, address: String(cString: inet_ntoa(address)), queue: queue, events: events)
        entry.owner = self
        lock.withLock { entries.append(entry); registrations += 1 }
        return .success(entry)
    }
    func remove(_ entry: Entry) { lock.withLock { entries.removeAll { $0 === entry } } }
    func deliver(_ event: LocalNameEvent, to host: String, on publisher: LocalAddressPublisher) async {
        guard let entry = live.first(where: { $0.host == host }) else { XCTFail("No live registration for \(host)"); return }
        await withCheckedContinuation { done in entry.queue.async { entry.events(event); done.resume() } }
        await publisher.settle()
    }
}
