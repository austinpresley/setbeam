import XCTest
import SetbeamCore
@testable import SetbeamApp

final class LocalAddressSettingsTests: XCTestCase {
    @MainActor func testNameIsSavedValidatedAndRestored() {
        let suite = "app.setbeam.tests.local-address.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = SessionModel(preferences: preferences)
        XCTAssertTrue(model.localAddressEnabled, "Offered by default")
        XCTAssertEqual(model.localAddressLabel, LocalAddressName.defaultLabel)
        XCTAssertEqual(model.localAddress, .stopped, "Nothing is published before sharing")
        XCTAssertEqual(model.localAddressStatus.text, model.canInviteOtherDevices
            ? "Viewers can use setbeam.local while you share." : "Choose a viewing network to use setbeam.local.")

        model.setLocalAddress(enabled: true, label: " Stage-A.local ")
        model.setLocalAddress(enabled: true, label: "stage a")
        let restored = SessionModel(preferences: preferences)
        XCTAssertEqual(restored.localAddressLabel, "stage-a", "An invalid name never replaces the saved one")
        restored.setLocalAddress(enabled: false, label: "stage-a")
        XCTAssertFalse(SessionModel(preferences: preferences).localAddressEnabled)
        XCTAssertEqual(SessionModel(preferences: preferences).localAddressStatus.text, "Off. Invitations use the IP address.")

        preferences.set("bad name!", forKey: "localAddressName")
        XCTAssertEqual(SessionModel(preferences: preferences).localAddressLabel, LocalAddressName.defaultLabel)
    }

    @MainActor func testInvitationUsesActiveNameAndKeepsIPAddressFallback() throws {
        var state = SessionState()
        state.beginMonitoring(); state.updateSource(available: true)
        try state.startSharing(); state.updateAudience(available: true)
        let model = SessionModel(initialState: state)
        let token = String(repeating: "a", count: 64)
        model.viewerURL = URL(string: "http://192.168.1.20:51234/s/\(token)/")
        XCTAssertNil(model.localViewerURL)
        XCTAssertEqual(model.invitationURL, model.viewerURL, "The IP address link until the name is active")

        model.localAddressChanged(.checking("setbeam"))
        XCTAssertNil(model.localViewerURL, "A name still being checked may belong to another host")
        model.localAddressChanged(.active("setbeam-2"))
        XCTAssertEqual(model.localViewerURL?.absoluteString, "http://setbeam-2.local:51234/s/\(token)/",
                       "Only the host changes; the port and private code stay")
        XCTAssertEqual(model.invitationURL, model.localViewerURL)
        XCTAssertEqual(model.viewerURL?.host, "192.168.1.20", "Join codes keep the IP address")
        if model.canInviteOtherDevices {
            XCTAssertEqual(model.localAddressStatus.text, "setbeam.local is in use on this network, so viewers use setbeam-2.local.")
            XCTAssertTrue(model.localAddressStatus.attention)
        }
        model.localAddressChanged(.unavailable(.inUse))
        XCTAssertEqual(model.invitationURL, model.viewerURL)
    }
}
