import XCTest
@testable import SetbeamCore

final class MacWindowTests: XCTestCase {
    private let identity = MacWindowIdentity(windowID: 4242, processID: 900, processStart: 1_700_000_000_000_000)
    private func presence(_ rows: [MacWindowRow]?, start: Int64? = 1_700_000_000_000_000) -> MacWindowPresence {
        MacWindowLocator.presence(of: identity, rows: rows, processStart: { _ in start })
    }

    func testWindowSourceRequiresCompleteIdentity() throws {
        for invalid in [MacWindowIdentity(windowID: 0, processID: 900, processStart: 1), MacWindowIdentity(windowID: 1, processID: 0, processStart: 1),
                        MacWindowIdentity(windowID: 1, processID: 900, processStart: 0)] {
            XCTAssertThrowsError(try VideoSource.macWindow(invalid).validated())
        }
        XCTAssertEqual(try VideoSource.macWindow(identity).validated(), .macWindow(identity))
        XCTAssertThrowsError(try SourceSetup(kind: .macWindow, name: "Window").source())
    }

    func testOnlyTheExactRuntimeWindowIsPresent() {
        XCTAssertEqual(presence([MacWindowRow(windowID: 4242, processID: 900, onScreen: true, title: "Session A")]), .visible)
        // A new title is the same window, never a reason to look elsewhere.
        XCTAssertEqual(presence([MacWindowRow(windowID: 4242, processID: 900, onScreen: true, title: "Session B")]), .visible)
        XCTAssertEqual(presence([MacWindowRow(windowID: 4242, processID: 900, onScreen: false)]), .hidden)
        // Another window with the same title, or the number owned by another process, is not a match.
        XCTAssertEqual(presence([MacWindowRow(windowID: 4243, processID: 900, onScreen: true, title: "Session A")]), .closed)
        XCTAssertEqual(presence([MacWindowRow(windowID: 4242, processID: 901, onScreen: true, title: "Session A")]), .closed)
        // A relaunched owner that received the same process ID has a different start time.
        XCTAssertEqual(presence([MacWindowRow(windowID: 4242, processID: 900, onScreen: true)], start: 1_700_000_000_000_001), .closed)
        XCTAssertEqual(presence([MacWindowRow(windowID: 4242, processID: 900, onScreen: true)], start: nil), .closed)
        XCTAssertEqual(presence(nil), .hidden)
        XCTAssertThrowsError(try MacWindowLocator.require(MacWindowIdentity(windowID: UInt32.max, processID: Int32.max, processStart: 1))) {
            XCTAssertEqual($0.localizedDescription, MacWindowLocator.closedMessage)
        }
    }

    func testProcessStartDistinguishesRunningProcesses() throws {
        let start = try XCTUnwrap(MacProcess.startTime(getpid()))
        XCTAssertEqual(MacProcess.startTime(getpid()), start)
        XCTAssertGreaterThan(start, 1_577_836_800_000_000)
        XCTAssertLessThanOrEqual(Double(start) / 1_000_000, Date().timeIntervalSince1970)
        XCTAssertNil(MacProcess.startTime(0))
        XCTAssertNil(MacProcess.startTime(Int32.max))
    }

    func testWindowSetupRestoresExactIdentityAndOlderSetupsStillDecode() throws {
        let suite = "window-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var setup = SourceSetup(kind: .macWindow, name: "Capture One · Session", deviceName: "Capture One")
        setup.window = identity
        try ProvenSetupStore(defaults: defaults).confirm(setup)
        let restored = try XCTUnwrap(ProvenSetupStore(defaults: defaults).setup)
        XCTAssertEqual(restored.window, identity)
        XCTAssertEqual(try restored.source(), .macWindow(identity))
        let older = #"{"id":"\#(UUID().uuidString)","kind":"macScreen","name":"Display","videoID":"\#(UUID().uuidString)","networkAddress":"","sourceWiFi":"","inputPort":19350}"#
        XCTAssertNil(try JSONDecoder().decode(SourceSetup.self, from: Data(older.utf8)).window)
    }

    func testLabelsAreBoundedAndTitlesStayOutOfLogs() {
        let window = MacWindow(identity: identity, applicationName: "Capture One", bundleIdentifier: nil, title: "Client\nproof\t" + String(repeating: "x", count: 300), width: 2880, height: 1800)
        XCTAssertFalse(window.title.contains("\n"))
        XCTAssertEqual(window.title.count, 120)
        XCTAssertTrue(window.sourceName.hasPrefix("Capture One · Client proof"))
        let untitled = MacWindow(identity: identity, applicationName: " ", bundleIdentifier: nil, title: "  ", width: 1, height: 1)
        XCTAssertEqual(untitled.label, "Untitled window")
        XCTAssertEqual(untitled.applicationName, "Application")
        XCTAssertEqual(VideoSource.macWindow(identity).label, "Application window")
        XCTAssertTrue(InputKind.macWindow.isMacCapture && VideoSource.macWindow(identity).isMacCapture)
        XCTAssertFalse(VideoSource.macWindow(identity).isCapture)
    }

    func testEligibilityExcludesSetbeamAndNonDocumentWindows() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertTrue(MacWindow.isEligible(processID: 900, ownProcessID: 1, layer: 0, onScreen: true, frame: frame))
        XCTAssertFalse(MacWindow.isEligible(processID: 1, ownProcessID: 1, layer: 0, onScreen: true, frame: frame))
        XCTAssertFalse(MacWindow.isEligible(processID: nil, ownProcessID: 1, layer: 0, onScreen: true, frame: frame))
        XCTAssertFalse(MacWindow.isEligible(processID: 900, ownProcessID: 1, layer: 25, onScreen: true, frame: frame))
        XCTAssertFalse(MacWindow.isEligible(processID: 900, ownProcessID: 1, layer: 0, onScreen: false, frame: frame))
        XCTAssertFalse(MacWindow.isEligible(processID: 900, ownProcessID: 1, layer: 0, onScreen: true, frame: CGRect(x: 0, y: 0, width: 30, height: 600)))
        XCTAssertFalse(MacWindow.isEligible(processID: 900, ownProcessID: 1, layer: 0, onScreen: true, frame: CGRect(x: CGFloat.nan, y: 0, width: 800, height: 600)))
    }

    func testOrderIsStableByApplicationTitleAndNumber() {
        func window(_ id: UInt32, _ app: String, _ title: String) -> MacWindow {
            MacWindow(identity: MacWindowIdentity(windowID: id, processID: 9, processStart: 1), applicationName: app, bundleIdentifier: nil, title: title, width: 10, height: 10)
        }
        let windows = [window(3, "Safari", "B"), window(2, "Capture One", "Session 10"), window(1, "Capture One", "Session 9"), window(4, "Safari", "B")]
        XCTAssertEqual(windows.sorted(by: MacWindow.precedes).map(\.identity.windowID), [1, 2, 3, 4])
    }

    func testWindowCaptureUsesTheScreenRateCeiling() {
        XCTAssertEqual(VideoFrameRate.source.captureRate(for: MacWindow.nativeFrameRate), 30)
        XCTAssertEqual(VideoFrameRate(rawValue: 1)?.captureRate(for: MacWindow.nativeFrameRate), 1)
    }
}
