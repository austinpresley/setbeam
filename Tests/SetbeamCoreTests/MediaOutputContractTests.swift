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

    func testMonitoringRelayAcceptsTheReceivedEncoding() {
        for codec in ["H264", "H265", "M-JPEG"] {
            XCTAssertTrue(MediaOutputContract.acceptsMonitoring(path: ["tracks2": [video(codec, profile: "High"), ["codec": "Opus"]]]))
        }
        for tracks in [[], [video("VP8")], [video(), video("H265")], [video(), ["codec": "MPEG-4 Audio"]], [["codec": "H265"]],
                       [["codec": "H265", "codecProps": ["profile": "Main", "width": 0, "height": 1080]]]] as [[[String: Any]]] {
            XCTAssertFalse(MediaOutputContract.acceptsMonitoring(path: ["tracks2": tracks]))
        }
    }
    func testOnlyTheAudienceEncodeIsBaselineAndBounded() {
        let audience = MediaOutputContract.audienceVideoArguments(.balanced)
        XCTAssertEqual(audience[audience.firstIndex(of: "-profile:v")! + 1], "baseline")
        XCTAssertEqual(audience[audience.firstIndex(of: "-b:v")! + 1], "6000k")
        XCTAssertEqual(audience[audience.firstIndex(of: "-bf")! + 1], "0")
        let monitoring = MediaOutputContract.monitoringVideoArguments
        XCTAssertEqual(monitoring[monitoring.firstIndex(of: "-profile:v")! + 1], "high")
        XCTAssertEqual(AudienceQuality.allCases.map(\.kilobits), [12_000, 6_000, 3_000])
    }
}
