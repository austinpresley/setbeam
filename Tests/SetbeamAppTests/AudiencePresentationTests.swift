import XCTest
import SetbeamCore
@testable import SetbeamApp

final class AudiencePresentationTests: XCTestCase {
    @MainActor func testUnconfirmedHoldDoesNotClaimCompletedHoldOrSilence() throws {
        var state = SessionState()
        state.beginMonitoring(); state.updateSource(available: true)
        try state.startSharing(); try state.setHold(true)
        state.updateAudience(available: false)
        let suite = "app.setbeam.tests.audience.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = SessionModel(initialState: state, preferences: preferences)
        XCTAssertEqual(model.sharingTitle, "Reconnecting")
        XCTAssertFalse(model.audienceAudioLabel.contains("silenced"))
    }

    private func session(holding: Bool = false, available: Bool = true, source: Bool = true) throws -> SessionState {
        var s = SessionState(); s.beginMonitoring(); s.updateSource(available: source)
        try s.startSharing(); try s.setHold(holding); s.updateAudience(available: available)
        return s
    }
    func testFailuresRetainTheRequestedTargetAndNeverCertifySuppression() throws {
        for target in [AudienceTarget.hold, .resume] {
            let intent = try session(holding: target.holding, available: false)
            var control = AudienceControlState(); control.fail(target, session: intent)
            let p = AudiencePresentation(session: intent, control: control, localReady: true, busy: false)
            XCTAssertEqual(p.primaryTarget, target)
            XCTAssertEqual(p.primaryTitle, target.holding ? "Retry Hold" : "Retry Resume")
            XCTAssertFalse(p.confirmedHold); XCTAssertTrue(p.primaryEnabled)
            XCTAssertFalse(p.outputDetail.contains("Sound off"))
            XCTAssertNotNil(p.recoveryDetail)
        }
    }
    func testPendingAndStoppedOutputOverrideHistoricalHoldConfirmation() throws {
        var control = AudienceControlState(); control.observe(try session(holding: true))
        control.begin(.resume)
        let pending = AudiencePresentation(session: try session(available: false), control: control, localReady: true, busy: true)
        XCTAssertEqual(pending.phase, .resuming); XCTAssertFalse(pending.confirmedHold)
        control.fail(.resume, session: try session(available: false))
        let failed = AudiencePresentation(session: try session(available: false), control: control, localReady: false, busy: false)
        XCTAssertEqual(failed.phase, .failedResume); XCTAssertFalse(failed.primaryEnabled)
    }
    func testConfirmedHoldSurvivesSourceLossButNotOutgoingLoss() throws {
        var control = AudienceControlState(); control.observe(try session(holding: true))
        let held = AudiencePresentation(session: try session(holding: true, source: false), control: control, localReady: false, busy: false)
        XCTAssertTrue(held.confirmedHold); XCTAssertFalse(held.primaryEnabled)
        let lost = AudiencePresentation(session: try session(holding: true, available: false), control: control, localReady: true, busy: false)
        XCTAssertFalse(lost.confirmedHold); XCTAssertEqual(lost.phase, .reconnecting)
        XCTAssertEqual(lost.primaryTarget, .hold)
    }
    func testAutomaticHoldAndStopHaveExplicitPendingStates() throws {
        let holding = AudiencePresentation(session: try session(holding: true, available: false), control: .init(), change: .hold, localReady: false, busy: true)
        XCTAssertEqual(holding.phase, .applyingHold); XCTAssertFalse(holding.confirmedHold)
        let stopping = AudiencePresentation(session: try session(holding: true), control: .init(), localReady: true, busy: true, stopping: true)
        XCTAssertEqual(stopping.title, "Stopping sharing"); XCTAssertNil(stopping.primaryTarget)
        XCTAssertFalse(stopping.confirmedHold)
    }
    func testIncomingReadyCopyUsesAudienceStateAndInputBinding() throws {
        let held = AudiencePresentation(session: try session(holding: true), control: .init(), localReady: true, busy: false)
        XCTAssertTrue(held.incomingReadyDetail.contains("Viewers remain on Hold"))
        let shared = AudiencePresentation(session: try session(), control: .init(), localReady: true, busy: false)
        XCTAssertTrue(shared.incomingReadyDetail.contains("Sharing is active"))
        for host in ["127.0.0.1", "127.2.3.4", "localhost", "[::1]"] {
            XCTAssertTrue(IncomingDestination.isLocalOnly("rtmp://\(host):1935"))
        }
        XCTAssertFalse(IncomingDestination.isLocalOnly("rtmp://192.168.1.4:1935"))
        XCTAssertFalse(IncomingDestination.isLocalOnly(""))
    }
}
