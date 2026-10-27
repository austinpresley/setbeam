import XCTest
import Network
@testable import SetbeamCore

final class IncomingStreamRelayTests: XCTestCase {
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
