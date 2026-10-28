import XCTest
import SetbeamCore
@testable import SetbeamApp

final class LowFrameRateTests: XCTestCase {
    @MainActor func testSavedRatesRestorePrivatelyAndInvalidValuesFallBackToSource() {
        let suite = "app.setbeam.tests.fps.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = SessionModel(preferences: preferences)
        model.setVideoSettings(quality: .best, frameRate: .fps1, screenRate: .fps5)
        let restored = SessionModel(preferences: preferences)
        XCTAssertEqual(restored.audienceFrameRate, .fps1)
        XCTAssertEqual(restored.screenFrameRate, .fps5)
        XCTAssertFalse(restored.state.sharing)
        preferences.set(999, forKey: "audienceFrameRate")
        preferences.set(-1, forKey: "screenFrameRate")
        let invalid = SessionModel(preferences: preferences)
        XCTAssertEqual(invalid.audienceFrameRate, .source)
        XCTAssertEqual(invalid.screenFrameRate, .source)
    }
    func testOneFPSAllowsJitterButRetainsBoundedFrozenPictureDetection() {
        XCTAssertEqual(PreviewPlaybackTiming.freshnessInterval(sourceFPS: 1), 3)
        XCTAssertEqual(PreviewPlaybackTiming.freshnessInterval(sourceFPS: 30), 2)
        XCTAssertEqual(PreviewPlaybackTiming.freshnessInterval(sourceFPS: 0), 2)
        XCTAssertEqual(PreviewPlaybackTiming.freshnessInterval(sourceFPS: .nan), 2)
        XCTAssertEqual(PreviewPlaybackTiming.freshnessInterval(sourceFPS: 0.01), 6)
    }
}
