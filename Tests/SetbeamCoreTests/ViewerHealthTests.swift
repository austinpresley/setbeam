import XCTest
@testable import SetbeamCore

final class ViewerHealthTests: XCTestCase {
    private func session(state: AudienceState = .live, revision: Int = 1) -> ViewerSession {
        ViewerSession(token: "viewer-health-test", title: "Sample", sample: true, state: state,
            playback: PlaybackDescriptor(origin: "http://127.0.0.1:8889", path: "live", user: "guest", password: "synthetic"), revision: revision)
    }

    func testHealthRequiresFreshCurrentPlaybackAndHoldOverridesViewerMeasurements() {
        let live = session()
        XCTAssertEqual(ViewerHealth.observed(.good, playing: true, revision: 1, session: live, age: 2), .good)
        XCTAssertEqual(ViewerHealth.observed(.good, playing: true, revision: 1, session: live, age: 9), .reconnecting)
        XCTAssertEqual(ViewerHealth.observed(.good, playing: false, revision: 1, session: live, age: 2), .reconnecting)
        XCTAssertEqual(ViewerHealth.observed(.good, playing: true, revision: 0, session: live, age: 2), .connecting)
        XCTAssertEqual(ViewerHealth.observed(.struggling, playing: true, revision: 1, session: session(state: .holding), age: 2), .holding)
        for neutral in [ViewerHealth.background, .paused, .ready] {
            XCTAssertEqual(ViewerHealth.observed(neutral, playing: false, revision: 1, session: live, age: 2), neutral)
        }
    }

    func testNamesAndNumbersStayDistinctAndAreNotExposedToGuests() async throws {
        let host = ViewerGateway(assets: [:])
        host.update(session())
        let port = try await host.start(address: "127.0.0.1")
        defer { host.stop() }
        let root = URL(string: "http://127.0.0.1:\(port)/s/viewer-health-test/")!
        func beat(_ id: String, name: String? = nil, mobile: Bool = true, health: String = "good") async throws {
            var value: [String: Any] = ["id": id, "mobile": mobile, "playing": true, "revision": 1, "health": health]
            value["name"] = name
            var request = URLRequest(url: root.appendingPathComponent("heartbeat"))
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: value)
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }
        try await beat("viewer-zzz")
        try await beat("viewer-aaa")
        XCTAssertEqual(host.viewers.map(\.number), [1, 2])
        XCTAssertEqual(Set(host.viewers.map(\.displayName)).count, 2)
        try await beat("viewer-zzz", name: "  Sam\n\u{202e} iPad  ")
        XCTAssertEqual(host.viewers.first?.number, 1)
        XCTAssertEqual(host.viewers.first?.displayName, "Sam iPad")
        XCTAssertEqual(host.viewers.first?.health, .good)
        try await beat("viewer-aaa", name: String(repeating: "x", count: 90), health: "invented")
        XCTAssertEqual(host.viewers.last?.name?.count, 40)
        XCTAssertEqual(host.viewers.last?.health, .playing)
        for path in ["state.json", "config.json", "viewers"] {
            let (data, response) = try await URLSession.shared.data(from: root.appendingPathComponent(path))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Sam iPad"))
            if path == "viewers" { XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404) }
        }
        host.update(session(state: .holding))
        XCTAssertEqual(host.viewers.map(\.health), [.holding, .holding])
        host.stop()
        XCTAssertTrue(host.viewers.isEmpty)
    }
}
