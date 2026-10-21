import XCTest
import SetbeamCore
@testable import SetbeamApp

final class SessionSafetyTests: XCTestCase {
    @MainActor func testMissingSavedCredentialPreservesActiveSourceAndSharing() throws {
        let model = SessionModel()
        let current = SourceSetup(kind: .sample, name: "Current private monitor")
        model.setup = current
        model.state.beginMonitoring()
        try model.state.startSharing()
        let unavailable = SourceSetup(kind: .network, name: "Unavailable saved input")
        model.restore(unavailable)
        XCTAssertEqual(model.setup, current)
        XCTAssertTrue(model.state.monitoring)
        XCTAssertTrue(model.state.sharing)
        XCTAssertNotNil(model.error)
    }
}
