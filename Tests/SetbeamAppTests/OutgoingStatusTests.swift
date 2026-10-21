import XCTest
import SetbeamCore
@testable import SetbeamApp

final class OutgoingStatusTests: XCTestCase {
    @MainActor private func sharingModel() throws -> SessionModel {
        let model = SessionModel()
        model.state.beginMonitoring()
        model.state.updateSource(available: true)
        try model.state.startSharing()
        model.state.updateAudience(available: true)
        return model
    }

    @MainActor func testHealthyOutputDoesNotReportReconnectingWhileThumbnailOpens() throws {
        let model = try sharingModel()
        model.audiencePreviewPlaying = false
        XCTAssertFalse(model.outgoingNeedsAttention, "A healthy outgoing stream is not reconnecting while its local thumbnail opens.")
    }

    @MainActor func testCachedThumbnailDoesNotHideMissingHoldingOutput() throws {
        let model = try sharingModel()
        try model.state.setHold(true)
        model.state.updateAudience(available: false)
        model.audiencePreviewPlaying = true
        XCTAssertTrue(model.outgoingNeedsAttention, "A cached thumbnail cannot establish a healthy holding output.")
    }

    @MainActor func testUnplannedLiveOutputLossStillNeedsAttention() throws {
        let model = try sharingModel()
        model.state.updateAudience(available: false)
        model.audiencePreviewPlaying = true
        XCTAssertTrue(model.outgoingNeedsAttention)
    }

    @MainActor func testPrivateMonitoringDoesNotReportOutgoingFailure() {
        let model = SessionModel()
        XCTAssertFalse(model.outgoingNeedsAttention)
    }

    @MainActor func testHealthyHoldingOutputDoesNotDependOnTheSourcePicture() throws {
        let model = try sharingModel()
        try model.state.setHold(true)
        model.state.updateSource(available: false)
        model.audiencePreviewPlaying = false
        XCTAssertFalse(model.outgoingNeedsAttention)
        XCTAssertEqual(model.sharingTitle, "On hold")
    }
}
