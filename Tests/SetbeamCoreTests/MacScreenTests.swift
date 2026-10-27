import XCTest
@testable import SetbeamCore

final class MacScreenTests: XCTestCase {
    func testScreenValidationRequiresDisplayUUID() throws {
        for invalid in ["", "1", "display", "00000000"] {
            XCTAssertThrowsError(try VideoSource.macScreen(displayUUID: invalid).validated())
        }
        let id = UUID().uuidString
        XCTAssertEqual(try VideoSource.macScreen(displayUUID: id).validated(), .macScreen(displayUUID: id))
    }
    func testProvenDisplayRestoresIdentityPrivately() throws {
        let suite = "screen-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID().uuidString
        let store = ProvenSetupStore(defaults: defaults)
        try store.confirm(SourceSetup(kind: .macScreen, name: "This Mac's screen", videoID: id))
        let restored = try XCTUnwrap(ProvenSetupStore(defaults: defaults).setup)
        XCTAssertEqual(restored.videoID, id)
        XCTAssertEqual(try restored.source(), .macScreen(displayUUID: id))
        XCTAssertFalse(SessionState().sharing)
    }
    func testSelectionNeverSubstitutesAnotherDisplay() throws {
        let wanted = MacDisplay(id: UUID().uuidString, name: "Studio", width: 1920, height: 1080, frameRate: 60)
        let other = MacDisplay(id: UUID().uuidString, name: "Studio", width: 1920, height: 1080, frameRate: 60)
        XCTAssertThrowsError(try MacDisplay.resolve(wanted.id, in: [other]))
        XCTAssertEqual(try MacDisplay.resolve(wanted.id.lowercased(), in: [other, wanted]), wanted)
    }
    func testManagedPublisherReceivesExplicitStandardInput() async throws {
        let pipe = Pipe()
        let child = try ManagedChild(name: "stdin check", executable: URL(fileURLWithPath: "/usr/bin/wc"),
                                     arguments: ["-c"], directory: FileManager.default.temporaryDirectory,
                                     standardInput: pipe.fileHandleForReading)
        defer { child.stop() }
        try pipe.fileHandleForReading.close()
        try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 42, count: 4096))
        try pipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !child.capturedOutput.contains("4096") {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(child.capturedOutput.contains("4096"))
    }
    func testDimensionsPreservePixelsAndCapAt4K() {
        let hd = MacDisplay.dimensions(width: 1920, height: 1080)
        XCTAssertEqual(hd.0, 1920); XCTAssertEqual(hd.1, 1080)
        let large = MacDisplay.dimensions(width: 6016, height: 3384)
        XCTAssertEqual(large.0, 3840); XCTAssertEqual(large.1, 2160)
        let portrait = MacDisplay.dimensions(width: 2160, height: 3840)
        XCTAssertEqual(portrait.0, 1214); XCTAssertEqual(portrait.1, 2160)
    }
}
