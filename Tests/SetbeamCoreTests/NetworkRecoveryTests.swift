import XCTest
@testable import SetbeamCore

final class NetworkRecoveryTests: XCTestCase {
    private let chosen = NetworkAddress(interface: "en0", address: "192.0.2.10", subnet: "192.0.2.0/24",
                                        router: "192.0.2.1", wirelessNetwork: "SSID:Studio")

    func testOutageWaitsForTheSameViewingInterface() {
        let other = NetworkAddress(interface: "en1", address: chosen.address, subnet: chosen.subnet,
                                   router: chosen.router, wirelessNetwork: chosen.wirelessNetwork)
        XCTAssertNil(chosen.observation(in: []))
        XCTAssertNil(chosen.observation(in: [other]))
        XCTAssertEqual(chosen.observation(in: [other, chosen]), chosen)
        let renewed = NetworkAddress(interface: "en0", address: "192.0.2.11", subnet: chosen.subnet,
                                     router: chosen.router, wirelessNetwork: chosen.wirelessNetwork)
        XCTAssertEqual(chosen.observation(in: [other, renewed, chosen]), chosen)
        XCTAssertEqual(chosen.observation(in: [other, renewed]), renewed)
        XCTAssertEqual(chosen.trust(in: renewed), .same)
    }

    func testSameIPCanHaveADifferentSubnetRouterOrWiFiNetwork() {
        let changes = [
            NetworkAddress(interface: "en0", address: chosen.address, subnet: "192.0.2.0/25",
                           router: chosen.router, wirelessNetwork: chosen.wirelessNetwork),
            NetworkAddress(interface: "en0", address: chosen.address, subnet: chosen.subnet,
                           router: "192.0.2.2", wirelessNetwork: chosen.wirelessNetwork),
            NetworkAddress(interface: "en0", address: chosen.address, subnet: chosen.subnet,
                           router: chosen.router, wirelessNetwork: "SSID:Visitors")
        ]
        for change in changes {
            XCTAssertEqual(chosen.observation(in: [change]), change)
            XCTAssertEqual(chosen.trust(in: change), .changed)
        }
    }

    func testMissingKnownIdentityWaitsAndRecovers() {
        let incomplete = NetworkAddress(interface: "en0", address: chosen.address, subnet: chosen.subnet)
        XCTAssertEqual(chosen.trust(in: incomplete), .unresolved)
        XCTAssertEqual(chosen.trust(in: chosen), .same)
    }
}
