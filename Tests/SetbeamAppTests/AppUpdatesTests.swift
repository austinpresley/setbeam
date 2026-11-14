import XCTest
@testable import SetbeamApp

final class AppUpdatesTests: XCTestCase {
    private let feed = "https://austinpresley.github.io/setbeam/appcast.xml"

    func testNormalReleaseLaunchChecksForUpdates() {
        XCTAssertEqual(UpdateAvailability.resolve(feedURL: feed, arguments: ["/Applications/Setbeam.app/Contents/MacOS/Setbeam"], environment: [:]), .enabled)
    }

    func testDeveloperBuildWithoutFeedNeverChecks() {
        XCTAssertEqual(UpdateAvailability.resolve(feedURL: nil, arguments: ["Setbeam"], environment: [:]), .noFeed)
        XCTAssertEqual(UpdateAvailability.resolve(feedURL: "", arguments: ["Setbeam"], environment: [:]), .noFeed)
    }

    func testInsecureFeedIsRejected() {
        XCTAssertEqual(UpdateAvailability.resolve(feedURL: "http://example.com/appcast.xml", arguments: ["Setbeam"], environment: [:]), .noFeed)
    }

    func testIntegrationAndQALaunchesStayOffline() {
        XCTAssertEqual(UpdateAvailability.resolve(feedURL: feed, arguments: ["Setbeam", "--integration-demo"], environment: [:]), .testLaunch)
        XCTAssertEqual(UpdateAvailability.resolve(feedURL: feed, arguments: ["Setbeam"], environment: ["SETBEAM_DISABLE_UPDATES": "1"]), .testLaunch)
    }

    @MainActor func testAppWithoutFeedCreatesNoUpdater() {
        let updater = AppUpdater(bundle: Bundle(for: Self.self), arguments: ["Setbeam"], environment: [:])
        XCTAssertEqual(updater.availability, .noFeed)
        XCTAssertFalse(updater.canCheck)
        updater.checkForUpdates()
        XCTAssertNil(updater.waitingVersion)
    }
}
