import XCTest
import IOKit.pwr_mgt
@testable import SetbeamApp

@MainActor final class PowerAssertionTests: XCTestCase {
    func testHoldsOneAssertionAndReleasesItOnce() {
        var created: [String] = [], released: [IOPMAssertionID] = []
        let display = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep as String, reason: "Setbeam live monitoring",
            create: { type, _ in created.append(type); return IOPMAssertionID(created.count) }, release: { released.append($0) })
        XCTAssertTrue(display.hold(true)); XCTAssertFalse(display.hold(true))
        XCTAssertEqual(created, [kIOPMAssertionTypePreventUserIdleDisplaySleep as String]); XCTAssertTrue(display.isHeld)
        XCTAssertTrue(display.hold(false)); XCTAssertFalse(display.hold(false))
        XCTAssertEqual(released, [1]); XCTAssertFalse(display.isHeld)
    }

    func testFailedCreationIsNotReportedAsHeld() {
        let display = PowerAssertion(type: "test", reason: "test", create: { _, _ in nil }, release: { _ in XCTFail("nothing to release") })
        XCTAssertFalse(display.hold(true)); XCTAssertFalse(display.isHeld); XCTAssertFalse(display.hold(false))
    }
}
