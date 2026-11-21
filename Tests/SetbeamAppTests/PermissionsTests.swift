import XCTest
import AVFoundation
import CoreLocation
@testable import SetbeamCore
@testable import SetbeamApp

final class PermissionsTests: XCTestCase {
    func testEachChoiceNeedsOnlyItsOwnAccess() {
        XCTAssertEqual(PermissionUses(sharing: false).needs, [], "The sample feed alone needs no access")
        XCTAssertEqual(PermissionUses(sharing: true).needs, [.localNetwork])
        XCTAssertEqual(PermissionUses(screen: true, sharing: false).needs, [.screenRecording])
        XCTAssertEqual(PermissionUses(camera: true, sharing: false).needs, [.camera, .microphone])
        XCTAssertEqual(PermissionUses(transmitter: true, sharing: false).needs, [.localNetwork, .location])
        XCTAssertFalse(PermissionUses(screen: true, camera: true, sharing: true).needs.contains(.location),
                       "Location is only for transmitter Wi-Fi rejoin")
    }

    func testReportedStatusesStayDistinct() {
        XCTAssertEqual(PermissionState.media(.authorized), .allowed)
        XCTAssertEqual(PermissionState.media(.notDetermined), .notAsked)
        XCTAssertEqual(PermissionState.media(.denied), .denied)
        XCTAssertEqual(PermissionState.media(.restricted), .denied)
        XCTAssertEqual(PermissionState.location(.authorizedAlways), .allowed)
        XCTAssertEqual(PermissionState.location(.notDetermined), .notAsked)
        XCTAssertEqual(PermissionState.location(.denied), .denied)
    }

    @MainActor func testPermissionChoicesPersist() throws {
        let suite = "app.setbeam.tests.permissions.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = SessionModel(preferences: preferences)
        model.permissionUses = PermissionUses(screen: true, transmitter: true, sharing: false)
        let relaunched = SessionModel(preferences: preferences)
        XCTAssertEqual(relaunched.permissionUses, PermissionUses(screen: true, transmitter: true, sharing: false))
    }
}
