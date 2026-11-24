import XCTest
import Network
@testable import SetbeamCore

final class IncomingStreamRelayTests: XCTestCase {
    func testCancelledStartDoesNotReplaceActiveBinding() async throws {
        let relay = IncomingStreamRelay()
        defer { relay.stop() }
        let active = try NetworkAddress.freeTCPPort()
        let replacement = try NetworkAddress.freeTCPPort()
        let target = try NetworkAddress.freeTCPPort()
        try await relay.start(address: "127.0.0.1", port: active, targetPort: target)
        let task = Task {
            // Ensure cancellation has happened before start registers on the relay queue.
            while !Task.isCancelled { await Task.yield() }
            try await relay.start(address: "127.0.0.1", port: replacement, targetPort: target)
        }
        task.cancel()
        do { try await task.value; XCTFail("The cancelled binding succeeded.") }
        catch is CancellationError {}
        let independent = IncomingStreamRelay()
        defer { independent.stop() }
        try await independent.start(address: "127.0.0.1", port: replacement, targetPort: target)
        do {
            try await independent.start(address: "127.0.0.1", port: active, targetPort: target)
            XCTFail("The original binding was released by a cancelled replacement.")
        } catch is SetbeamError {}
    }

    func testOnlySelectedSubnetAndExplicitLoopbackCanReachPrivateRTMP() {
        func allows(_ host: String) -> Bool {
            IncomingStreamRelay.allows(.hostPort(host: .init(host), port: 12345), network: "192.0.2.0/27")
        }
        XCTAssertTrue(allows("192.0.2.4"))
        XCTAssertTrue(allows("192.0.2.31"))
        XCTAssertTrue(allows("127.0.0.1"))
        XCTAssertTrue(allows("::1"))
        XCTAssertTrue(allows("::ffff:192.0.2.4"))
        XCTAssertFalse(allows("192.0.2.32"))
        XCTAssertFalse(allows("198.51.100.4"))
        XCTAssertFalse(allows("::ffff:198.51.100.4"))
        XCTAssertFalse(allows("2001:db8::1"))
        XCTAssertFalse(allows("localhost"))
    }
}
