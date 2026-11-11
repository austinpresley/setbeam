import XCTest
import SetbeamCore
@testable import SetbeamApp

final class SourceChooserStateTests: XCTestCase {
    func testInitialCategoryFollowsTheSourceAndDefaultsToWindows() {
        XCTAssertEqual(SourceCategory.initial(for: nil), .windows)
        for (kind, category) in [(InputKind.macScreen, SourceCategory.displays), (.macWindow, .windows), (.capture, .cameras), (.accsoon, .wireless), (.network, .wireless), (.incoming, .wireless), (.sample, .windows)] {
            XCTAssertEqual(SourceCategory.initial(for: SourceSetup(kind: kind, name: "Same label")), category)
        }
    }

    func testCurrentWindowUsesItsCompleteIdentityRatherThanSavedSetupIDOrName() {
        var saved = SourceSetup(kind: .macWindow, name: "Document")
        saved.window = MacWindowIdentity(windowID: 42, processID: 9, processStart: 100)
        var current = SourceSetup(kind: .macWindow, name: "Renamed document")
        current.window = saved.window
        XCTAssertTrue(SourceChooserSelection.matches(saved, current))
        current.window = MacWindowIdentity(windowID: 42, processID: 9, processStart: 101)
        XCTAssertFalse(SourceChooserSelection.matches(saved, current))
        current.window = MacWindowIdentity(windowID: 43, processID: 9, processStart: 100)
        XCTAssertFalse(SourceChooserSelection.matches(saved, current))
        XCTAssertFalse(SourceChooserSelection.matches(SourceSetup(kind: .macWindow, name: "Document"), nil))
    }

    func testDisplayCaptureAndNetworkMatchingRetainTheirOwnIdentities() {
        let display = SourceSetup(kind: .macScreen, name: "Display", videoID: "ABC")
        XCTAssertTrue(SourceChooserSelection.matches(display, SourceSetup(kind: .macScreen, name: "Renamed", videoID: "abc")))
        XCTAssertFalse(SourceChooserSelection.matches(display, SourceSetup(kind: .capture, name: "Display", videoID: "ABC")))
        let capture = SourceSetup(kind: .capture, name: "Input", videoID: "camera", audioID: "audio-a")
        XCTAssertFalse(SourceChooserSelection.matches(capture, SourceSetup(kind: .capture, name: "Input", videoID: "camera", audioID: "audio-b")))
        let network = SourceSetup(kind: .network, name: "Stream")
        XCTAssertTrue(SourceChooserSelection.matches(network, network))
        XCTAssertFalse(SourceChooserSelection.matches(network, SourceSetup(kind: .network, name: "Stream")))
    }
    func testLastWindowNameDoesNotRepeatTheApplicationAndKeepsIdentitySeparate() {
        var saved = SourceSetup(kind: .macWindow, name: "Capture One · Session A", deviceName: "Capture One")
        saved.window = MacWindowIdentity(windowID: 1, processID: 9, processStart: 10)
        let current = MacWindow(identity: saved.window!, applicationName: "Capture One", bundleIdentifier: nil, title: "Session renamed", width: 800, height: 600)
        XCTAssertEqual(SourceChooserSelection.name(for: saved, window: current), "Session renamed")
        XCTAssertEqual(SourceChooserSelection.name(for: saved, window: nil), "Session A")
        saved.name = "Custom source name"
        XCTAssertEqual(SourceChooserSelection.name(for: saved, window: nil), "Custom source name")
    }

    func testSavedCaptureRequiresItsExactSoundInputForAvailability() {
        let saved = SourceSetup(kind: .capture, name: "Capture", videoID: "video", audioID: "sound")
        let video = CaptureHardware(id: "video", name: "Video", index: 0)
        let wrongSound = CaptureHardware(id: "another", name: "Sound", index: 0, audio: true)
        let missing = SourceChooserAvailability.capture(saved, devices: [video, wrongSound], cameraAllowed: true, microphoneAllowed: true)
        XCTAssertFalse(missing.available)
        XCTAssertTrue(missing.unavailable)
        XCTAssertEqual(missing.text, "Sound input disconnected")
        let sound = CaptureHardware(id: "sound", name: "Sound", index: 1, audio: true)
        XCTAssertTrue(SourceChooserAvailability.capture(saved, devices: [video, sound], cameraAllowed: true, microphoneAllowed: true).available)
    }

    func testSavedCaptureNeedsMicrophoneAccessOnlyWhenItHasSound() {
        let video = CaptureHardware(id: "video", name: "Video", index: 0)
        let sound = CaptureHardware(id: "sound", name: "Sound", index: 1, audio: true)
        let saved = SourceSetup(kind: .capture, name: "Capture", videoID: "video", audioID: "sound")
        let denied = SourceChooserAvailability.capture(saved, devices: [video, sound], cameraAllowed: true, microphoneAllowed: false)
        XCTAssertFalse(denied.available)
        XCTAssertFalse(denied.unavailable)
        XCTAssertEqual(denied.text, "Needs microphone access")
        let silent = SourceSetup(kind: .capture, name: "Capture", videoID: "video")
        XCTAssertTrue(SourceChooserAvailability.capture(silent, devices: [video], cameraAllowed: true, microphoneAllowed: false).available)
    }

}
