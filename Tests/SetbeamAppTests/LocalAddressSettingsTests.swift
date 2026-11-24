import XCTest
@testable import SetbeamCore
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
        let listener = ViewerGateway.Binding(id: UUID(), address: binding.address, port: 51234, shortAddressPath: nil)
        let ip = try XCTUnwrap(binding.invitation(currentToken: token, listener: listener, localLabel: nil))
        XCTAssertNil(ip.localURL)
        XCTAssertEqual(ip.preferredURL, ip.ipURL)

        let named = try XCTUnwrap(binding.invitation(currentToken: token, listener: listener, localLabel: "setbeam-2"))
        XCTAssertEqual(named.localURL?.absoluteString, "http://setbeam-2.local:51234/s/\(token)/",
                       "Only the host changes; the port and private code stay")
        XCTAssertEqual(named.preferredURL, named.localURL)
        XCTAssertEqual(named.ipURL, ip.ipURL, "Join codes keep the IP address")
    }

    func testStaleBindCannotConfirmCurrentInvitation() {
        let old = ViewingGatewayBinding(address: "192.0.2.10", token: "share")
        var current = ViewingGatewayBinding(address: "192.0.2.11", token: "share")
        let oldListener = ViewerGateway.Binding(id: UUID(), address: old.address, port: 9000, shortAddressPath: nil)
        let currentListener = ViewerGateway.Binding(id: UUID(), address: current.address, port: 9000, shortAddressPath: nil)
        let wrongPort = ViewerGateway.Binding(id: UUID(), address: current.address, port: 9001, shortAddressPath: nil)
        XCTAssertFalse(current.confirm(id: old.id, port: 9000, currentToken: "share"))
        XCTAssertNil(current.invitation(currentToken: "share", listener: currentListener, localLabel: nil))
        XCTAssertFalse(current.confirm(id: current.id, port: 9000, currentToken: nil))
        XCTAssertTrue(current.confirm(id: current.id, port: 9000, currentToken: "share"))
        XCTAssertNil(current.invitation(currentToken: "share", listener: nil, localLabel: nil))
        XCTAssertNil(current.invitation(currentToken: "share", listener: oldListener, localLabel: nil))
        XCTAssertNil(current.invitation(currentToken: "share", listener: wrongPort, localLabel: nil))
        XCTAssertEqual(current.invitation(currentToken: "share", listener: currentListener, localLabel: nil)?.binding, currentListener.id)
        XCTAssertNil(current.invitation(currentToken: nil, listener: currentListener, localLabel: nil))
        XCTAssertNil(current.invitation(currentToken: "next-share", listener: currentListener, localLabel: nil))
    }

    func testListenerRetryChangesInvitationEndorsementAtTheSameURL() {
        var binding = ViewingGatewayBinding(address: "192.0.2.10", token: "share")
        XCTAssertTrue(binding.confirm(id: binding.id, port: 9000, currentToken: "share"))
        let first = ViewerGateway.Binding(id: UUID(), address: binding.address, port: 9000, shortAddressPath: nil)
        let retry = ViewerGateway.Binding(id: UUID(), address: binding.address, port: 9000, shortAddressPath: nil)
        let original = binding.invitation(currentToken: "share", listener: first, localLabel: nil)
        let replacement = binding.invitation(currentToken: "share", listener: retry, localLabel: nil)
        XCTAssertEqual(original?.ipURL, replacement?.ipURL)
        XCTAssertNotEqual(original?.binding, replacement?.binding)
    }

    func testLoopbackBindingOffersNoInvitation() {
        var binding = ViewingGatewayBinding(address: "127.0.0.2", token: "share")
        XCTAssertTrue(binding.confirm(id: binding.id, port: 9000, currentToken: "share"))
        let listener = ViewerGateway.Binding(id: UUID(), address: binding.address, port: 9000, shortAddressPath: nil)
        XCTAssertNotNil(binding.url(currentToken: "share", listener: listener))
        XCTAssertNil(binding.invitation(currentToken: "share", listener: listener, localLabel: "setbeam"))
    }
}
