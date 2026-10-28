import XCTest
@testable import SetbeamCore
@testable import SetbeamApp

final class ViewerAttentionTests: XCTestCase {
    @MainActor func testStrugglingViewersComeFirstWithoutLosingNeutralOrHealthySessions() throws {
        var state = SessionState()
        state.beginMonitoring()
        try state.startSharing()
        let model = SessionModel(initialState: state)
        let viewers = [viewer("good", number: 1, health: .good), viewer("background", number: 2, health: .background),
                       viewer("bad", number: 3, health: .struggling), viewer("reconnecting", number: 4, health: .reconnecting)]
        model.viewers = viewers
        XCTAssertEqual(model.strugglingViewers.map(\.id), ["bad"])
        XCTAssertEqual(model.viewersForDetails.map(\.id), ["bad", "good", "background", "reconnecting"])
        try state.setHold(true)
        let held = SessionModel(initialState: state)
        held.viewers = viewers
        XCTAssertTrue(held.strugglingViewers.isEmpty)
        XCTAssertEqual(held.viewersForDetails.map(\.id), viewers.map(\.id))
        state.stopSharing()
        let stopped = SessionModel(initialState: state)
        stopped.viewers = viewers
        XCTAssertTrue(stopped.strugglingViewers.isEmpty)
    }

    private func viewer(_ id: String, number: Int, health: ViewerHealth) -> ViewerActivity {
        ViewerActivity(id: id, label: "Browser", playing: health == .good || health == .struggling,
            onThisMac: false, revision: 1, lastSeen: Date(), number: number, name: nil, health: health)
    }
}
