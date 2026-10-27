import XCTest
@testable import SetbeamCore

final class SessionLogTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SessionLogTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testUnconfiguredLogWritesNothing() throws {
        let log = SessionLog()
        log.record("ignored")
        XCTAssertNil(log.currentFile)
    }

    func testEntriesAreRedactedJSONLinesInAPrivateFile() throws {
        let directory = try temporaryDirectory(), log = SessionLog()
        log.configure(directory: directory)
        let secret = String(repeating: "f0", count: 32)
        log.record("source.restart", ["reason": "exited", "error": "rtsp://publisher:\(secret)@127.0.0.1:5554/local refused", "failures": 2, "sharing": true,
                                      "frameAge": 0.462])
        let file = try XCTUnwrap(log.currentFile)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(secret))
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(entry["event"] as? String, "source.restart")
        XCTAssertEqual(entry["failures"] as? Int, 2)
        XCTAssertEqual(entry["sharing"] as? Bool, true)
        XCTAssertNotNil(entry["time"] as? String)
        XCTAssertTrue(text.contains("\"frameAge\":0.462,"), text)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testRotationBoundsDiskUse() throws {
        let directory = try temporaryDirectory(), log = SessionLog(maxBytes: 400, keep: 2)
        log.configure(directory: directory)
        for index in 0..<60 { log.record("tick", ["index": index]) }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(names, ["session.log", "session.1.log", "session.2.log"])
        for name in names {
            let size = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size] as? Int ?? 0
            XCTAssertLessThanOrEqual(size, 400)
        }
        let newest = try String(contentsOf: directory.appendingPathComponent("session.log"), encoding: .utf8)
        XCTAssertTrue(newest.contains("\"index\":59"))
    }

    func testChildExitStatusIsDecodedForTheLog() {
        XCTAssertEqual(MediaRuntime.exitDescription(nil), "running")
        XCTAssertEqual(MediaRuntime.exitDescription(8 << 8), "code 8")
        XCTAssertEqual(MediaRuntime.exitDescription(9), "signal 9")
    }
}
