import XCTest
@testable import SetbeamCore
@testable import SetbeamApp

final class PointerVisibilityTests: XCTestCase {
    @MainActor func testThisMacShowsPointersOnlyAfterTheOperatorChoosesForThisSession() throws {
        let suite = "app.setbeam.tests.pointers.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var state = SessionState(); state.beginMonitoring(); try state.startSharing()
        let model = SessionModel(initialState: state, preferences: preferences)
        model.setSharedPointers(true)
        XCTAssertFalse(model.showsPointers, "Letting viewers point does not draw pointers on this Mac")
        model.setPointersOnThisMac(true)
        XCTAssertTrue(model.showsPointers)
        model.setSharedPointers(false)
        XCTAssertFalse(model.showsPointers, "Pointers end when viewers can no longer point")
        model.setSharedPointers(true)
        let relaunched = SessionModel(initialState: state, preferences: preferences)
        XCTAssertTrue(relaunched.sharedPointers, "The viewer permission is saved")
        XCTAssertFalse(relaunched.pointersOnThisMac, "The view choice is never saved")
        try state.setHold(true)
        let held = SessionModel(initialState: state, preferences: preferences)
        held.setPointersOnThisMac(true)
        XCTAssertFalse(held.showsPointers, "Hold clears pointers from this Mac")
    }
}
