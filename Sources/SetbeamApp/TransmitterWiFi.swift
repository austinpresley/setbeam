import CoreLocation
import CoreWLAN
import Foundation
import SetbeamCore

struct TransmitterWiFiIdentity: Equatable {
    let ssid: String
    private let uid: UInt32

    init?(_ setup: SourceSetup?) {
        guard let setup, setup.kind == .accsoon, let uid = setup.wirelessUID,
              uid != 0, !setup.sourceWiFi.isEmpty else { return nil }
        self.uid = uid
        ssid = setup.sourceWiFi
    }

    var preferenceKey: String { "transmitterWiFiRejoin-\(uid)-\(ssid)" }
    var credentialAccount: String { "source-wifi-\(uid)-\(ssid)" }
}

enum TransmitterRejoinNetwork: String {
    case open, secured
}

enum TransmitterWiFiResult: Equatable {
    case joined, notFound, needsLocation, wifiOff, noInterface, cancelled, failed(String)

    var logValue: String {
        switch self {
        case .joined: return "joined"
        case .notFound: return "not found"
        case .needsLocation: return "needs location access"
        case .wifiOff: return "Wi-Fi off"
        case .noInterface: return "no Wi-Fi interface"
        case .cancelled: return "cancelled"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
    /// Operator guidance; nil when the attempt joined or simply did not find the network yet.
    var message: String? {
        switch self {
        case .joined, .notFound, .cancelled: return nil
        case .needsLocation: return "Allow Location access for Setbeam in Privacy & Security. macOS shows Wi-Fi names only to apps with that access."
        case .wifiOff: return "Turn on Wi-Fi so Setbeam can rejoin the transmitter."
        case .noInterface: return "This Mac has no Wi-Fi interface for the transmitter."
        case .failed: return "Setbeam could not join the transmitter's Wi-Fi. Check the saved password."
        }
    }
}

/// Revoked when the operator opts out, changes source, or the session comes to depend on Wi-Fi.
final class RejoinPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    private var associating = false
    var isAllowed: Bool { lock.withLock { allowed } }

    /// Reports whether CoreWLAN association has already begun and cannot be cancelled.
    @discardableResult func revoke() -> Bool {
        lock.withLock {
            allowed = false
            return associating
        }
    }

    func beginAssociation() -> Bool {
        lock.withLock {
            guard allowed, !associating else { return false }
            associating = true
            return true
        }
    }

    func finishAssociation() { lock.withLock { associating = false } }
}

/// Joins one named network for the opt-in transmitter rejoin. Setbeam associates only with a
/// network whose name macOS has revealed, never with an unidentified scan result.
@MainActor final class TransmitterWiFi {
    private let location = CLLocationManager()

    var interfaceName: String? { CWWiFiClient.shared().interface()?.interfaceName }
    var connectedName: String? { CWWiFiClient.shared().interface()?.ssid() }
    var locationAllowed: Bool { location.authorizationStatus == .authorizedAlways }
    var locationDenied: Bool { [.denied, .restricted].contains(location.authorizationStatus) }
    func requestLocation() { if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() } }

    nonisolated static func join(ssid: String, password: String?, permit: RejoinPermit) async -> TransmitterWiFiResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: joinNow(ssid: ssid, password: password, permit: permit)) }
        }
    }

    nonisolated private static func joinNow(ssid: String, password: String?, permit: RejoinPermit) -> TransmitterWiFiResult {
        guard permit.isAllowed else { return .cancelled }
        guard let interface = CWWiFiClient.shared().interface() else { return .noInterface }
        guard interface.powerOn() else { return .wifiOff }
        do {
            let found = try interface.scanForNetworks(withName: ssid)
            guard !found.isEmpty else { return .notFound }
            guard let network = found.first(where: { $0.ssid == ssid }) else { return .needsLocation }
            // Scanning takes seconds; the operator or session may have withdrawn consent meanwhile.
            guard permit.beginAssociation() else { return .cancelled }
            defer { permit.finishAssociation() }
            try interface.associate(to: network, password: password?.isEmpty == false ? password : nil)
            return .joined
        } catch { return .failed(error.localizedDescription) }
    }
}
