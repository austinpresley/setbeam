import XCTest
@testable import SetbeamCore

final class SourceSetupTests: XCTestCase {
    func testOnlySustainedSourceAndDecodedPreviewProveASetup() {
        let start = Date(timeIntervalSince1970: 1000)
        var readiness = SetupReadiness()
        XCTAssertFalse(readiness.observe(sourceFresh: true, previewFresh: false, now: start))
        XCTAssertFalse(readiness.observe(sourceFresh: false, previewFresh: true, now: start.addingTimeInterval(3)))
        XCTAssertFalse(readiness.observe(sourceFresh: true, previewFresh: true, now: start.addingTimeInterval(4)))
        XCTAssertFalse(readiness.observe(sourceFresh: true, previewFresh: true, now: start.addingTimeInterval(5)))
        XCTAssertTrue(readiness.observe(sourceFresh: true, previewFresh: true, now: start.addingTimeInterval(6)))
        XCTAssertFalse(readiness.observe(sourceFresh: false, previewFresh: true, now: start.addingTimeInterval(7)))
        XCTAssertFalse(readiness.observe(sourceFresh: true, previewFresh: true, now: start.addingTimeInterval(8)))
    }
    func testRememberedSetupExcludesSecretsAndFailedDraftDoesNotReplaceIt() throws {
        let suite = "Setbeam-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProvenSetupStore(defaults: defaults)
        XCTAssertNil(store.setup)
        let good = SourceSetup(kind: .network, name: "Capture One", networkAddress: "rtsp://user:private@source/live?token=private")
        try store.confirm(good)
        let saved = try XCTUnwrap(store.setup)
        XCTAssertEqual(saved.id, good.id); XCTAssertNotNil(saved.confirmedAt)
        XCTAssertEqual(saved.networkAddress, "rtsp://source/live")
        XCTAssertThrowsError(try saved.source())
        XCTAssertNoThrow(try saved.source(address: "rtsp://user:private@source/live?token=private"))
        var readiness = SetupReadiness()
        let failed = SourceSetup(kind: .capture, name: "Unplugged", videoID: "missing")
        if readiness.observe(sourceFresh: false, previewFresh: false) { try store.confirm(failed) }
        XCTAssertEqual(store.setup?.id, good.id)
        let persisted = String(decoding: try XCTUnwrap(defaults.data(forKey: "provenSetup.v1")), as: UTF8.self)
        XCTAssertFalse(persisted.contains("private")); XCTAssertFalse(persisted.contains("sharing"))
        store.forget(); XCTAssertNil(store.setup)
    }
    func testCaptureIdentitySurvivesReorderingAndNeverSubstitutesSameName() throws {
        let devices = [CaptureHardware(id: "other", name: "HDMI Capture", index: 0), CaptureHardware(id: "saved", name: "HDMI Capture", index: 2)]
        XCTAssertEqual(try CaptureHardware.resolve("saved", audio: false, in: devices), 2)
        let reordered = [CaptureHardware(id: "saved", name: "HDMI Capture", index: 0), CaptureHardware(id: "other", name: "HDMI Capture", index: 1)]
        XCTAssertEqual(try CaptureHardware.resolve("saved", audio: false, in: reordered), 0)
        XCTAssertThrowsError(try CaptureHardware.resolve("missing", audio: false, in: reordered))
        XCTAssertThrowsError(try CaptureHardware.resolve("saved", audio: true, in: reordered))
        let setup = SourceSetup(kind: .capture, name: "A Camera", videoID: "saved")
        XCTAssertEqual(try setup.source(), .captureDevice(videoID: "saved", audioID: nil))
    }
    func testAudienceNeedsAFreshRelayAndRestartsPrivate() throws {
        var state = SessionState(); state.beginMonitoring(); state.updateSource(available: true)
        try state.startSharing(); XCTAssertEqual(state.audience, .reconnecting)
        state.updateAudience(available: true); XCTAssertEqual(state.audience, .live)
        state.updateAudience(available: false); XCTAssertEqual(state.audience, .reconnecting)
        XCTAssertTrue(state.sourceAvailable)
        try state.setHold(true); XCTAssertEqual(state.audience, .holding)
        state.end(); state.beginMonitoring(); state.updateSource(available: true)
        XCTAssertFalse(state.sharing); XCTAssertFalse(state.holding); XCTAssertEqual(state.audience, .stopped)
    }
    func testWirelessSetupRestoresTheSameUnitWithoutPersistingItsAddress() throws {
        let suite = "Setbeam-wireless-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var setup = SourceSetup(kind: .accsoon, name: "Computer display", deviceName: "Accsoon CineView Master 4K", sourceWiFi: "Accsoon_Test")
        setup.wirelessUID = 12345
        try ProvenSetupStore(defaults: defaults).confirm(setup)
        let restored = try XCTUnwrap(ProvenSetupStore(defaults: defaults).setup)
        XCTAssertEqual(restored.id, setup.id)
        XCTAssertEqual(try restored.source(), .accsoon(uid: 12345))
        XCTAssertEqual(restored.sourceWiFi, "Accsoon_Test")
        XCTAssertTrue(restored.networkAddress.isEmpty)
    }
}
