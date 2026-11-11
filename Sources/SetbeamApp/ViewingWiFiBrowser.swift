import CoreLocation
import CoreWLAN
import Foundation

struct ViewingWiFiNetwork: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let current: Bool
    let supportsJoinCode: Bool
    let open: Bool
}

/// This browser has no association capability. Cached names are safe to read during a feed.
@MainActor final class ViewingWiFiBrowser: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var networks: [ViewingWiFiNetwork] = []
    @Published private(set) var scanning = false
    @Published private(set) var message = ""
    private let location = CLLocationManager()
    override init() { super.init(); location.delegate = self }
    var allowed: Bool { location.authorizationStatus == .authorizedAlways }
    func allowNames() {
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        else if !allowed { message = "Allow Location for Setbeam in System Settings to see network names. You can also type a name." }
        else { loadCached() }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.loadCached() }
    }
    func loadCached() {
        guard allowed else { message = "macOS needs Location access to show Wi-Fi names. Manual entry still works."; return }
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { message = "Turn on Wi-Fi to see nearby names, or enter one manually."; return }
        networks = Self.entries(interface.cachedScanResults() ?? [], current: interface.ssid())
        message = networks.isEmpty ? "No cached networks. Refresh the list when the feed is idle, or type a name." : "Cached Wi-Fi list. Selecting a name does not join it."
    }
    func scan() {
        guard !scanning, allowed else { allowNames(); return }
        scanning = true; message = "Looking for Wi-Fi networks…"
        Task {
            let result: Result<[ViewingWiFiNetwork], Error> = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { throw CocoaError(.featureUnsupported) }
                        continuation.resume(returning: .success(Self.entries(try interface.scanForNetworks(withSSID: nil), current: interface.ssid())))
                    } catch { continuation.resume(returning: .failure(error)) }
                }
            }
            scanning = false
            switch result {
            case .success(let values): networks = values; message = values.isEmpty ? "No named networks found. Enter a name manually." : "Select a name. This Mac stays on its current network."
            case .failure: message = "The Wi-Fi list could not refresh. Use a cached name or enter one manually."
            }
        }
    }
    nonisolated private static func entries(_ found: Set<CWNetwork>, current: String?) -> [ViewingWiFiNetwork] {
        var values: [String: ViewingWiFiNetwork] = [:]
        for network in found {
            guard let name = network.ssid, !name.isEmpty, name.utf8.count <= 32 else { continue }
            let open = network.supportsSecurity(.none)
            let supported = open || network.supportsSecurity(.wpaPersonal) || network.supportsSecurity(.wpa2Personal) || network.supportsSecurity(.wpa3Personal) || network.supportsSecurity(.wpa3Transition)
            let value = ViewingWiFiNetwork(name: name, current: name == current, supportsJoinCode: supported, open: open)
            // If two APs have the same name but incompatible security, require manual setup.
            if let previous = values[name], previous.open != value.open || previous.supportsJoinCode != value.supportsJoinCode {
                values[name] = .init(name: name, current: name == current, supportsJoinCode: false, open: false)
            } else if values[name] == nil { values[name] = value }
        }
        return values.values.sorted { $0.current != $1.current ? $0.current : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func passwordFormat(_ password: String) -> String {
        if password.isEmpty { return "Open network. No password is included in its join code." }
        let ascii = password.unicodeScalars.allSatisfy { (32...126).contains($0.value) }
        let hex = password.utf8.count == 64 && password.allSatisfy { $0.isASCII && $0.isHexDigit }
        return hex || ascii && (8...63).contains(password.utf8.count)
            ? "Password format looks valid. It has not been tested against the network."
            : "Personal Wi-Fi usually needs 8 to 63 ASCII characters or 64 hexadecimal digits. Check the password."
    }
}
