import Foundation
import Darwin
import SystemConfiguration

public struct NetworkAddress: Hashable, Identifiable, Sendable {
    public let interface: String
    public let address: String
    public var id: String { "\(interface):\(address)" }
    public var label: String { interface == "lo0" ? "This Mac only · \(address)" : "\(Self.details(interface).0) · \(address)" }
    public init(interface: String, address: String) { self.interface = interface; self.address = address }

    public static func available() -> [NetworkAddress] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var result: [NetworkAddress] = []
        var cursor = interfaces
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard !["utun", "awdl", "llw", "bridge", "vmenet"].contains(where: { name.hasPrefix($0) }) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254.") { result.append(NetworkAddress(interface: name, address: ip)) }
            }
        }
        return result.sorted { a, b in
            let aWireless = Self.details(a.interface).1, bWireless = Self.details(b.interface).1
            if aWireless != bWireless { return !aWireless }
            return a.interface < b.interface
        }
    }

    private static func details(_ bsd: String) -> (String, Bool) {
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        for value in interfaces where (SCNetworkInterfaceGetBSDName(value) as String?) == bsd {
            return (SCNetworkInterfaceGetLocalizedDisplayName(value) as String? ?? bsd,
                    (SCNetworkInterfaceGetInterfaceType(value) as String?) == (kSCNetworkInterfaceTypeIEEE80211 as String))
        }
        return (bsd, false)
    }

    public static func freeTCPPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SetbeamError.unavailable("Could not reserve a local media port.") }
        defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw SetbeamError.unavailable("Could not reserve a local media port.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard read == 0 else { throw SetbeamError.unavailable("Could not read a local media port.") }
        return UInt16(bigEndian: address.sin_port)
    }
}
