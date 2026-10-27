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
        var state = SessionState(); state.beginMonitoring(); state.updateSource(available: true); try state.startSharing(); state.updateAudience(available: true)
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
        let key = String(repeating: "a1b2", count: 12)
        for text in ["rtmp://sender:\(key)@192.0.2.4/source", "source?user=sender&pass=\(key)", "http://192.0.2.4:8080/s/\(key)/",
                     "guest token \(key)", "password=hunter2 next"] {
            let redacted = Redaction.text(text)
            XCTAssertFalse(redacted.contains(key) || redacted.contains("hunter2"), redacted)
        }
        XCTAssertEqual(Redaction.text("Source input exited with status 1"), "Source input exited with status 1")
    }
}
