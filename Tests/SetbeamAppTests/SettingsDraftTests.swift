import XCTest
import SetbeamCore
@testable import SetbeamApp

final class SettingsDraftTests: XCTestCase {
    private var initial: SourceDetailsDraft {
        .init(name: "Original", audioID: "old-mic", remember: true, screenRate: .source,
              rejoin: false, password: "previous test password", openNetwork: false)
    }
    func testOneCommitIncludesTheChangedPasswordAndName() throws {
        let source = SourceSetup(kind: .accsoon, name: "Original", sourceWiFi: "Fixture transmitter")
        var draft = initial
        draft.name = " Renamed source "; draft.rejoin = true; draft.password = "new test password"
        let plan = try XCTUnwrap(draft.plan(for: source, current: initial))
        XCTAssertEqual(plan.source.id, source.id)
        XCTAssertEqual(plan.source.name, "Renamed source")
        XCTAssertEqual(plan.rejoin, .init(enabled: true, password: "new test password", openNetwork: false))
        XCTAssertFalse(plan.reconnect)
        XCTAssertTrue(plan.nameOrRememberChanged)
    }
    func testPendingSoundIsIncludedWithoutSubstitutingTheVideoInput() throws {
        let source = SourceSetup(kind: .capture, name: "Original", videoID: "exact-video", audioID: "old-mic")
        var draft = initial; draft.audioID = "chosen-mic"; draft.remember = false
        let plan = try XCTUnwrap(draft.plan(for: source, current: initial))
        XCTAssertTrue(plan.reconnect)
        XCTAssertEqual(plan.source.id, source.id)
        XCTAssertEqual(plan.source.videoID, "exact-video")
        XCTAssertEqual(plan.source.audioID, "chosen-mic")
        XCTAssertFalse(plan.remember)
        XCTAssertNil(plan.captureRate)
    }
    func testCaptureRateKeepsTheCompleteWindowIdentity() throws {
        var source = SourceSetup(kind: .macWindow, name: "Original")
        source.window = MacWindowIdentity(windowID: 42, processID: 9, processStart: 100)
        var draft = initial; draft.screenRate = .fps1
        let plan = try XCTUnwrap(draft.plan(for: source, current: initial))
        XCTAssertEqual(plan.captureRate, .fps1)
        XCTAssertFalse(plan.nameOrRememberChanged)
        XCTAssertEqual(plan.source.window, source.window)
        XCTAssertFalse(plan.reconnect)
    }
    func testBlankPasswordCannotEnableRejoinWithoutAnExplicitOpenNetworkChoice() {
        let source = SourceSetup(kind: .accsoon, name: "Original", sourceWiFi: "Fixture transmitter")
        var draft = initial; draft.rejoin = true; draft.password = ""
        XCTAssertNil(draft.plan(for: source, current: initial))
        draft.openNetwork = true
        XCTAssertEqual(draft.plan(for: source, current: initial)?.rejoin, .init(enabled: true, password: "", openNetwork: true))
    }
    @MainActor func testRejectedBlankRejoinPasswordPreservesTheExistingSettingAndMemoryValue() {
        let suite = "app.setbeam.tests.rejoin-password.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(true, forKey: "transmitterWiFiRejoin")
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = SessionModel(preferences: preferences)
        model.setup = SourceSetup(kind: .accsoon, name: "Fixture", sourceWiFi: "Fixture transmitter")
        model.transmitterWiFiPassword = "existing test password"
        XCTAssertFalse(model.setTransmitterRejoin(true, password: ""))
        XCTAssertTrue(model.transmitterRejoin)
        XCTAssertEqual(model.transmitterWiFiPassword, "existing test password")
        XCTAssertNotNil(model.rejoinProblem)
    }
    @MainActor func testTurningRememberOffForTheSavedSourcePreventsRestoration() throws {
        let suite = "app.setbeam.tests.forget-current.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let setup = SourceSetup(kind: .capture, name: "Fixture", videoID: "fixture-video")
        try ProvenSetupStore(defaults: preferences).confirm(setup)
        let model = SessionModel(preferences: preferences)
        model.setup = setup
        model.renameSource(setup.name, remember: false)
        XCTAssertNil(model.provenSetup)
        XCTAssertNil(SessionModel(preferences: preferences).provenSetup)
        XCTAssertFalse(model.rememberSetup)
    }
    func testStreamEntryNeverUsesAnIncomingPrivateKey() {
        XCTAssertNil(SessionModel.networkSourcePrefill(kind: .incoming, activeAddress: "private-incoming-key"))
        XCTAssertNil(SessionModel.networkSourcePrefill(kind: .accsoon, activeAddress: "not-rtsp"))
        XCTAssertNil(SessionModel.networkSourcePrefill(kind: nil, activeAddress: "not-rtsp"))
        XCTAssertEqual(SessionModel.networkSourcePrefill(kind: .network, activeAddress: "rtsp://source/live"), "rtsp://source/live")
    }
    @MainActor func testForgettingAnOlderSourceKeepsTheCurrentRememberIntent() throws {
        let suite = "app.setbeam.tests.forget-other.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let old = SourceSetup(kind: .capture, name: "Old Cam", videoID: "old-video")
        try ProvenSetupStore(defaults: preferences).confirm(old)
        let model = SessionModel(preferences: preferences)
        let current = SourceSetup(kind: .capture, name: "New Cam", videoID: "new-video")
        model.setup = current
        model.forgetSetup()
        XCTAssertNil(model.provenSetup)
        XCTAssertEqual(model.setup?.id, current.id)
        XCTAssertTrue(model.rememberSetup)
    }

}

