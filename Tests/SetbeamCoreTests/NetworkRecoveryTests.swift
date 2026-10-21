import XCTest
@testable import SetbeamCore

final class NetworkRecoveryTests: XCTestCase {
    func testOutageWaitsForTheSameViewingInterface() {
        let chosen = NetworkAddress(interface: "en0", address: "192.0.2.10")
        let other = NetworkAddress(interface: "en1", address: "198.51.100.10")
        XCTAssertEqual(NetworkAddress.restoring(chosen, in: []), chosen)
        XCTAssertEqual(NetworkAddress.restoring(chosen, in: [other]), chosen)
        XCTAssertEqual(NetworkAddress.restoring(chosen, in: [other, chosen]), chosen)
        let renewed = NetworkAddress(interface: "en0", address: "192.0.2.11")
        XCTAssertEqual(NetworkAddress.restoring(chosen, in: [other, renewed]), renewed)
    }
}
