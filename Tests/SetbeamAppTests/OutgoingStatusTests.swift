import XCTest
import SetbeamCore
@testable import SetbeamApp

final class OutgoingStatusTests: XCTestCase {
    @MainActor private func sharingModel(holding: Bool = false, sourceAvailable: Bool = true, audienceAvailable: Bool = true) throws -> SessionModel {
        var state = SessionState()
        state.beginMonitoring()
        state.updateSource(available: sourceAvailable)
        try state.startSharing()
        try state.setHold(holding)
        state.updateAudience(available: audienceAvailable)
        return SessionModel(initialState: state)
    }

    @MainActor func testHealthyOutputDoesNotReportReconnectingWhileThumbnailOpens() throws {
        let model = try sharingModel()
        model.audiencePreviewPlaying = false
        XCTAssertFalse(model.outgoingNeedsAttention, "A healthy outgoing stream is not reconnecting while its local thumbnail opens.")
    }

    @MainActor func testCachedThumbnailDoesNotHideMissingHoldingOutput() throws {
        let model = try sharingModel(holding: true, audienceAvailable: false)
        model.audiencePreviewPlaying = true
        XCTAssertTrue(model.outgoingNeedsAttention, "A cached thumbnail cannot establish a healthy holding output.")
    }

    @MainActor func testUnplannedLiveOutputLossStillNeedsAttention() throws {
        let model = try sharingModel(audienceAvailable: false)
        model.audiencePreviewPlaying = true
        XCTAssertTrue(model.outgoingNeedsAttention)
    }

    @MainActor func testPrivateMonitoringDoesNotReportOutgoingFailure() {
        let model = SessionModel()
        XCTAssertFalse(model.outgoingNeedsAttention)
    }

    @MainActor func testHealthyHoldingOutputDoesNotDependOnTheSourcePicture() throws {
        let model = try sharingModel(holding: true, sourceAvailable: false)
        model.audiencePreviewPlaying = false
        XCTAssertFalse(model.outgoingNeedsAttention)
        XCTAssertEqual(model.sharingTitle, "On hold")
    }
}
