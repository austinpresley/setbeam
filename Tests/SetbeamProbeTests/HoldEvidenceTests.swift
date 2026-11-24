import XCTest
@testable import SetbeamProbe

final class HoldEvidenceTests: XCTestCase {
    func testPCMPeakRequiresTheEntireWindowAndIncludesTheLastChannel() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }

        try Data([0, 0, 0, 0, 0, 0, 0, 128]).write(to: file)
        XCTAssertEqual(try SetbeamProbe.pcmPeak(at: file, samples: 4), 32_768)

        try Data([0, 0, 0, 0, 0, 0, 0]).write(to: file)
        XCTAssertThrowsError(try SetbeamProbe.pcmPeak(at: file, samples: 4))

        try Data([0, 0, 0, 0]).write(to: file)
        XCTAssertThrowsError(try SetbeamProbe.pcmPeak(at: file, samples: 4))
    }
}
