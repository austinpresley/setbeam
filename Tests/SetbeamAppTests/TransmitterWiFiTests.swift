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

    func testSharingCanProceedAfterRevokingAScanButWaitsForActiveAssociation() {
        let scanning = RejoinPermit()
        XCTAssertFalse(scanning.revoke())
        XCTAssertFalse(scanning.beginAssociation())

        let associating = RejoinPermit()
        XCTAssertTrue(associating.beginAssociation())
        XCTAssertTrue(associating.revoke())
        associating.finishAssociation()
        XCTAssertFalse(associating.revoke())
        XCTAssertFalse(associating.beginAssociation())
    }
}
