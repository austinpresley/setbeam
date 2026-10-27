import XCTest
@testable import SetbeamCore

final class MediaOutputContractTests: XCTestCase {
    private func video(_ codec: String = "H264", profile: String = "Constrained Baseline") -> [String: Any] {
        ["codec": codec, "codecProps": ["profile": profile, "width": 1920, "height": 1080]]
    }
    func testObservedBaselineVideoWithOptionalOpusIsUsable() {
        XCTAssertTrue(MediaOutputContract.accepts(path: ["tracks2": [video()]]))
        XCTAssertTrue(MediaOutputContract.accepts(path: ["tracks2": [video(profile: "Baseline"), ["codec": "Opus"]]]))
    }
    func testUnknownOrIncompatibleObservedFormatsDoNotEstablishReadiness() {
        for tracks in [[], [video("H265")], [video(profile: "High")], [video(), ["codec": "MPEG-4 Audio"]],
                       [video(), video()], [["codec": "H264"]]] as [[[String: Any]]] {
            XCTAssertFalse(MediaOutputContract.accepts(path: ["tracks2": tracks]))
        }
        XCTAssertFalse(MediaOutputContract.accepts(path: nil))
        XCTAssertFalse(MediaOutputContract.accepts(path: ["tracks": ["H264", "Opus"]]))
    }
}
