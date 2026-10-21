import Foundation
import AppKit
import CoreImage
import Security
import SetbeamCore

enum AppAssets {
    static var packaged: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    static var root: URL {
        packaged ? Bundle.main.resourceURL! : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/SetbeamApp/Resources")
    }
    static var runtimePaths: RuntimePaths {
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return RuntimePaths(tools: packaged ? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers") : project.appendingPathComponent("Vendor/bin"), fixtures: packaged ? root.appendingPathComponent("Fixtures") : project.appendingPathComponent("Fixtures"))
    }
    static func resource(_ name: String) -> URL { root.appendingPathComponent(name) }
    static var icon: NSImage? { NSImage(contentsOf: resource("Setbeam.icns")) }
    static func text(_ name: String) -> String { (try? String(contentsOf: resource(name), encoding: .utf8)) ?? "" }
    static var viewerAssets: [String: Data] {
        Dictionary(uniqueKeysWithValues: ["viewer.html", "viewer.css", "viewer.js", "reader.js"].compactMap { name in
            (try? Data(contentsOf: resource(name))).map { (name, $0) }
        })
    }
}

enum QRCode {
    static func image(_ payload: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
    static func wifi(ssid: String, password: String) -> String {
        func escape(_ text: String) -> String {
            text.reduce(into: "") { result, character in
                if "\\;,:\"".contains(character) { result.append("\\") }; result.append(character)
            }
        }
        return password.isEmpty ? "WIFI:T:nopass;S:\(escape(ssid));;" : "WIFI:T:WPA;S:\(escape(ssid));P:\(escape(password));;"
    }
}

enum SecureSettings {
    private static let service = "app.setbeam.credentials"
    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func store(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var add = query; add.merge(attributes) { _, new in new }; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw SetbeamError.runtime("Could not save the credential in Keychain.") }
        } else if update != errSecSuccess { throw SetbeamError.runtime("Could not update the credential in Keychain.") }
    }
    static func remove(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}
