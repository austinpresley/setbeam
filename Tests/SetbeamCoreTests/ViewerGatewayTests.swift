import XCTest
@testable import SetbeamCore

final class ViewerGatewayTests: XCTestCase {
    func testViewerRoutesAndReadOnlyCredentialBoundary() async throws {
        let host = ViewerGateway(assets: ["viewer.html": Data("sample viewer".utf8)])
        let token = UUID().uuidString
        host.update(ViewerSession(token: token, title: "Studio", sample: true, state: .live,
            playback: PlaybackDescriptor(origin: "http://127.0.0.1:8889", path: "live", user: "guest", password: "read-only-test-value")))
        let port = try await host.start(address: "127.0.0.1")
        defer { host.stop() }
        let origin = "http://127.0.0.1:\(port)"
        func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, Int) {
            var value = URLRequest(url: URL(string: origin + path)!)
            value.httpMethod = method; value.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: value)
            return (data, (response as! HTTPURLResponse).statusCode)
        }
        for path in ["/", "/config.json", "/v3/config/global/get", "/s/wrong/", "/s/\(token)/LICENSE", "/s/\(token)/%2e%2e/config.json"] {
            let (_, status) = try await request(path)
            XCTAssertEqual(status, 404, path)
        }
        let prefix = "/s/\(token)/"
        let (html, status) = try await request(prefix)
        XCTAssertEqual(status, 200); XCTAssertEqual(String(decoding: html, as: UTF8.self), "sample viewer")
        let (config, _) = try await request(prefix + "config.json")
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: config) as? [String: Any])
        XCTAssertEqual(values["user"] as? String, "guest")
        XCTAssertEqual(values["pass"] as? String, "read-only-test-value")
        XCTAssertEqual(values.count, 5)
        let (_, rejected) = try await request(prefix + "state.json", method: "POST")
        XCTAssertEqual(rejected, 405)
        XCTAssertTrue(host.viewers.isEmpty)
        let body = Data(#"{"id":"browser-test-01","mobile":true,"playing":true}"#.utf8)
        _ = try await request(prefix + "heartbeat", method: "POST", body: body)
        XCTAssertEqual(host.viewers.count, 1); XCTAssertEqual(host.viewers.first?.playing, true)
        host.update(ViewerSession(token: "rotated-session", title: "Studio", sample: true, state: .stopped,
            playback: PlaybackDescriptor(origin: "http://127.0.0.1:8889", path: "live", user: "guest", password: "rotated")))
        let (_, expired) = try await request(prefix + "config.json")
        XCTAssertEqual(expired, 404)
    }
}
