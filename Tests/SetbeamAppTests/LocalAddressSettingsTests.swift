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
        let token = String(repeating: "a", count: 64)
        var binding = ViewingGatewayBinding(address: "192.168.1.20", token: token)
        XCTAssertTrue(binding.confirm(id: binding.id, port: 51234, currentToken: token))
        let ip = try XCTUnwrap(binding.invitation(currentToken: token, listenerReady: true, localLabel: nil))
        XCTAssertNil(ip.localURL)
        XCTAssertEqual(ip.preferredURL, ip.ipURL)

        let named = try XCTUnwrap(binding.invitation(currentToken: token, listenerReady: true, localLabel: "setbeam-2"))
        XCTAssertEqual(named.localURL?.absoluteString, "http://setbeam-2.local:51234/s/\(token)/",
                       "Only the host changes; the port and private code stay")
        XCTAssertEqual(named.preferredURL, named.localURL)
        XCTAssertEqual(named.ipURL, ip.ipURL, "Join codes keep the IP address")
    }

    func testStaleBindCannotConfirmCurrentInvitation() {
        let old = ViewingGatewayBinding(address: "192.0.2.10", token: "share")
        var current = ViewingGatewayBinding(address: "192.0.2.11", token: "share")
        XCTAssertFalse(current.confirm(id: old.id, port: 9000, currentToken: "share"))
        XCTAssertNil(current.invitation(currentToken: "share", listenerReady: true, localLabel: nil))
        XCTAssertFalse(current.confirm(id: current.id, port: 9000, currentToken: nil))
        XCTAssertTrue(current.confirm(id: current.id, port: 9000, currentToken: "share"))
        XCTAssertNil(current.invitation(currentToken: "share", listenerReady: false, localLabel: nil))
        XCTAssertNotNil(current.invitation(currentToken: "share", listenerReady: true, localLabel: nil))
        XCTAssertNil(current.invitation(currentToken: nil, listenerReady: true, localLabel: nil))
        XCTAssertNil(current.invitation(currentToken: "next-share", listenerReady: true, localLabel: nil))
    }

    func testLoopbackBindingOffersNoInvitation() {
        var binding = ViewingGatewayBinding(address: "127.0.0.2", token: "share")
        XCTAssertTrue(binding.confirm(id: binding.id, port: 9000, currentToken: "share"))
        XCTAssertNotNil(binding.url(currentToken: "share", listenerReady: true))
        XCTAssertNil(binding.invitation(currentToken: "share", listenerReady: true, localLabel: "setbeam"))
    }
}
