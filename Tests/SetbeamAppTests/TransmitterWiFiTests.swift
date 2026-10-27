import XCTest
@testable import SetbeamApp

final class TransmitterWiFiTests: XCTestCase {
    func testRevokedPermitNeverTouchesWiFi() async {
        let permit = RejoinPermit()
        XCTAssertTrue(permit.isAllowed)
        permit.revoke()
        let result = await TransmitterWiFi.join(ssid: "Setbeam-Test-Network", password: nil, permit: permit)
        XCTAssertEqual(result, .cancelled)
        XCTAssertNil(result.message)
    }
}
