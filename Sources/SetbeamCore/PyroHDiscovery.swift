import Foundation
import Darwin
import SystemConfiguration
import CoreWLAN
import os

/// Only the current Wi-Fi interface's directly attached IPv4 router is a discovery target.
public struct PyroHNetwork: Codable, Hashable, Sendable {
    public let interface: String
    public let address: String
    public let router: String
    public let subnetMask: String?
    public let bssid: String?

    public init(interface: String, address: String, router: String, subnetMask: String? = nil, bssid: String? = nil) {
        self.interface = interface; self.address = address; self.router = router
        self.subnetMask = subnetMask; self.bssid = bssid?.lowercased()
    }

    /// The fixture must be supplied explicitly to discovery and playback. The system reader only returns Wi-Fi.
    public static let loopbackFixture = PyroHNetwork(interface: "lo0", address: "127.0.0.1", router: "127.0.0.1")

    public var isVerifiable: Bool {
        if self == Self.loopbackFixture { return true }
        guard !interface.isEmpty, let bssid, let subnetMask,
              Self.isLocalRouter(router, address: address, mask: subnetMask) else { return false }
        let octets = bssid.split(separator: ":", omittingEmptySubsequences: false)
        guard octets.count == 6, octets.allSatisfy({ $0.utf8.count == 2 && UInt8($0, radix: 16) != nil }) else { return false }
        return bssid != "00:00:00:00:00:00" && bssid != "02:00:00:00:00:00" && bssid != "ff:ff:ff:ff:ff:ff"
    }

    public static func connected() -> [PyroHNetwork] {
        guard let store = SCDynamicStoreCreate(nil, "Setbeam Pyro H discovery" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "^State:/Network/Service/[^/]+/IPv4$" as CFString) as? [String] else { return [] }
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let wifi = Set(interfaces.compactMap { item -> String? in
            guard SCNetworkInterfaceGetInterfaceType(item) as String? == kSCNetworkInterfaceTypeIEEE80211 as String else { return nil }
            return SCNetworkInterfaceGetBSDName(item) as String?
        })
        let active = NetworkAddress.available()
        var result = Set<PyroHNetwork>()
        for key in keys {
            guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let interface = value[kSCPropInterfaceName as String] as? String, wifi.contains(interface),
                  let router = value[kSCPropNetIPv4Router as String] as? String,
                  let addresses = value[kSCPropNetIPv4Addresses as String] as? [String],
                  let masks = value[kSCPropNetIPv4SubnetMasks as String] as? [String] else { continue }
            for (address, mask) in zip(addresses, masks) where active.contains(where: { $0.interface == interface && $0.address == address }) {
                guard isLocalRouter(router, address: address, mask: mask) else { continue }
                let bssid = CWWiFiClient.shared().interface(withName: interface)?.bssid()
                result.insert(.init(interface: interface, address: address, router: router, subnetMask: mask, bssid: bssid))
            }
        }
        return result.sorted { $0.interface < $1.interface }.prefix(4).map { $0 }
    }

    static func isLocalRouter(_ router: String, address: String, mask: String) -> Bool {
        func ipv4(_ string: String) -> UInt32? {
            var value = in_addr()
            guard string.withCString({ inet_pton(AF_INET, $0, &value) }) == 1 else { return nil }
            return UInt32(bigEndian: value.s_addr)
        }
        guard let router = ipv4(router), let address = ipv4(address), let mask = ipv4(mask),
              (8...30).contains(mask.nonzeroBitCount), (~mask &+ 1) & ~mask == 0 else { return false }
        func privateAddress(_ value: UInt32) -> Bool {
            value >> 24 == 10 || value >> 20 == 0xac1 || value >> 16 == 0xc0a8
        }
        let network = address & mask, broadcast = network | ~mask
        return privateAddress(router) && privateAddress(address) && router != address && router & mask == network
            && router != network && router != broadcast && address != network && address != broadcast
    }
}

/// The network and endpoint that answered discovery on the scoped socket.
public struct PyroHRoute: Codable, Hashable, Sendable {
    public let network: PyroHNetwork
    public let port: UInt16

    public var address: String { "rtsp://\(network.router):\(port)/live" }

    public static let rediscover = "Join your Pyro H's Wi-Fi and select its stream again in Choose a source → Wireless."
    public static let verifyWiFi = "Rejoin the original Pyro H Wi-Fi. If Setbeam still can't verify it, allow Location access in Privacy & Security → Location Services."
    public static let changedWiFi = "Rejoin the original Pyro H Wi-Fi to reconnect. To use a different route, switch inputs and choose the Pyro H again."

    func validate() throws {
        guard port != 0, network.isVerifiable else { throw SetbeamError.unavailable(Self.rediscover) }
    }

    func requireCurrent(_ networks: [PyroHNetwork]) throws {
        try validate()
        guard networks.contains(network) else {
            let message = networks.contains(where: \.isVerifiable) ? Self.changedWiFi : Self.verifyWiFi
            throw SetbeamError.unavailable(message)
        }
    }
}

/// A compatible /live description is a connection candidate, not proof of the device's model.
public struct PyroHSource: Identifiable, Equatable, Sendable {
    public let network: PyroHNetwork
    public let port: UInt16
    public let hasAudio: Bool
    public var id: PyroHRoute { route }
    public var route: PyroHRoute { .init(network: network, port: port) }
    public var address: String { route.address }
    public var setup: SourceSetup {
        var value = SourceSetup(kind: .network, name: "Hollyland Pyro H", deviceName: "Hollyland Pyro H", networkAddress: address)
        value.networkProfile = .pyroH
        value.pyroHRoute = route
        return value
    }
}

public enum PyroHDiscovery {
    public static let ports: [UInt16] = [5554, 554, 8554]

    /// No SETUP/PLAY, subnet scans, Wi-Fi changes, processes, or streaming connection.
    public static func scan(networks: [PyroHNetwork], ports: [UInt16] = ports, timeout: TimeInterval = 1.2,
                            currentNetworks: @escaping @Sendable () -> [PyroHNetwork] = { PyroHNetwork.connected() }) async -> [PyroHSource] {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            // POSIX polling is bounded and stays off the main actor. Cancellation is checked at most 50 ms apart.
            await Task.detached(priority: .utility) {
                var result: [PyroHSource] = []
                var seen = Set<UInt16>()
                let targets = ports.filter { $0 > 0 && seen.insert($0).inserted }.prefix(3)
                for network in Array(Set(networks)).sorted(by: { $0.interface < $1.interface }).prefix(4) {
                    for port in targets {
                        guard !cancelled.withLock({ $0 }) else { return [] }
                        let route = PyroHRoute(network: network, port: port)
                        guard (try? route.requireCurrent(currentNetworks())) != nil else { break }
                        if let audio = probe(route: route, timeout: timeout.isFinite ? min(2, max(0.01, timeout)) : 1.2,
                                             cancelled: { cancelled.withLock { $0 } }),
                           (try? route.requireCurrent(currentNetworks())) != nil {
                            result.append(PyroHSource(network: network, port: port, hasAudio: audio)); break
                        }
                    }
                }
                return cancelled.withLock({ $0 }) ? [] : result
            }.value
        } onCancel: { cancelled.withLock { $0 = true } }
    }

    private static func probe(route: PyroHRoute, timeout: TimeInterval, cancelled: () -> Bool) -> Bool? {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        guard let fd = PyroHSocket.connect(route, deadline: deadline, cancelled: cancelled) else { return nil }
        defer { close(fd) }
        let request = Data("DESCRIBE \(route.address) RTSP/1.0\r\nCSeq: 1\r\nAccept: application/sdp\r\nUser-Agent: Setbeam\r\n\r\n".utf8)
        var sent = 0
        while sent < request.count {
            guard PyroHSocket.wait(fd, events: Int16(POLLOUT), deadline: deadline, cancelled: cancelled) else { return nil }
            let count = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: sent), request.count - sent, 0) }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { return nil }; sent += count
        }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while PyroHSocket.wait(fd, events: Int16(POLLIN), deadline: deadline, cancelled: cancelled) {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { return nil }
            bytes.append(contentsOf: buffer.prefix(count))
            switch PyroHDescription.parse(bytes) {
            case .incomplete: continue
            case .rejected: return nil
            case .video(let audio): return audio
            }
        }
        return nil
    }

}

enum PyroHDescription: Equatable {
    case incomplete, rejected, video(hasAudio: Bool)

    static func parse(_ bytes: Data) -> PyroHDescription {
        guard bytes.count <= 40_960 else { return .rejected }
        guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else { return bytes.count > 8192 ? .rejected : .incomplete }
        guard boundary.upperBound <= 8192, let header = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { return .rejected }
        let lines = header.components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ") ?? []
        guard status.count >= 2, status[0] == "RTSP/1.0", status[1] == "200", lines.count <= 64 else { return .rejected }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .rejected }
            let name = line[..<colon].lowercased(), value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard fields[name] == nil else { return .rejected }; fields[name] = value
        }
        guard fields["cseq"] == "1", fields["content-type"]?.lowercased().split(separator: ";").first == "application/sdp",
              let length = fields["content-length"].flatMap(Int.init), (1...32_768).contains(length) else { return .rejected }
        guard bytes.count >= boundary.upperBound + length else { return .incomplete }
        guard let sdp = String(data: bytes[boundary.upperBound..<boundary.upperBound + length], encoding: .utf8) else { return .rejected }
        let descriptions = sdp.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard descriptions.first == "v=0", descriptions.count <= 512, descriptions.allSatisfy({ $0.utf8.count <= 2048 }) else { return .rejected }
        var media = "", payloads = Set<String>(), video = false, audio = false
        for line in descriptions {
            if line.hasPrefix("m=") {
                let parts = line.dropFirst(2).split(separator: " ").map(String.init)
                media = parts.first ?? ""; payloads = Set(parts.dropFirst(3))
            } else if line.hasPrefix("a=rtpmap:") {
                let parts = line.dropFirst(9).split(separator: " ")
                guard parts.count == 2, payloads.contains(String(parts[0])) else { continue }
                if media == "video", parts[1].uppercased() == "H264/90000" { video = true }
                if media == "audio", parts[1].uppercased().hasPrefix("MPEG4-GENERIC/") { audio = true }
            }
        }
        return video ? .video(hasAudio: audio) : .rejected
    }
}
