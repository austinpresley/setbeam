import XCTest
@testable import SetbeamCore
@testable import SetbeamApp

final class FloatingPreviewStateTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 20_000)
    private func session(held: Bool = false, available: Bool = true, source: Bool = true) throws -> SessionState {
        var state = SessionState(); state.beginMonitoring(); state.updateSource(available: source)
        try state.startSharing(); try state.setHold(held); state.updateAudience(available: available)
        return state
    }
    private func presentation(_ session: SessionState, _ control: AudienceControlState, local: Bool = true) -> FloatingPreviewState {
        FloatingPreviewState(session: session, control: control, localReady: local, busy: false)
    }
    func testPrivatePreviewNeverPublishesEvenWithAnOldControlFailure() throws {
        var control = AudienceControlState()
        control.fail(.hold, session: try session())
        let result = presentation(SessionState(), control)
        XCTAssertEqual(result.center, .hidden); XCTAssertNil(result.target)
        XCTAssertFalse(result.washed); XCTAssertFalse(result.enabled)
    }
    func testHoldWaitsForFreshHoldingOutputNotOnlyRuntimeIntentOrCommandReturn() throws {
        var control = AudienceControlState()
        control.observe(try session(), at: now)
        control.begin(.hold)
        control.observe(try session(), at: now)
        let changing = try session(held: true, available: false)
        control.complete(changing, at: now)
        XCTAssertEqual(presentation(changing, control).center, .pending)
        XCTAssertFalse(presentation(changing, control).washed)
        control.observe(try session(held: true), at: now.addingTimeInterval(1))
        XCTAssertTrue(presentation(try session(held: true), control).washed)
        XCTAssertEqual(presentation(try session(held: true), control).center, .resume)
    }
    func testResumeRetainsTheWashUntilFreshLiveOutput() throws {
        var control = AudienceControlState()
        control.observe(try session(held: true), at: now)
        control.begin(.resume)
        let changing = try session(available: false)
        control.complete(changing, at: now)
        XCTAssertTrue(presentation(changing, control).washed)
        XCTAssertEqual(presentation(changing, control).center, .pending)
        control.observe(try session(), at: now.addingTimeInterval(1))
        XCTAssertFalse(presentation(try session(), control).washed)
        XCTAssertEqual(presentation(try session(), control).target, .hold)
    }
    func testAReadySnapshotCannotFinishAnOperationThatIsStillRunning() throws {
        var control = AudienceControlState(); control.begin(.hold)
        control.observe(try session(held: true), at: now)
        XCTAssertNotNil(control.pending)
        control.complete(try session(held: true), at: now)
        XCTAssertNil(control.pending)
    }
    func testTimeoutRetriesTheRequestedHoldInsteadOfResumingItsIntent() throws {
        var control = AudienceControlState(); control.begin(.hold)
        let intentOnly = try session(held: true, available: false)
        control.complete(intentOnly, at: now)
        control.observe(intentOnly, at: now.addingTimeInterval(10))
        let result = presentation(intentOnly, control)
        XCTAssertEqual(result.center, .failed); XCTAssertEqual(result.target, .hold)
        XCTAssertFalse(result.washed); XCTAssertTrue(result.enabled)
    }
    func testFailedResumeDoesNotClaimProtectionWhenRuntimeAlreadyStoppedHolding() throws {
        var control = AudienceControlState(); control.observe(try session(held: true), at: now)
        let changedIntent = try session(available: false)
        control.fail(.resume, session: changedIntent)
        let result = presentation(changedIntent, control)
        XCTAssertFalse(result.washed); XCTAssertEqual(result.center, .failed)
        XCTAssertEqual(result.target, .resume)
    }
    func testLostSourceKeepsConfirmedHoldButDisablesResume() throws {
        var control = AudienceControlState(); control.observe(try session(held: true), at: now)
        let missing = try session(held: true, available: false, source: false)
        control.observe(missing, at: now.addingTimeInterval(2))
        let result = presentation(missing, control, local: false)
        XCTAssertTrue(result.washed); XCTAssertEqual(result.center, .resume); XCTAssertFalse(result.enabled)
    }
    func testStoppingClearsConfirmationPendingAndFailuresForTheNextLink() throws {
        var control = AudienceControlState(); control.observe(try session(held: true), at: now)
        control.begin(.resume)
        control.observe(SessionState(), at: now)
        XCTAssertEqual(control, AudienceControlState())
        XCTAssertFalse(presentation(try session(), control).washed)
    }
    func testARepairedOutputClearsTheScopedFailure() throws {
        var control = AudienceControlState()
        control.fail(.hold, session: try session(held: true, available: false))
        control.observe(try session(held: true), at: now)
        XCTAssertNil(control.failed); XCTAssertTrue(control.confirmedHolding)
    }
    func testDoubleClickAndDragGuardUsesTheSuppliedSystemInterval() {
        var gate = FloatingClickGate()
        XCTAssertTrue(gate.accept(at: 100, interval: 0.9))
        XCTAssertFalse(gate.accept(at: 100.8, interval: 0.9))
        XCTAssertFalse(gate.accept(at: 101, count: 2, interval: 0.9))
        XCTAssertFalse(gate.accept(at: 102, dragged: true, interval: 0.9))
        XCTAssertTrue(gate.accept(at: 102.01, interval: 0.9), "Rejected input must not suppress the next deliberate action")
    }
    func testRecoveryUsesTheHoldActionOnlyOnHoverAndNamesInitialSharing() throws {
        let unavailable = try session(available: false)
        let recovering = presentation(unavailable, AudienceControlState())
        XCTAssertEqual(recovering.symbol, "pause.fill")
        XCTAssertFalse(recovering.centerVisible(hovered: false, keyboard: false))
        XCTAssertTrue(recovering.centerVisible(hovered: true, keyboard: false))
        let starting = FloatingPreviewState(session: unavailable, control: AudienceControlState(), localReady: true, busy: false, starting: true)
        XCTAssertTrue(starting.label.contains("starting"))
    }
    func testSlowRuntimeCallStillGetsTheFullConfirmationDeadline() throws {
        var control = AudienceControlState(); control.begin(.hold)
        let waiting = try session(held: true, available: false)
        control.observe(waiting, at: now.addingTimeInterval(30))
        control.complete(waiting, at: now.addingTimeInterval(30))
        control.observe(waiting, at: now.addingTimeInterval(39))
        XCTAssertEqual(control.pending, .hold)
        control.observe(waiting, at: now.addingTimeInterval(40))
        XCTAssertEqual(control.failed, .hold)
    }
    func testAudienceSummaryDistinguishesWaitingAdmissionAndPlayback() {
        var viewer = ViewerActivity(id: "a", label: "Browser", playing: false, onThisMac: false,
                                   revision: 1, lastSeen: now, number: 1, name: "Alex", health: .connecting)
        var waiting = viewer; waiting.admission = .pending
        let mixed = FloatingAudienceSummary(sharing: true, viewers: [viewer, waiting])
        XCTAssertEqual(mixed.count, 1); XCTAssertEqual(mixed.waiting, 1); XCTAssertEqual(mixed.joined, 1)
        XCTAssertEqual(mixed.symbol, "person.badge.clock")
        XCTAssertTrue(mixed.label.contains("joined browser sessions"))
        viewer.admission = .declined
        XCTAssertFalse(FloatingAudienceSummary(sharing: true, viewers: [viewer]).visible)
        XCTAssertFalse(FloatingAudienceSummary(sharing: false, viewers: [waiting]).visible)
    }
    func testRemovalReferenceRequiresTheSameLinkJoinAndAdmission() {
        var viewer = ViewerActivity(id: "a", label: "Browser", playing: true, onThisMac: false,
                                   revision: 1, lastSeen: now, number: 1, name: "Alex", health: .playing)
        viewer.joinedAt = now
        let reference = JoinRequest(viewer, link: 4)
        XCTAssertNotNil(reference.current(in: [viewer], link: 4, admission: .admitted))
        XCTAssertNil(reference.current(in: [viewer], link: 5, admission: .admitted))
        XCTAssertNil(reference.current(in: [viewer], link: 4), "Pending-request actions cannot remove an admitted session")
        viewer.joinedAt = now.addingTimeInterval(1)
        XCTAssertNil(reference.current(in: [viewer], link: 4, admission: .admitted))
    }
    func testPortraitSourceChangeStaysOnTheDisplayAndKeepsItsAspect() throws {
        let screen = CGRect(x: 0, y: 40, width: 1440, height: 860)
        let fit = try XCTUnwrap(PreviewWindowLayout(source: CGSize(width: 360, height: 640), frame: CGRect(x: 1080, y: 80, width: 340, height: 192), screen: screen))
        XCTAssertTrue(screen.contains(fit.frame))
        XCTAssertEqual(fit.frame.height / fit.frame.width, 640.0 / 360, accuracy: 0.001)
        XCTAssertEqual(fit.minimum.width, 220)
    }
    func testExtremeSourceShapesFitAUsableWindowAndTheCompletePicture() throws {
        let screen = CGRect(x: -1000, y: 80, width: 1000, height: 620)
        for source in [CGSize(width: 100, height: 2000), CGSize(width: 4000, height: 100)] {
            let fit = try XCTUnwrap(PreviewWindowLayout(source: source, frame: CGRect(x: 1200, y: -500, width: 340, height: 192), screen: screen))
            XCTAssertTrue(screen.contains(fit.frame))
            let picture = PreviewViewport().imageRect(source: source, bounds: CGRect(origin: .zero, size: fit.frame.size))
            XCTAssertGreaterThan(picture.width, 0)
            XCTAssertLessThanOrEqual(picture.width, fit.frame.width + 0.001)
            XCTAssertLessThanOrEqual(picture.height, fit.frame.height + 0.001)
        }
    }
}
