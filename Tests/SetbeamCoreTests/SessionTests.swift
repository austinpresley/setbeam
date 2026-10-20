import XCTest
@testable import SetbeamCore

final class SessionTests: XCTestCase {
    func testAudienceControlsPreserveLocalMonitoring() throws {
        var state = SessionState()
        XCTAssertThrowsError(try state.startSharing())
        state.beginMonitoring(); state.updateSource(available: true)
        try state.startSharing(); try state.setHold(true)
        XCTAssertEqual(state.audience, .holding)
        XCTAssertTrue(state.monitoring); XCTAssertTrue(state.sourceAvailable)
        state.stopSharing()
        XCTAssertEqual(state.audience, .stopped)
        XCTAssertTrue(state.monitoring); XCTAssertTrue(state.sourceAvailable)
        state.end(); XCTAssertFalse(state.monitoring)
    }
    func testInterruptedSourceKeepsAudienceSessionIntent() throws {
        var state = SessionState(); state.beginMonitoring(); state.updateSource(available: true); try state.startSharing()
        state.updateSource(available: false)
        XCTAssertEqual(state.audience, .reconnecting); XCTAssertTrue(state.sharing)
        state.updateSource(available: true); XCTAssertEqual(state.audience, .live)
    }
    func testSourceValidationAndRedaction() throws {
        XCTAssertNoThrow(try VideoSource.network("rtsp://user:secret@192.0.2.4:5554/live").validated())
        for address in ["https://example.com", "rtsp:///live", "rtsp://camera/live\npaths: {}", "rtsp://camera:0/live"] {
            XCTAssertThrowsError(try VideoSource.network(address).validated())
        }
        XCTAssertEqual(VideoSource.safeAddress("rtsp://user:secret@camera:5554/live?token=private"), "rtsp://camera:5554/live")
        let log = Redaction.text("Failed rtsp://publisher:private@127.0.0.1/live and http://camera/live?token=private")
        XCTAssertFalse(log.contains("private"))
    }
}
