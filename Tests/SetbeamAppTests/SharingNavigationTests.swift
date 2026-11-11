import XCTest
import SetbeamCore
@testable import SetbeamApp

final class SharingNavigationTests: XCTestCase {
    @MainActor func testViewingNetworkDeepLinkOpensItsDisclosureWithoutChangingTheNetwork() {
        let model = SessionModel()
        let network = model.networkChoice
        model.showViewingNetwork()
        XCTAssertEqual(model.sharingSection, .options)
        XCTAssertTrue(model.sharingOptionsNetworkRequested)
        XCTAssertEqual(model.networkChoice, network)
        model.showSharing(.options)
        XCTAssertFalse(model.sharingOptionsNetworkRequested)
    }
    @MainActor func testOpeningAndSwitchingPanelsNeverChangesSharingOrHold() throws {
        let suite = "app.setbeam.tests.sharing-navigation.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var state = SessionState()
        state.beginMonitoring(); state.updateSource(available: true)
        try state.startSharing(); try state.setHold(true)
        let model = SessionModel(initialState: state, preferences: preferences)
        XCTAssertNil(model.sharingSection)
        XCTAssertFalse(model.sharingInWindow)
        for section in SharingSection.allCases {
            model.showSharing(section)
            XCTAssertEqual(model.sharingSection, section)
            XCTAssertTrue(model.state.monitoring)
            XCTAssertTrue(model.state.sharing)
            XCTAssertTrue(model.state.holding)
        }
        model.showSharingInWindow()
        model.showSharing(.viewers)
        XCTAssertTrue(model.sharingInWindow, "Switching tabs keeps the chosen window presentation")
        model.closeSharing()
        XCTAssertNil(model.sharingSection)
        XCTAssertTrue(model.state.sharing)
        XCTAssertTrue(model.state.holding)
    }

    @MainActor func testStatusReopensLastSectionAndNeverChangesMedia() {
        let suite = "app.setbeam.tests.sharing-status.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = SessionModel(preferences: preferences)
        model.showSharing(.viewers); model.closeSharing(); model.showSharingStatus()
        XCTAssertEqual(model.sharingSection, .viewers)
        XCTAssertFalse(model.state.sharing)
        model.showSharingInWindow(); model.showSharingStatus()
        XCTAssertTrue(model.sharingInWindow)
        XCTAssertEqual(model.sharingSection, .viewers)
    }

    @MainActor func testSourceAndSharingDestinationsKeepTheSelectedSourcePrivate() {
        let suite = "app.setbeam.tests.destinations.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = SessionModel(preferences: preferences)
        let setup = SourceSetup(kind: .network, name: "Computer display")
        model.setup = setup
        model.openSourceDetails()
        XCTAssertEqual(model.sheet, .sourceDetails)
        model.openNetworkSource()
        XCTAssertEqual(model.sheet, .networkSource)
        model.showSharing(.options)
        XCTAssertEqual(model.sheet, .networkSource, "A request review preserves the source form")
        XCTAssertTrue(model.sharingInWindow, "Use the separate window while a modal source task is open")
        XCTAssertEqual(model.setup?.id, setup.id)
        XCTAssertFalse(model.state.sharing)
        XCTAssertFalse(model.state.holding)
    }

    @MainActor func testChangingViewingNetworkPreservesWiFiJoinDetails() {
        let suite = "app.setbeam.tests.viewer-network.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set("Studio Guests", forKey: "wifiSSID")
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = SessionModel(preferences: preferences)
        model.wifiPassword = "Test-only join password"
        model.changeViewingNetwork("lo0")
        XCTAssertEqual(model.networkChoice, "lo0")
        XCTAssertEqual(model.wifiSSID, "Studio Guests")
        XCTAssertEqual(model.wifiPassword, "Test-only join password")
        XCTAssertEqual(preferences.string(forKey: "wifiSSID"), "Studio Guests")
    }
    func testPresentationDecisionsProtectThePictureAndModalDrafts() {
        XCTAssertEqual(SharingDestination.resolve(section: nil, preferWindow: true, hasSheet: false, screenWidth: 1600), .hidden)
        XCTAssertEqual(SharingDestination.resolve(section: .invite, preferWindow: false, hasSheet: false, screenWidth: 1600), .inline)
        XCTAssertEqual(SharingDestination.resolve(section: .viewers, preferWindow: false, hasSheet: false, screenWidth: 900), .window)
        XCTAssertEqual(SharingDestination.resolve(section: .viewers, preferWindow: false, hasSheet: true, screenWidth: 1600), .window)
        XCTAssertEqual(SharingDestination.resolve(section: .options, preferWindow: true, hasSheet: false, screenWidth: 1600), .window)
    }
    @MainActor func testRepeatedViewerRequestsRaiseTheSameDestinationAndKeepDrafts() {
        let suite = "app.setbeam.tests.sharing-focus.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = SessionModel(preferences: preferences)
        model.showSharing(.options)
        model.sharingDraft?.address = "draft-address"
        model.sharingDraft?.quality = .light
        model.closeSharing()
        model.showSharing(.options)
        XCTAssertEqual(model.sharingDraft?.address, "draft-address")
        XCTAssertEqual(model.sharingDraft?.quality, .light)
        model.showSharing(.viewers); model.showSharingInWindow()
        let focus = model.sharingFocusRequest
        model.showSharing(.viewers)
        XCTAssertGreaterThan(model.sharingFocusRequest, focus)
        XCTAssertEqual(model.sharingSection, .viewers)
        XCTAssertTrue(model.sharingInWindow)
        model.closeSharing()
        XCTAssertFalse(model.sharingInWindow)
    }

    func testRequestCardSuppressionRequiresTheVisibleViewerDestination() {
        XCTAssertTrue(ViewerRequestPresentation.isVisible(appActive: true, section: .viewers, detached: false, keyIsMonitor: true, keyIsSharing: false, hasSheet: false))
        XCTAssertFalse(ViewerRequestPresentation.isVisible(appActive: true, section: .viewers, detached: false, keyIsMonitor: true, keyIsSharing: false, hasSheet: true))
        XCTAssertTrue(ViewerRequestPresentation.isVisible(appActive: true, section: .viewers, detached: true, keyIsMonitor: false, keyIsSharing: true, hasSheet: true))
        XCTAssertFalse(ViewerRequestPresentation.isVisible(appActive: false, section: .viewers, detached: true, keyIsMonitor: false, keyIsSharing: true, hasSheet: false))
        XCTAssertFalse(ViewerRequestPresentation.isVisible(appActive: true, section: .invite, detached: true, keyIsMonitor: false, keyIsSharing: true, hasSheet: false))
    }

    @MainActor func testDirtySourceSheetCannotBeReplacedByOtherPresentations() {
        let suite = "app.setbeam.tests.sheet-gate.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = SessionModel(preferences: preferences)
        model.sheet = .sourceDetails; model.sourceDetailsDirty = true
        for next in [AppSheet.connection, .networkSource, .rename, .join, .setupCheck, .about] {
            var prepared = false
            XCTAssertFalse(model.present(next) { prepared = true })
            XCTAssertFalse(prepared, "Blocked presentations must not read private settings either")
            XCTAssertEqual(model.sheet, .sourceDetails)
        }
        model.openSources(); model.openNetworkSource(); model.showJoinCodes(); model.returnToPreviousSource()
        XCTAssertEqual(model.sheet, .sourceDetails)
        model.showSharing(.invite)
        XCTAssertEqual(model.sheet, .sourceDetails)
        XCTAssertTrue(model.sharingInWindow)
        model.sourceDetailsDirty = false
        XCTAssertTrue(model.present(.join))
        XCTAssertEqual(model.sheet, .join)
    }

}
