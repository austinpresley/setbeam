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

/// Status enriches the identity for one observed host. A newer beacon owns the
/// current media flags, and a discovery handoff invalidates all pending queries.
struct AccsoonDiscoveryRecords {
    struct Query: Equatable, Sendable {
        let token = UUID()
        let device: AccsoonDevice
    }

    private(set) var devices: [UInt32: AccsoonDevice] = [:]
    private var queries: [UInt32: Query] = [:]

    mutating func observe(_ announcement: AccsoonDevice) -> Query? {
        var device = announcement
        if let previous = devices[device.id], previous.host == device.host,
           device.lastSeen.timeIntervalSince(previous.lastSeen) < 8 {
            device.productID = previous.productID; device.firmware = previous.firmware; device.hardware = previous.hardware
        } else {
            queries.removeValue(forKey: device.id)
        }
        devices[device.id] = device
        guard device.productID == nil, queries[device.id] == nil, queries.count < 8 else { return nil }
        let query = Query(device: device)
        queries[device.id] = query
        return query
    }

    mutating func complete(_ query: Query, info: AccsoonStatus.Info?, now: Date = Date()) -> Bool {
        let original = query.device
        guard queries[original.id] == query else { return false }
        queries.removeValue(forKey: original.id)
        guard let info, var device = devices[original.id], device.host == original.host,
              now.timeIntervalSince(device.lastSeen) < 8 else { return false }
        device.productID = info.product; device.firmware = info.firmware; device.hardware = info.hardware
        if device.lastSeen == original.lastSeen {
            device.videoAvailable = info.video; device.audioAvailable = info.audio
        }
        devices[device.id] = device
        return true
    }

    func contains(_ query: Query) -> Bool { queries[query.device.id] == query }

    mutating func invalidateQueries() { queries.removeAll() }
}

public final class AccsoonDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.setbeam.accsoon-discovery")
    private let queueKey = DispatchSpecificKey<Void>()
    private var socketFD: Int32 = -1
    private var generation = 0
    private var records = AccsoonDiscoveryRecords()
    private var change: (@Sendable ([AccsoonDevice]) -> Void)?
    public var onChange: (@Sendable ([AccsoonDevice]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return change }
        set { lock.lock(); change = newValue; lock.unlock() }
    }
    public init() { queue.setSpecific(key: queueKey, value: ()) }
    public var devices: [AccsoonDevice] {
        lock.lock(); defer { lock.unlock() }
        return records.devices.values.filter { Date().timeIntervalSince($0.lastSeen) < 8 }.sorted { $0.wifiName < $1.wifiName }
    }
    public func device(_ id: UInt32) -> AccsoonDevice? { devices.first { $0.id == id } }
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard socketFD < 0 else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SetbeamError.unavailable("Wireless discovery could not start.") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(28001).bigEndian
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { close(fd); throw SetbeamError.unavailable("Close Accsoon SEE to let Setbeam connect directly to the transmitter.") }
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        socketFD = fd; generation += 1; records.invalidateQueries(); let current = generation
        queue.async { [weak self] in
            defer { close(fd) }
            var buffer = [UInt8](repeating: 0, count: 65_535)
            while let self, self.running(fd, generation: current) {
                var peer = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &peer) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) } }
                guard count > 0 else { continue }
                var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &peer.sin_addr, &host, socklen_t(host.count)) != nil else { continue }
                self.observe(Data(buffer.prefix(count)), host: String(cString: host), socketGeneration: current)
            }
        }
    }
    private func running(_ fd: Int32, generation: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return socketFD == fd && self.generation == generation }
    public func stop() {
        lock.lock()
        let active = socketFD >= 0
        socketFD = -1; generation += 1; records.invalidateQueries()
        lock.unlock()
        if active, DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
    }
    public func observe(_ data: Data, host: String) { observe(data, host: host, socketGeneration: nil) }

    private func observe(_ data: Data, host: String, socketGeneration: Int?) {
        guard let value = AccsoonAnnouncement.decode(data, host: host) else { return }
        lock.lock()
        if let socketGeneration, socketGeneration != generation { lock.unlock(); return }
        let query = records.observe(value)
        lock.unlock()
        onChange?(devices)
        if let query {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard self?.isPending(query) == true else { return }
                let selected = query.device
                let info = try? AccsoonStatus.read(host: selected.host, expectedUID: selected.id)
                guard let self else { return }
                self.lock.lock()
                let applied = self.records.complete(query, info: info)
                self.lock.unlock()
                if applied { self.onChange?(self.devices) }
            }
        }
    }
    private func isPending(_ query: AccsoonDiscoveryRecords.Query) -> Bool {
        lock.withLock { records.contains(query) }
    }

    deinit { stop() }
}

enum AccsoonStatus {
    struct Info { let product: Int; let firmware: Int; let hardware: Int; let video: Bool; let audio: Bool }
    static func read(host: String, expectedUID: UInt32) throws -> Info {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SetbeamError.unavailable("The transmitter did not respond.") }
        defer { close(fd) }
        var noSignal: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let unavailable = SetbeamError.unavailable("The transmitter did not respond.")
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw unavailable }
        func wait(_ event: Int32) throws {
            var descriptor = pollfd(fd: fd, events: Int16(event), revents: 0)
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw unavailable }
                let ready = poll(&descriptor, 1, Int32(ceil(remaining * 1_000)))
                if ready > 0 { return }
                if ready < 0, errno == EINTR { continue }
                throw unavailable
            }
        }

        var peer = sockaddr_in(); peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); peer.sin_family = sa_family_t(AF_INET); peer.sin_port = UInt16(28010).bigEndian
        guard inet_pton(AF_INET, host, &peer.sin_addr) == 1 else { throw SetbeamError.invalidSource("The transmitter address is invalid.") }
        let result = withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if result != 0 {
            guard errno == EINPROGRESS else { throw unavailable }
            try wait(POLLOUT)
            var problem: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &problem, &length) == 0, problem == 0 else { throw unavailable }
        }
        let client = UInt32.random(in: 1...UInt32.max)
        func sendCommand(_ command: UInt16, channel: UInt8 = 0, body: Data = Data()) throws {
            var payload = Data(); payload.rtmsAppend(UInt32(0x78776e93)); payload.rtmsAppend(client); payload.append(contentsOf: [0x40, channel]); payload.rtmsAppend(command); payload.append(body)
            var frame = Data(); frame.rtmsAppend(UInt32(0x78a3f889)); frame.rtmsAppend(UInt32(payload.count)); frame.append(payload)
            try frame.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    try wait(POLLOUT)
                    let count = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                    if count < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                    guard count > 0 else { throw unavailable }
                    sent += count
                }
            }
        }
        func exact(_ count: Int) throws -> Data {
            var result = Data(), buffer = [UInt8](repeating: 0, count: count)
            while result.count < count {
                try wait(POLLIN)
                let received = recv(fd, &buffer, count - result.count, 0)
                if received < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard received > 0 else { throw unavailable }
                result.append(contentsOf: buffer.prefix(received))
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
