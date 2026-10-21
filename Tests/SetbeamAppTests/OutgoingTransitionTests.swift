import XCTest
@testable import SetbeamApp

final class OutgoingTransitionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100)

    func testExplicitChangesHavePreparationLabelsAndADeadline() {
        for change in [OutgoingTransition.Change.startSharing, .hold, .resume] {
            var transition = OutgoingTransition()
            transition.begin(change, at: now)
            XCTAssertEqual(transition.activeChange(at: now.addingTimeInterval(2)), change)
            XCTAssertNil(transition.activeChange(at: now.addingTimeInterval(10)))
            XCTAssertFalse(change.title.lowercased().contains("reconnecting"))
        }
    }

    func testFirstFreshOutputEndsPreparationBeforeTheDeadline() {
        var transition = OutgoingTransition()
        transition.begin(.resume, at: now)
        transition.observeReady(false)
        XCTAssertEqual(transition.activeChange(at: now.addingTimeInterval(1)), .resume)
        transition.observeReady(true)
        transition.observeReady(false)
        XCTAssertNil(transition.activeChange(at: now.addingTimeInterval(2)), "A later outage must not inherit the initial preparation grace.")
    }

    func testStopOrKnownFailureCancelsPreparation() {
        var transition = OutgoingTransition()
        transition.begin(.hold, at: now)
        transition.reset()
        XCTAssertNil(transition.activeChange(at: now))
    }

    func testNewExplicitChangeReplacesAnEarlierOne() {
        var transition = OutgoingTransition()
        transition.begin(.startSharing, at: now)
        transition.begin(.hold, at: now.addingTimeInterval(1))
        XCTAssertEqual(transition.activeChange(at: now.addingTimeInterval(10)), .hold)
        XCTAssertNil(transition.activeChange(at: now.addingTimeInterval(11)))
    }
}
