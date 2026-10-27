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
