import Foundation
import Darwin
import CommonCrypto
import zlib

public struct AccsoonDevice: Identifiable, Sendable, Equatable {
    public let id: UInt32
    public var host: String
    public var wifiName: String
    public var productID: Int?
    public var firmware: Int?
    public var hardware: Int?
    public var videoAvailable = false
    public var audioAvailable = false
    public var lastSeen: Date
    // The same physically identified Master 4K / firmware 3.30 unit has reported both values.
    public var recognized: Bool { productID == 21 || productID == 24 }
    public var name: String { recognized ? "Accsoon CineView Master 4K" : "Accsoon transmitter" }
    public var firmwareLabel: String? { firmware.map { "\($0 >> 8)." + String(format: "%02d", $0 & 255) } }
}

/// RTMS4 discovery is unsolicited. Parsing deliberately discards the credential-bearing custom profile.
/// Wire provenance and the one physically identified product are recorded in the research ledger.
public enum AccsoonAnnouncement {
    public static func decode(_ bytes: Data, host: String, now: Date = Date()) -> AccsoonDevice? {
        guard bytes.count >= 20, bytes.rtms32(0) == 0x78776e93, bytes[8] == 0x40, bytes[9] == 0, bytes.rtms16(10) == 10 else { return nil }
        var offset = 12, profile: [String: Any]?, ssid = ""
        while offset + 8 <= bytes.count {
            let type = bytes.rtms16(offset), count = Int(bytes.rtms16(offset + 2))
            guard count > 0, count % 16 == 0, offset + 8 + count <= bytes.count else { return nil }
            let cipher = bytes.subdata(in: offset + 8..<offset + 8 + count)
            let checksum = cipher.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(count)) }
            guard UInt32(checksum) == bytes.rtms32(offset + 4), let clear = decrypt(cipher),
                  let json = try? JSONSerialization.jsonObject(with: clear) as? [String: Any] else { return nil }
            if type == 0 { profile = json }
            if type == 1 { ssid = String((json["public_ssid"] as? String ?? "").prefix(64)) }
            offset += 8 + count
        }
        guard let profile, let identifier = profile["uid"] as? NSNumber,
              identifier.uint32Value == bytes.rtms32(4), identifier.uint32Value != 0 else { return nil }
        var device = AccsoonDevice(id: identifier.uint32Value, host: host, wifiName: ssid, lastSeen: now)
        let streams = (profile["stream"] as? [String: Any])?["stream_array"] as? [[String: Any]] ?? []
        device.videoAvailable = streams.contains { $0["stream_type"] as? Int == 0 && $0["valid"] as? Bool == true }
        device.audioAvailable = streams.contains { $0["stream_type"] as? Int == 1 && $0["valid"] as? Bool == true }
        return device
    }
    private static func decrypt(_ input: Data) -> Data? {
        // Static protocol obfuscation key from the official client, not a user's Wi-Fi/session credential.
        let key = Array("myN9QyGEwC2T7Ke2".utf8)
        var output = [UInt8](repeating: 0, count: input.count + 16), moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            input.withUnsafeBytes { inputBytes in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, kCCKeySizeAES128, nil, inputBytes.baseAddress, input.count,
                        &output, output.count, &moved)
            }
        }
        guard status == kCCSuccess else { return nil }
        var data = Data(output.prefix(moved)); while data.last == 0 { data.removeLast() }
        return data
    }
}

public final class AccsoonDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.setbeam.accsoon-discovery")
    private var socketFD: Int32 = -1
    private var generation = 0
    private var records: [UInt32: AccsoonDevice] = [:]
    private var querying = Set<UInt32>()
    public var onChange: (@Sendable ([AccsoonDevice]) -> Void)?
    public init() {}
    public var devices: [AccsoonDevice] {
        lock.lock(); defer { lock.unlock() }
        return records.values.filter { Date().timeIntervalSince($0.lastSeen) < 8 }.sorted { $0.wifiName < $1.wifiName }
    }
    public func device(_ id: UInt32) -> AccsoonDevice? { devices.first { $0.id == id } }
    public func start() throws {
        lock.lock(); let active = socketFD >= 0; lock.unlock(); guard !active else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SetbeamError.unavailable("Wireless discovery could not start.") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(28001).bigEndian
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { close(fd); throw SetbeamError.unavailable("Close Accsoon SEE to let Setbeam connect directly to the transmitter.") }
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        lock.lock(); socketFD = fd; generation += 1; let current = generation; lock.unlock()
        queue.async { [weak self] in
            defer { close(fd) }
            var buffer = [UInt8](repeating: 0, count: 65_535)
            while let self, self.running(fd, generation: current) {
                var peer = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &peer) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) } }
                guard count > 0 else { continue }
                var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &peer.sin_addr, &host, socklen_t(host.count)) != nil else { continue }
                self.observe(Data(buffer.prefix(count)), host: String(cString: host))
            }
        }
    }
    private func running(_ fd: Int32, generation: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return socketFD == fd && self.generation == generation }
    public func stop() {
        lock.lock(); let active = socketFD >= 0; socketFD = -1; generation += 1; lock.unlock()
        if active { queue.sync {} }
    }
    public func observe(_ data: Data, host: String) {
        guard var value = AccsoonAnnouncement.decode(data, host: host) else { return }
        lock.lock()
        if let old = records[value.id] { value.productID = old.productID; value.firmware = old.firmware; value.hardware = old.hardware }
        records[value.id] = value
        let query = value.productID == nil && !querying.contains(value.id)
        if query { querying.insert(value.id) }
        lock.unlock()
        onChange?(devices)
        if query {
            let selected = value
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let info = try? AccsoonStatus.read(host: selected.host, expectedUID: selected.id)
                guard let self else { return }
                self.lock.lock()
                if let info, var device = self.records[selected.id] {
                    device.productID = info.product; device.firmware = info.firmware; device.hardware = info.hardware
                    device.videoAvailable = info.video; device.audioAvailable = info.audio; self.records[selected.id] = device
                }
                self.querying.remove(selected.id); self.lock.unlock(); self.onChange?(self.devices)
            }
        }
    }
    deinit { stop() }
}

private enum AccsoonStatus {
    struct Info { let product: Int; let firmware: Int; let hardware: Int; let video: Bool; let audio: Bool }
    static func read(host: String, expectedUID: UInt32) throws -> Info {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SetbeamError.unavailable("The transmitter did not respond.") }
        defer { close(fd) }
        var noSignal: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        fcntl(fd, F_SETFL, O_NONBLOCK)
        var peer = sockaddr_in(); peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); peer.sin_family = sa_family_t(AF_INET); peer.sin_port = UInt16(28010).bigEndian
        guard inet_pton(AF_INET, host, &peer.sin_addr) == 1 else { throw SetbeamError.invalidSource("The transmitter address is invalid.") }
        let result = withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if result != 0 {
            guard errno == EINPROGRESS else { throw SetbeamError.unavailable("The transmitter did not respond.") }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&descriptor, 1, 1500) > 0 else { throw SetbeamError.unavailable("The transmitter did not respond.") }
            var problem: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &problem, &length)
            guard problem == 0 else { throw SetbeamError.unavailable("The transmitter did not respond.") }
        }
        fcntl(fd, F_SETFL, 0)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)); setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let client = UInt32.random(in: 1...UInt32.max)
        func sendCommand(_ command: UInt16, channel: UInt8 = 0, body: Data = Data()) throws {
            var payload = Data(); payload.rtmsAppend(UInt32(0x78776e93)); payload.rtmsAppend(client); payload.append(contentsOf: [0x40, channel]); payload.rtmsAppend(command); payload.append(body)
            var frame = Data(); frame.rtmsAppend(UInt32(0x78a3f889)); frame.rtmsAppend(UInt32(payload.count)); frame.append(payload)
            try frame.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let count = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                    guard count > 0 else { throw SetbeamError.unavailable("The transmitter did not respond.") }; sent += count
                }
            }
        }
        func exact(_ count: Int) throws -> Data {
            var result = Data(), buffer = [UInt8](repeating: 0, count: count)
            while result.count < count {
                let received = recv(fd, &buffer, count - result.count, 0)
                guard received > 0 else { throw SetbeamError.unavailable("The transmitter did not respond.") }; result.append(contentsOf: buffer.prefix(received))
            }
            return result
        }
        try sendCommand(11, body: Data([0])); defer { try? sendCommand(13) }
        try sendCommand(20, channel: 3)
        for _ in 0..<12 {
            let header = try exact(8), count = Int(header.rtms32(4))
            guard header.rtms32(0) == 0x78a3f889, count <= 65_536 else { throw SetbeamError.runtime("The transmitter status was unreadable.") }
            if count == 0 { continue }
            let payload = try exact(count)
            guard count >= 12, payload.rtms32(0) == 0x78776e93 else { continue }
            var json = Data(payload.dropFirst(12)); while json.last == 0 { json.removeLast() }
            guard payload.rtms16(10) == 0x8014,
                  let info = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let product = info["product_id"] as? Int, let firmware = info["firmware_version"] as? Int,
                  let hardware = info["hard_version"] as? Int,
                  let identifier = info["uid"] as? NSNumber, identifier.uint32Value == expectedUID else { continue }
            let media = info["media"] as? [String: Any] ?? [:]
            let videoStreams = (media["video"] as? [String: Any])?["stream"] as? [[String: Any]] ?? []
            let audioStreams = (media["audio"] as? [String: Any])?["stream"] as? [[String: Any]] ?? []
            return Info(product: product, firmware: firmware, hardware: hardware,
                video: videoStreams.contains { $0["valid"] as? Bool == true },
                audio: audioStreams.contains { $0["valid"] as? Bool == true })
        }
        throw SetbeamError.unavailable("The transmitter did not return its model information.")
    }
}

private extension Data {
    func rtms16(_ offset: Int) -> UInt16 { withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) } }
    func rtms32(_ offset: Int) -> UInt32 { withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
    mutating func rtmsAppend<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) } }
}
