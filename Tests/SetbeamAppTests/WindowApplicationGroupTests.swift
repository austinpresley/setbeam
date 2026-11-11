import XCTest
import SetbeamCore
@testable import SetbeamApp

final class WindowApplicationGroupTests: XCTestCase {
    private func window(_ id: UInt32, app: String, bundle: String?, title: String, pid: Int32 = 9) -> MacWindow {
        MacWindow(identity: MacWindowIdentity(windowID: id, processID: pid, processStart: 1),
                  applicationName: app, bundleIdentifier: bundle, title: title, width: 800, height: 600)
    }

    func testApplicationsStayTogetherAndWindowIdentitiesSurviveGrouping() {
        let windows = [
            window(4, app: "Safari", bundle: "com.apple.Safari", title: "B"),
            window(2, app: "Capture One", bundle: "com.captureone", title: "Session 10"),
            window(3, app: "Safari", bundle: "com.apple.Safari", title: "A", pid: 10),
            window(1, app: "Capture One", bundle: "com.captureone", title: "Session 9")
        ]
        let groups = WindowApplicationGroup.grouping(windows)
        XCTAssertEqual(groups.map(\.name), ["Capture One", "Safari"])
        XCTAssertEqual(groups.map { $0.windows.map(\.identity.windowID) }, [[1, 2], [3, 4]])
        XCTAssertEqual(Set(groups.flatMap(\.windows).map(\.identity)), Set(windows.map(\.identity)))
        XCTAssertEqual(WindowApplicationGroup.grouping(windows.reversed()).map(\.id), groups.map(\.id))
    }

    func testMissingBundleUsesApplicationNameAndDifferentBundlesStaySeparate() {
        let groups = WindowApplicationGroup.grouping([
            window(1, app: "Editor", bundle: nil, title: "A"),
            window(2, app: "Editor", bundle: nil, title: "B", pid: 10),
            window(3, app: "Editor", bundle: "other.editor", title: "C")
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map { $0.windows.count }.sorted(), [1, 2])
        XCTAssertTrue(WindowApplicationGroup.grouping([]).isEmpty)
    }
    func testSearchMatchesApplicationsAndWindowTitlesWithoutChangingIdentity() {
        let windows = [window(1, app: "Capture One", bundle: "capture", title: "Studio session"),
                       window(2, app: "Capture One", bundle: "capture", title: "Client proofs")]
        let group = WindowApplicationGroup.grouping(windows)[0]
        XCTAssertEqual(group.matching(" capture ONE ").map(\.id), group.windows.map(\.id))
        XCTAssertEqual(group.matching("PROOFS").map(\.identity.windowID), [2])
        XCTAssertTrue(group.matching("Safari").isEmpty)
        XCTAssertEqual(group.matching(" ").count, 2)
    }

    func testDuplicateAndUntitledWindowNumbersDoNotDependOnTheSearchResults() {
        let group = WindowApplicationGroup.grouping([
            window(1, app: "Editor", bundle: "editor", title: ""),
            window(2, app: "Editor", bundle: "editor", title: "Untitled"),
            window(3, app: "Editor", bundle: "editor", title: "Proof"),
            window(4, app: "Editor", bundle: "editor", title: "Proof"),
            window(5, app: "Editor", bundle: "editor", title: "Unique")
        ])[0]
        XCTAssertEqual(group.windows.map { group.detail(for: $0) }, ["Window 1", "Window 2", "Window 3", "Window 4", nil])
        let proofs = group.matching("Proof")
        XCTAssertEqual(proofs.map { group.detail(for: $0) }, ["Window 3", "Window 4"])
    }

}
