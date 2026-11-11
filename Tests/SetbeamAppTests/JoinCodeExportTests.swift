import XCTest
import SwiftUI
import PDFKit
import Vision
@testable import SetbeamApp

final class JoinCodeExportTests: XCTestCase {
    @MainActor func testPDFContainsBothExactCodesAndExpiryLabels() throws {
        let ssid = "Studio;WiFi", password = "fixture:password", url = URL(string: "http://127.0.0.1:9999/s/" + String(repeating: "a", count: 64) + "/")!
        let view = JoinCodeDocumentView(title: "Fixture feed", ssid: ssid, password: password, url: url, date: Date(timeIntervalSince1970: 1000), approval: true)
        let data = view.dataWithPDF(inside: view.bounds)
        let document = try XCTUnwrap(PDFDocument(data: data)), page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(document.pageCount, 1)
        let image = page.thumbnail(of: NSSize(width: 3000, height: 2333), for: .mediaBox)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: cg).perform([request])
        XCTAssertEqual(Set(request.results?.compactMap(\.payloadStringValue) ?? []), [QRCode.wifi(ssid: ssid, password: password), url.absoluteString])
        let text = page.string ?? ""
        XCTAssertTrue(text.contains("expire")); XCTAssertTrue(text.contains("Wi-Fi password")); XCTAssertTrue(text.contains("approval"))
        if let output = ProcessInfo.processInfo.environment["SETBEAM_QA_OUTPUT"] {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("qa-join-codes.pdf"))
        }
    }
    @MainActor func testMissingProtectedPasswordNeverBecomesAnOpenNetworkCode() throws {
        let suite = "app.setbeam.tests.missing-wifi.\(UUID().uuidString)", ssid = UUID().uuidString.prefix(20).description
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(ssid, forKey: "wifiSSID"); preferences.set(true, forKey: "viewingWiFiProtected-\(ssid)")
        let model = SessionModel(preferences: preferences); model.loadViewingWiFi()
        XCTAssertFalse(model.viewingWiFiPasswordAvailable)
        XCTAssertEqual(model.wifiPassword, "")
        XCTAssertTrue(ViewingWiFiBrowser.passwordFormat("12345678").contains("not been tested"))
        XCTAssertTrue(ViewingWiFiBrowser.passwordFormat("short").contains("Check the password"))
    }
}
