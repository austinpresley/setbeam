import Foundation
import XCTest
@testable import SetbeamApp

final class IntegrationSessionFileTests: XCTestCase {
    func testNormalLaunchCannotExportSession() {
        XCTAssertNil(IntegrationSessionFile(arguments: ["Setbeam", "--session-file", "/tmp/session.json"]))
    }

    func testExportHasPrivatePermissionsAndRetiresWithTheSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json")
        let export = try XCTUnwrap(IntegrationSessionFile(arguments: ["Setbeam", "--integration-demo", "--session-file", url.path]))
        let firstShare = Data("sample-link".utf8)
        try export.write(firstShare)
        XCTAssertEqual(try Data(contentsOf: url), firstShare)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        export.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try export.write(firstShare)
        let unrelatedFile = Data("other-owner".utf8)
        try unrelatedFile.write(to: url, options: .atomic)
        export.clear()
        XCTAssertEqual(try Data(contentsOf: url), unrelatedFile)
    }
}
