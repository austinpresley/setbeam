import XCTest
import ScreenCaptureKit
@testable import SetbeamCore
@testable import SetbeamApp

@MainActor final class WindowSourcePreviewTests: XCTestCase {
    private func window(_ id: UInt32, _ title: String = "Fixture") -> MacWindow {
        MacWindow(identity: MacWindowIdentity(windowID: id, processID: 900, processStart: 1), applicationName: "Fixture", bundleIdentifier: nil, title: title, width: 800, height: 500)
    }
    private func image() -> CGImage {
        CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    func testWithoutAccessNothingIsListedOrCaptured() async {
        var listed = 0
        let previews = WindowSourcePreviews(list: { listed += 1; return [] }, capture: { _, _ in XCTFail("captured"); throw CancellationError() })
        await previews.refresh(permitted: false, monitored: nil)
        XCTAssertEqual(listed, 0)
        XCTAssertFalse(previews.loaded)
        XCTAssertTrue(previews.windows.isEmpty)
    }

    func testMonitoredWindowReusesTheFeedAndPassesAreBounded() async {
        let windows = (1...12).map { window(UInt32($0)) }
        var captured: [UInt32] = []
        let picture = image()
        let previews = WindowSourcePreviews(list: { windows.map { ($0, nil) } }, capture: { window, _ in captured.append(window.identity.windowID); return picture })
        await previews.refresh(permitted: true, monitored: windows[0].identity)
        XCTAssertFalse(captured.contains(1))
        XCTAssertEqual(captured.count, WindowSourcePreviews.picturesPerPass)
        XCTAssertNil(previews.images[windows[0].identity])
        // Once rows report visibility, only those rows are refreshed.
        captured = []
        previews.appeared(windows[10].identity); previews.appeared(windows[11].identity)
        await previews.refresh(permitted: true, monitored: windows[0].identity)
        XCTAssertEqual(captured, [11, 12])
    }

    func testClosingTheChooserDiscardsALateScreenshot() async throws {
        let gate = CaptureGate(), target = window(7), picture = image()
        let previews = WindowSourcePreviews(list: { [(target, nil)] }, capture: { _, _ in await gate.wait(); return picture })
        let refresh = Task { await previews.refresh(permitted: true, monitored: nil) }
        for _ in 0..<100 where !(await gate.waiting) { try await Task.sleep(nanoseconds: 10_000_000) }
        previews.clear()
        await gate.open()
        await refresh.value
        XCTAssertTrue(previews.images.isEmpty)
        XCTAssertTrue(previews.windows.isEmpty)
    }

    func testFailedPictureIsMarkedUnavailableAndClosedWindowsDropOut() async {
        var windows = [window(1), window(2, "")]
        let previews = WindowSourcePreviews(list: { windows.map { ($0, nil) } }, capture: { window, _ in
            if window.identity.windowID == 2 { throw SetbeamError.unavailable("closed") }
            return self.image()
        })
        await previews.refresh(permitted: true, monitored: nil)
        XCTAssertNotNil(previews.images[windows[0].identity])
        XCTAssertTrue(previews.unavailable.contains(windows[1].identity))
        XCTAssertEqual(previews.windows[1].label, "Fixture")
        windows.removeFirst()
        await previews.refresh(permitted: true, monitored: nil)
        XCTAssertEqual(previews.windows.map(\.identity.windowID), [2])
        XCTAssertTrue(previews.images.isEmpty)
    }

    func testReturnedWindowRetriesOnceUnlessAFreshFrameArrives() {
        let start = Date()
        var retry = WindowReturnRetry()
        // Returning while cached availability is still true still arms the retry.
        XCTAssertFalse(retry.observe(.hidden, previous: .visible, lastFrameAt: start, now: start))
        XCTAssertFalse(retry.observe(.visible, previous: .hidden, lastFrameAt: start, now: start.addingTimeInterval(2)))
        XCTAssertFalse(retry.observe(.visible, previous: .visible, lastFrameAt: start, now: start.addingTimeInterval(4)))
        XCTAssertTrue(retry.observe(.visible, previous: .visible, lastFrameAt: start, now: start.addingTimeInterval(5)))
        XCTAssertFalse(retry.observe(.visible, previous: .visible, lastFrameAt: start, now: start.addingTimeInterval(9)))
        // A frame after the return means capture resumed on its own.
        XCTAssertFalse(retry.observe(.visible, previous: .hidden, lastFrameAt: start, now: start.addingTimeInterval(10)))
        XCTAssertFalse(retry.observe(.visible, previous: .visible, lastFrameAt: start.addingTimeInterval(11), now: start.addingTimeInterval(11)))
        XCTAssertFalse(retry.observe(.visible, previous: .visible, lastFrameAt: start.addingTimeInterval(11), now: start.addingTimeInterval(20)))
        // Hiding again cancels a pending retry.
        XCTAssertFalse(retry.observe(.visible, previous: .hidden, lastFrameAt: start, now: start.addingTimeInterval(21)))
        XCTAssertFalse(retry.observe(.closed, previous: .visible, lastFrameAt: start, now: start.addingTimeInterval(22)))
        XCTAssertFalse(retry.observe(.closed, previous: .closed, lastFrameAt: start, now: start.addingTimeInterval(30)))
    }

    func testSavedWindowFromAnEndedProcessIsNotReopenedOrSubstituted() async throws {
        let suite = "Setbeam-window-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SessionModel(preferences: defaults)
        var saved = SourceSetup(kind: .macWindow, name: "Fixture · Session", deviceName: "Fixture")
        saved.window = MacWindowIdentity(windowID: UInt32.max, processID: Int32.max, processStart: 1)
        model.restore(saved)
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.state.monitoring)
        XCTAssertEqual(model.setup?.window, saved.window)
        XCTAssertEqual(model.windowPresence, .closed)
        XCTAssertEqual(model.recoveryTitle, "The selected window closed")
        XCTAssertNotNil(model.error)
        await model.shutdown()
    }
    func testInactiveCategoryListsSourcesWithoutCapturingHiddenPreviews() async {
        let candidate = window(1)
        var captured = 0
        let previews = WindowSourcePreviews(list: { [(candidate, nil)] }, capture: { _, _ in captured += 1; return self.image() })
        await previews.refresh(permitted: true, monitored: nil, captureVisible: false)
        XCTAssertEqual(previews.windows, [candidate])
        XCTAssertTrue(previews.loaded)
        XCTAssertTrue(previews.images.isEmpty)
        XCTAssertEqual(captured, 0)
        await previews.refresh(permitted: true, monitored: nil)
        XCTAssertEqual(captured, 1)
        XCTAssertNotNil(previews.images[candidate.identity])
    }

}

private actor CaptureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
