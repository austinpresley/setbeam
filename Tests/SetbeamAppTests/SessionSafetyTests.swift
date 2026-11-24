import XCTest
import SetbeamCore
@testable import SetbeamApp

final class SessionSafetyTests: XCTestCase {
    @MainActor func testUnpreparedRuntimeKeepsPlaybackControlsDisabled() async {
        let model = SessionModel()
        let unused = URL(fileURLWithPath: "/unused-setbeam-tools")
        let runtime = MediaRuntime(paths: RuntimePaths(tools: unused, fixtures: unused))
        model.apply(await runtime.snapshot())
        XCTAssertNil(model.preview)
        XCTAssertFalse(model.state.monitoring)
        XCTAssertFalse(model.canShare)
    }

    @MainActor func testStopRemainsAvailableDuringSourceWorkAndPreservesItsBusyState() async throws {
        var state = SessionState()
        state.beginMonitoring()
        try state.startSharing()
        let model = SessionModel(initialState: state)
        model.busy = true
        XCTAssertTrue(model.canStopSharing)
        model.stopSharing()
        XCTAssertTrue(model.stoppingSharing)
        XCTAssertFalse(model.canStopSharing)
        XCTAssertEqual(model.floatingPresentation.center, .hidden)
        let deadline = Date().addingTimeInterval(2)
        while model.stoppingSharing && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.state.sharing)
        XCTAssertTrue(model.busy)
        XCTAssertFalse(model.stoppingSharing)
    }

    @MainActor func testMissingSavedCredentialPreservesActiveSourceAndSharing() throws {
        var state = SessionState()
        state.beginMonitoring()
        try state.startSharing()
        let model = SessionModel(initialState: state)
        let current = SourceSetup(kind: .sample, name: "Current private monitor")
        model.setup = current
        let unavailable = SourceSetup(kind: .network, name: "Unavailable saved input")
        model.restore(unavailable)
        XCTAssertEqual(model.setup, current)
        XCTAssertTrue(model.state.monitoring)
        XCTAssertTrue(model.state.sharing)
        XCTAssertNotNil(model.error)
    }
}

extension SessionSafetyTests {
    @MainActor func testDeniedReplacementRetainsItsOwnCandidateAndPermission() throws {
        let suite = "setbeam-permission-recovery-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var state = SessionState()
        state.beginMonitoring()
        try state.startSharing()
        let model = SessionModel(initialState: state, preferences: preferences)
        let active = SourceSetup(kind: .sample, name: "Current sample")
        model.setup = active
        var candidate = SourceSetup(kind: .capture, name: "Camera to try")
        candidate.videoID = "camera-id"
        candidate.audioID = "sound-id"
        let denied = DeniedSourceRequest(candidate: candidate, address: nil, remember: false, permission: .microphone)
        model.recordDeniedSource(denied)

        XCTAssertEqual(model.deniedSourceRequest, denied)
        XCTAssertEqual(model.setup, active)
        XCTAssertTrue(model.state.sharing)
        XCTAssertEqual(model.recoveryTitle, "Allow Microphone Access")
        XCTAssertTrue(model.recoveryDetail.contains(candidate.name))
        XCTAssertEqual(model.deniedSourceRequest?.permission.settingsURL.query, "Privacy_Microphone")
        XCTAssertEqual(PermissionKind.camera.settingsURL.query, "Privacy_Camera")
        XCTAssertEqual(PermissionKind.screenRecording.settingsURL.query, "Privacy_ScreenCapture")
    }

    @MainActor func testSoundExpectationIsClearedWhenTheSourceChanges() {
        let suite = "setbeam-test-sound-expectation-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = SessionModel(preferences: preferences)
        model.expectsAudio = false
        model.source = .sample
        XCTAssertEqual(model.expectsAudio, false)
        model.source = .network("rtsp://127.0.0.1/setup-check")
        XCTAssertNil(model.expectsAudio)
    }

    func testLocalNetworkPermissionUseMatchesPlatformAvailability() {
        XCTAssertEqual(PermissionUses(transmitter: true).needs.contains(.localNetwork), PermissionKind.localNetwork.isAvailable)
        if #available(macOS 15, *) {
            XCTAssertTrue(PermissionKind.localNetwork.isAvailable)
        } else {
            XCTAssertFalse(PermissionKind.localNetwork.isAvailable)
        }
    }
}
