import Darwin
import Foundation

/// Receives one discovered RTMS4 transmitter and forwards its media only to loopback.
/// The caller owns discovery, SDP, decoding, and the decision to share the received feed.
public final class AccsoonReceiver: @unchecked Sendable {
    private let lifecycle = NSLock()
    private let state = NSLock()
    private let announcements = DispatchQueue(label: "app.setbeam.accsoon.announcements")
    private var session: AccsoonReceiveSession?
    private var failure: String?
    private var previousStatistics: [String: Int] = ["running": 0, "tcpConnected": 0]
    private var announcement: (@Sendable (Data, String) -> Void)?

    public init() {}

    public var isRunning: Bool {
        state.lock(); defer { state.unlock() }
        return session?.isRunning ?? false
    }

    public var lastError: String? {
        state.lock(); defer { state.unlock() }
        return failure
    }

    /// Numeric, content-free diagnostics for the current or most recently closed session.
    public var statistics: [String: Int] {
        state.lock(); let current = session; let previous = previousStatistics; state.unlock()
        return current?.statistics ?? previous
    }

    public var onAnnouncement: (@Sendable (Data, String) -> Void)? {
        get { state.lock(); defer { state.unlock() }; return announcement }
        set { state.lock(); announcement = newValue; state.unlock() }
    }

    /// Discovery must release UDP 28001 before this method is called.
    /// `host` is the IPv4 address selected from the discovered device's local subnet.
    public func start(host: String, deviceUID: UInt32, videoPort: UInt16, audioPort: UInt16?) throws {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard stopSession() else { throw SetbeamError.unavailable("The previous Accsoon connection is still closing. Try again.") }
        guard deviceUID != 0, videoPort != 0, audioPort != 0, audioPort != videoPort else {
            throw SetbeamError.unavailable("The Accsoon connection has invalid device or local media settings.")
        }
        state.lock(); failure = nil; state.unlock()
        do {
            let next = try AccsoonReceiveSession(host: host, deviceUID: deviceUID, videoPort: videoPort, audioPort: audioPort,
                onFailure: { [weak self] message in
                    guard let self else { return }
                    self.state.lock(); self.failure = message; self.state.unlock()
                }, onAnnouncement: { [weak self] packet in
                    guard let self else { return }
                    self.state.lock(); let callback = self.announcement; self.state.unlock()
                    if let callback { self.announcements.async { callback(packet, host) } }
                })
            state.lock(); session = next; state.unlock()
            next.start()
        } catch {
            state.lock(); failure = error.localizedDescription; state.unlock()
            throw error
        }
    }

    /// Waits for the owned socket worker to finish before discovery can bind again.
    public func stop() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        _ = stopSession()
    }

    private func stopSession() -> Bool {
        state.lock(); let previous = session; state.unlock()
        guard previous?.stop() != false else { return false }
        let snapshot = previous?.statistics
        state.lock()
        if let snapshot { previousStatistics = snapshot }
        session = nil; state.unlock()
        return true
    }

    deinit { _ = session?.stop() }
}

private final class AccsoonReceiveSession: @unchecked Sendable {
    private let condition = NSCondition()
    private let counters = AccsoonReceiveCounters()
    private var cancelled = false
    private var finished = false
    private let udp: Int32
    private let tcp: Int32
    private let output: Int32
    private let peer: in_addr
    private let deviceUID: UInt32
    private let clientUID = UInt32.random(in: 1...UInt32.max)
    private var videoDestination: sockaddr_in
    private var audioDestination: sockaddr_in?
    private let onFailure: @Sendable (String) -> Void
    private let onAnnouncement: @Sendable (Data) -> Void
    private var assembler = AccsoonRTMSAssembler()
    private var videoRTP = AccsoonRTPPacketizer(payloadType: 96)
    private var audioRTP = AccsoonRTPPacketizer(payloadType: 97)
    private var tcpInput = Data()
    private var tcpOutput = Data()
    private var tcpOutputOffset = 0
    private var ackSequence: UInt16 = 1
    private var nakSequence: UInt16 = 1
    private var acknowledgedConnection = false

    init(host: String, deviceUID: UInt32, videoPort: UInt16, audioPort: UInt16?,
         onFailure: @escaping @Sendable (String) -> Void,
         onAnnouncement: @escaping @Sendable (Data) -> Void) throws {
        var peer = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &peer) }) == 1 else {
            throw SetbeamError.unavailable("The Accsoon transmitter has no usable local IPv4 address. Rejoin its Wi-Fi and try again.")
        }
        var udp: Int32 = -1, tcp: Int32 = -1, output: Int32 = -1
        do {
            udp = try Self.socket(SOCK_DGRAM)
            var receiveSize: Int32 = 4 * 1_024 * 1_024
            if setsockopt(udp, SOL_SOCKET, SO_RCVBUF, &receiveSize, socklen_t(MemoryLayout.size(ofValue: receiveSize))) != 0 {
                receiveSize = 1_024 * 1_024
                _ = setsockopt(udp, SOL_SOCKET, SO_RCVBUF, &receiveSize, socklen_t(MemoryLayout.size(ofValue: receiveSize)))
            }
            var local = Self.address(INADDR_ANY, 28_001)
            let bound = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(udp, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0 else {
                if errno == EADDRINUSE {
                    throw SetbeamError.unavailable("Accsoon's receiving port is already in use. Quit Accsoon SEE, then connect in Setbeam again.")
                }
                throw Self.socketError("Setbeam could not open Accsoon's receiving port")
            }
            tcp = try Self.socket(SOCK_STREAM)
            var noSignal: Int32 = 1
            _ = setsockopt(tcp, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
            var remote = Self.address(peer.s_addr, 28_010)
            let connected = withUnsafePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(tcp, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if connected != 0 {
                guard errno == EINPROGRESS else { throw Self.connectionError() }
                var descriptor = pollfd(fd: tcp, events: Int16(POLLOUT), revents: 0)
                guard Darwin.poll(&descriptor, 1, 2_000) > 0 else { throw Self.connectionError() }
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout.size(ofValue: socketError))
                guard getsockopt(tcp, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else {
                    throw Self.connectionError()
                }
            }
            output = try Self.socket(SOCK_DGRAM)
        } catch {
            for socket in [udp, tcp, output] where socket >= 0 { Darwin.close(socket) }
            throw error
        }
        self.udp = udp; self.tcp = tcp; self.output = output; self.peer = peer
        self.deviceUID = deviceUID
        videoDestination = Self.address(inet_addr("127.0.0.1"), videoPort)
        audioDestination = audioPort.map { Self.address(inet_addr("127.0.0.1"), $0) }
        self.onFailure = onFailure; self.onAnnouncement = onAnnouncement
    }

    var isRunning: Bool { condition.lock(); defer { condition.unlock() }; return !finished && !cancelled }

    var statistics: [String: Int] {
        var result = counters.snapshot
        condition.lock()
        result["running"] = !finished && !cancelled ? 1 : 0
        result["tcpConnected"] = finished ? 0 : 1
        condition.unlock()
        return result
    }

    func start() { DispatchQueue(label: "app.setbeam.accsoon.receive", qos: .userInitiated).async { self.run() } }

    func stop() -> Bool {
        condition.lock()
        cancelled = true
        let deadline = Date().addingTimeInterval(2)
        while !finished, condition.wait(until: deadline) {}
        let result = finished
        condition.unlock()
        return result
    }

    private var shouldStop: Bool { condition.lock(); defer { condition.unlock() }; return cancelled }

    private func run() {
        defer {
            // A disconnect uses this session's UID and socket, never another app's session.
            let disconnect = framed(packet(channel: 0, command: 13))
            disconnect.withUnsafeBytes { bytes in _ = Darwin.send(tcp, bytes.baseAddress, bytes.count, 0) }
            Darwin.close(udp); Darwin.close(tcp); Darwin.close(output)
            condition.lock(); finished = true; condition.broadcast(); condition.unlock()
        }
        var subscribedAt = -Double.infinity
        var keepaliveAt = -Double.infinity
        var acknowledgedAt = -Double.infinity
        var requestedAt = -Double.infinity
        var statusAt = -Double.infinity
        let began = ProcessInfo.processInfo.systemUptime
        var receivedAt = began
        do {
            while !shouldStop {
                let now = ProcessInfo.processInfo.systemUptime
                // Empty the kernel receive queue first. Parsing and retransmission work follows.
                for received in try drainUDP() { try receive(received, now: now, receivedAt: &receivedAt) }
                try drainTCP(now: now, receivedAt: &receivedAt)
                if now - subscribedAt >= 0.5 {
                    let streams: [UInt8] = !acknowledgedConnection ? [0] : audioDestination == nil ? [1, 1] : [2, 1, 100]
                    let subscription = packet(channel: 0, command: 11, body: Data(streams))
                    try enqueue(subscription)
                    counters.add("subscriptions")
                    subscribedAt = now
                }
                if now - keepaliveAt >= 1 {
                    // RTMS TCP's heartbeat is an empty outer frame, not an extension command.
                    try enqueue(Data())
                    counters.add("sentTCPHeartbeats")
                    keepaliveAt = now
                }
                if acknowledgedConnection, now - statusAt >= 2 {
                    for command: UInt16 in [1000, 20, 30, 90] { try enqueue(packet(channel: 3, command: command)) }
                    statusAt = now
                }
                if now - acknowledgedAt >= 0.25 {
                    for acknowledgement in assembler.acknowledgements {
                        var body = Data([acknowledgement.stream.stream, acknowledgement.stream.substream])
                        body.appendLE(UInt16(0x8000)); body.appendLE(ackSequence); body.appendLE(acknowledgement.message)
                        try enqueue(packet(channel: 1, command: 50, body: body)); ackSequence &+= 1
                        counters.add("acknowledgements")
                    }
                    acknowledgedAt = now
                }
                if now - requestedAt >= 0.1 {
                    for request in assembler.missingFragments(now: now) {
                        var body = Data([request.stream.stream, request.stream.substream])
                        body.appendLE(nakSequence); body.appendLE(UInt16(request.messages.count))
                        for message in request.messages {
                            body.appendLE(message.id); body.appendLE(UInt16(message.indices.count))
                            for index in message.indices { body.appendLE(index) }
                        }
                        let request = packet(channel: 1, command: 52, body: body)
                        var destination = Self.address(peer.s_addr, 28_000)
                        request.withUnsafeBytes { raw in
                            withUnsafePointer(to: &destination) { pointer in
                                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                    _ = Darwin.sendto(udp, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                                }
                            }
                        }
                        nakSequence &+= 1
                        counters.add("negativeAcknowledgements")
                    }
                    requestedAt = now
                }
                if assembler.hasExpiredGap(now: now) {
                    throw SetbeamError.unavailable("The Accsoon picture lost data that could not be recovered. Reconnecting to the transmitter is needed.")
                }
                if now - receivedAt > 8 {
                    throw SetbeamError.unavailable("The Accsoon transmitter stopped responding. Check its power and Wi-Fi connection.")
                }
                try flushTCP()
                var descriptors = [pollfd(fd: udp, events: Int16(POLLIN), revents: 0),
                                   pollfd(fd: tcp, events: Int16(POLLIN | (tcpOutput.isEmpty ? 0 : POLLOUT)), revents: 0)]
                let polled = Darwin.poll(&descriptors, nfds_t(descriptors.count), 20)
                if polled < 0, errno != EINTR { throw Self.socketError("The Accsoon connection could not be monitored") }
            }
        } catch {
            if !shouldStop { onFailure(error.localizedDescription) }
        }
    }

    private func drainUDP() throws -> [Data] {
        var result: [Data] = []
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var bytes = 0
        for _ in 0..<512 {
            if shouldStop || bytes >= 8 * 1_024 * 1_024 { break }
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.recvfrom(udp, &buffer, buffer.count, 0, $0, &length) }
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                if errno == EINTR { continue }
                throw Self.socketError("The Accsoon receiving socket failed")
            }
            counters.add("udpPackets")
            counters.add("udpBytes", by: count)
            if count > 0, sender.sin_addr.s_addr == peer.s_addr {
                result.append(Data(buffer.prefix(count))); bytes += count
            } else { counters.add("rejectedPeerPackets") }
        }
        return result
    }

    private func drainTCP(now: Double, receivedAt: inout Double) throws {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<128 {
            if shouldStop { return }
            let count = Darwin.recv(tcp, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                throw Self.connectionError()
            }
            guard count != 0 else { throw Self.connectionError() }
            tcpInput.append(contentsOf: buffer.prefix(count))
            while tcpInput.count >= 8 {
                guard tcpInput.u32LE(0) == 0x78a3f889, let length = tcpInput.u32LE(4), length <= 8 * 1_024 * 1_024 else {
                    throw SetbeamError.unavailable("The Accsoon transmitter sent an invalid connection frame.")
                }
                let frameLength = 8 + Int(length)
                guard tcpInput.count >= frameLength else { break }
                counters.add("tcpFrames")
                if length > 0 { try receive(Data(tcpInput[8..<frameLength]), now: now, receivedAt: &receivedAt) }
                else { receivedAt = now; counters.add("receivedTCPHeartbeats") }
                tcpInput = Data(tcpInput.dropFirst(frameLength))
            }
            guard tcpInput.count <= 8 * 1_024 * 1_024 + 8 else {
                throw SetbeamError.unavailable("The Accsoon connection exceeded its receive limit.")
            }
        }
    }

    private func receive(_ data: Data, now: Double, receivedAt: inout Double) throws {
        guard data.count >= 12, data.u32LE(0) == 0x78776e93, data[8] == 0x40 else {
            counters.add("invalidHeaderPackets"); return
        }
        guard data.u32LE(4) == deviceUID else { counters.add("rejectedUIDPackets"); return }
        counters.add("matchingUIDPackets")
        receivedAt = now
        if data[9] == 0, data.u16LE(10) == 12 {
            acknowledgedConnection = true; counters.add("connectionAcknowledgements"); return
        }
        if data[9] == 0, data.u16LE(10) == 10 { counters.add("announcements"); onAnnouncement(data); return }
        guard data[9] == 2, data.count >= 24 else { return }
        counters.add("mediaFragments")
        guard data[12] == 1 || (data[12] == 100 && audioDestination != nil) else {
            counters.add("unsubscribedStreamFragments"); return
        }
        counters.add(data[12] == 1 ? "videoFragments" : "audioFragments")
        for complete in try assembler.receive(data, now: now) {
            counters.add(complete.stream.stream == 1 ? "completedVideoMessages" : "completedAudioMessages")
            guard let media = AccsoonEncodedMessage(complete.data) else { counters.add("invalidEncodedMessages"); continue }
            if complete.stream.stream == 1 {
                guard media.codec == 265 else {
                    throw SetbeamError.unavailable("This Accsoon video format is not supported. Select H.265 monitoring in the transmitter settings.")
                }
                for packet in try videoRTP.hevc(media.payload, timestamp: media.timestamp) {
                    if try send(packet, destination: &videoDestination) { counters.add("forwardedVideoRTPPackets") }
                }
            } else if var destination = audioDestination {
                guard media.codec == 37 else {
                    throw SetbeamError.unavailable("This Accsoon audio format is not supported. Reconnect with audio disabled.")
                }
                for packet in try audioRTP.aac(media.payload, timestamp: media.timestamp) {
                    if try send(packet, destination: &destination) { counters.add("forwardedAudioRTPPackets") }
                }
            }
        }
    }

    private func send(_ data: Data, destination: inout sockaddr_in) throws -> Bool {
        let count = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.sendto(output, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != ENOBUFS, errno != ECONNREFUSED {
            throw Self.socketError("Setbeam could not forward the Accsoon picture locally")
        }
        if count != data.count { counters.add("droppedLoopbackRTPPackets") }
        return count == data.count
    }

    private func packet(channel: UInt8, command: UInt16, body: Data = Data()) -> Data {
        var result = Data(); result.appendLE(UInt32(0x78776e93)); result.appendLE(clientUID)
        result.append(contentsOf: [0x40, channel]); result.appendLE(command); result.append(body)
        return result
    }

    private func framed(_ payload: Data) -> Data {
        var result = Data(); result.appendLE(UInt32(0x78a3f889)); result.appendLE(UInt32(payload.count)); result.append(payload)
        return result
    }

    private func enqueue(_ packet: Data) throws {
        if tcpOutputOffset > 0 { tcpOutput.removeFirst(tcpOutputOffset); tcpOutputOffset = 0 }
        guard tcpOutput.count + packet.count + 8 <= 1_024 * 1_024 else { throw Self.connectionError() }
        tcpOutput.append(framed(packet))
    }

    private func flushTCP() throws {
        while tcpOutputOffset < tcpOutput.count {
            let count = tcpOutput.withUnsafeBytes { bytes in
                Darwin.send(tcp, bytes.baseAddress!.advanced(by: tcpOutputOffset), bytes.count - tcpOutputOffset, 0)
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                throw Self.connectionError()
            }
            guard count > 0 else { throw Self.connectionError() }
            tcpOutputOffset += count
        }
        tcpOutput.removeAll(keepingCapacity: true); tcpOutputOffset = 0
    }

    private static func socket(_ type: Int32) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, type, 0)
        guard descriptor >= 0 else { throw socketError("Setbeam could not open the Accsoon connection") }
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            Darwin.close(descriptor); throw socketError("Setbeam could not prepare the Accsoon connection")
        }
        guard fcntl(descriptor, F_SETFD, fcntl(descriptor, F_GETFD) | FD_CLOEXEC) == 0 else {
            Darwin.close(descriptor); throw socketError("Setbeam could not protect the Accsoon connection")
        }
        return descriptor
    }

    private static func address(_ address: in_addr_t, _ port: UInt16) -> sockaddr_in {
        var result = sockaddr_in(); result.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        result.sin_family = sa_family_t(AF_INET); result.sin_addr.s_addr = address; result.sin_port = port.bigEndian
        return result
    }

    private static func socketError(_ message: String) -> SetbeamError {
        SetbeamError.unavailable("\(message). \(String(cString: strerror(errno))).")
    }

    private static func connectionError() -> SetbeamError {
        SetbeamError.unavailable("Setbeam could not keep its Accsoon connection. Check the transmitter's power and join its Wi-Fi again.")
    }
}

final class AccsoonReceiveCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var values = Dictionary(uniqueKeysWithValues: [
        "udpPackets", "udpBytes", "rejectedPeerPackets", "tcpFrames", "receivedTCPHeartbeats",
        "sentTCPHeartbeats", "subscriptions", "acknowledgements", "negativeAcknowledgements",
        "invalidHeaderPackets", "rejectedUIDPackets", "matchingUIDPackets", "announcements",
        "mediaFragments", "unsubscribedStreamFragments", "videoFragments", "audioFragments",
        "completedVideoMessages", "completedAudioMessages", "invalidEncodedMessages",
        "forwardedVideoRTPPackets", "forwardedAudioRTPPackets", "droppedLoopbackRTPPackets"
    ].map { ($0, 0) })

    func add(_ name: String, by count: Int = 1) {
        lock.lock(); defer { lock.unlock() }
        values[name, default: 0] += count
    }

    var snapshot: [String: Int] { lock.lock(); defer { lock.unlock() }; return values }
}

struct AccsoonRTMSStream: Hashable {
    let stream: UInt8
    let substream: UInt8
}

/// Packet and message limits bound both malformed input and an unavailable retransmission.
struct AccsoonRTMSAssembler {
    struct Complete { let stream: AccsoonRTMSStream; let data: Data }
    struct Acknowledgement { let stream: AccsoonRTMSStream; let message: UInt32 }
    struct Missing { let id: UInt32; let indices: [UInt16] }
    struct Request { let stream: AccsoonRTMSStream; let messages: [Missing] }
    private struct Message {
        let count: Int
        let began: Double
        var parts: [Int: Data] = [:]
        var bytes = 0
        var complete: Data?
    }
    private struct Stream {
        var next: UInt32
        var acknowledged: UInt32?
        var messages: [UInt32: Message] = [:]
        // Derive the deadline from the messages still waiting. A busy stream can
        // always have a newer partial message while each older gap recovers.
        var gapBegan: Double? { messages.values.lazy.map(\.began).min() }
    }
    private var streams: [AccsoonRTMSStream: Stream] = [:]
    private var bytes = 0

    var acknowledgements: [Acknowledgement] {
        streams.compactMap { key, value in value.acknowledged.map { Acknowledgement(stream: key, message: $0) } }
    }

    mutating func receive(_ data: Data, now: Double) throws -> [Complete] {
        guard data.count >= 24, let id = data.u32LE(16), let count = data.u16LE(20), let index = data.u16LE(22),
              count > 0, count <= 4_096, index < count, data.count > 24 else { return [] }
        let key = AccsoonRTMSStream(stream: data[12], substream: data[13])
        guard streams[key] != nil || streams.count < 16 else { return [] }
        var stream = streams[key] ?? Stream(next: id)
        let distance = Int32(bitPattern: id &- stream.next)
        guard distance >= 0 else { return [] }
        guard distance < 128 else { throw SetbeamError.unavailable("The Accsoon connection lost too many video messages. Reconnect to the transmitter.") }
        var message = stream.messages[id] ?? Message(count: Int(count), began: now)
        guard message.count == Int(count), message.complete == nil, message.parts[Int(index)] == nil else { return [] }
        let fragment = Data(data.dropFirst(24))
        guard message.bytes + fragment.count <= 8 * 1_024 * 1_024, bytes + fragment.count <= 16 * 1_024 * 1_024 else {
            throw SetbeamError.unavailable("The Accsoon picture exceeded its receive limit. Reconnect to the transmitter.")
        }
        message.parts[Int(index)] = fragment; message.bytes += fragment.count; bytes += fragment.count
        if message.parts.count == message.count {
            var complete = Data(capacity: message.bytes)
            for part in 0..<message.count { complete.append(message.parts[part]!) }
            message.parts.removeAll(); message.complete = complete
        }
        stream.messages[id] = message
        var result: [Complete] = []
        while let complete = stream.messages[stream.next]?.complete {
            bytes -= complete.count
            result.append(Complete(stream: key, data: complete)); stream.messages.removeValue(forKey: stream.next)
            stream.acknowledged = stream.next; stream.next &+= 1
        }
        streams[key] = stream
        return result
    }

    func hasExpiredGap(now: Double) -> Bool {
        streams.values.contains { $0.gapBegan.map { now - $0 > 3 } ?? false }
    }

    func missingFragments(now: Double) -> [Request] {
        streams.compactMap { key, stream -> Request? in
            guard let furthest = stream.messages.keys.map({ $0 &- stream.next }).max() else { return nil }
            var messages: [Missing] = []
            for distance in 0...furthest {
                let id = stream.next &+ distance
                if let message = stream.messages[id] {
                    guard message.complete == nil, now - message.began >= 0.05 else { continue }
                    let indices = Array((0..<message.count).lazy.filter { message.parts[$0] == nil }.prefix(128).map { UInt16($0) })
                    if !indices.isEmpty { messages.append(Missing(id: id, indices: indices)) }
                } else if let gap = stream.gapBegan, now - gap >= 0.05 {
                    // The native server treats an empty index list as a whole-message request.
                    messages.append(Missing(id: id, indices: []))
                }
                if messages.count == 8 { break }
            }
            return messages.isEmpty ? nil : Request(stream: key, messages: messages)
        }
    }
}

struct AccsoonEncodedMessage {
    let timestamp: UInt64
    let codec: UInt32
    let payload: Data
    init?(_ message: Data) {
        guard message.count >= 24, let timestamp = message.u64LE(0), let codec = message.u32LE(8), let length = message.u32LE(20),
              length > 0, Int(length) <= message.count - 24 else { return nil }
        self.timestamp = timestamp; self.codec = codec & 0x3ff; payload = Data(message[24..<24 + Int(length)])
    }
}

/// RFC 7798 HEVC and RFC 3640 AAC-hbr, with a conservative 1,200-byte RTP packet limit.
struct AccsoonRTPPacketizer {
    private let payloadType: UInt8
    private var sequence = UInt16.random(in: .min ... .max)
    private let ssrc = UInt32.random(in: 1...UInt32.max)
    // One current VPS, SPS, and PPS. Do not retain arbitrarily large source data.
    private var parameterSets: [UInt8: Data] = [:]
    private static let maximumParameterSetBytes = 65_536
    init(payloadType: UInt8) { self.payloadType = payloadType }

    mutating func hevc(_ annexB: Data, timestamp: UInt64) throws -> [Data] {
        var units = Self.nalUnits(annexB)
        guard !units.isEmpty else { return [] }
        for nal in units {
            guard nal.count >= 2, nal[0] & 0x80 == 0, nal[1] & 0x07 != 0 else {
                throw SetbeamError.unavailable("The Accsoon transmitter sent an invalid H.265 picture.")
            }
        }
        let types = Set(units.map { ($0[0] >> 1) & 0x3f })
        for nal in units {
            let type = (nal[0] >> 1) & 0x3f
            if (32...34).contains(type) {
                if nal.count <= Self.maximumParameterSetBytes {
                    // Copy this small NAL so a slice cannot retain a whole video message.
                    parameterSets[type] = nal.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
                }
                else { parameterSets.removeValue(forKey: type) }
            }
        }
        if types.contains(where: { (16...23).contains($0) }) {
            // A new local decoder may have missed the initial parameter packets.
            // Repeat only absent sets before each random-access picture.
            let missing = [UInt8(32), 33, 34].filter { !types.contains($0) }.compactMap { parameterSets[$0] }
            units.insert(contentsOf: missing, at: 0)
        }
        var packets: [Data] = []
        let clock = Self.clock(timestamp, rate: 90_000)
        for (index, nal) in units.enumerated() {
            let type = (nal[0] >> 1) & 0x3f
            let marker = index == units.count - 1 && type <= 31
            if nal.count <= 1_188 { packets.append(packet(nal, timestamp: clock, marker: marker)); continue }
            var offset = 2
            while offset < nal.count {
                let end = min(offset + 1_185, nal.count)
                var payload = Data([(nal[0] & 0x81) | (49 << 1), nal[1], type | (offset == 2 ? 0x80 : 0) | (end == nal.count ? 0x40 : 0)])
                payload.append(nal[offset..<end])
                packets.append(packet(payload, timestamp: clock, marker: marker && end == nal.count)); offset = end
            }
        }
        return packets
    }

    mutating func aac(_ adts: Data, timestamp: UInt64) throws -> [Data] {
        var offset = 0
        var frame: UInt32 = 0
        var packets: [Data] = []
        while offset < adts.count {
            guard adts.count - offset >= 7, adts[offset] == 0xff, adts[offset + 1] & 0xf6 == 0xf0 else { throw Self.audioError() }
            let headerLength = adts[offset + 1] & 1 == 1 ? 7 : 9
            let profile = adts[offset + 2] >> 6
            let sampleRateIndex = (adts[offset + 2] >> 2) & 0x0f
            let channels = ((adts[offset + 2] & 1) << 2) | (adts[offset + 3] >> 6)
            let length = (Int(adts[offset + 3] & 3) << 11) | (Int(adts[offset + 4]) << 3) | Int(adts[offset + 5] >> 5)
            guard profile == 1, sampleRateIndex == 3, channels == 2, adts[offset + 6] & 3 == 0,
                  length > headerLength, length <= adts.count - offset else { throw Self.audioError() }
            let unit = Data(adts[offset + headerLength..<offset + length])
            // AU-size is 13 bits, AU-index is three bits. Each packet carries one access unit.
            let clock = Self.clock(timestamp, rate: 48_000) &+ frame * 1_024
            var beginning = 0
            while beginning < unit.count {
                let end = min(beginning + 1_184, unit.count)
                var payload = Data([0, 16, UInt8(unit.count >> 5), UInt8((unit.count & 31) << 3)])
                payload.append(unit[beginning..<end])
                packets.append(packet(payload, timestamp: clock, marker: end == unit.count)); beginning = end
            }
            offset += length; frame += 1
        }
        return packets
    }

    private mutating func packet(_ payload: Data, timestamp: UInt32, marker: Bool) -> Data {
        var result = Data([0x80, payloadType | (marker ? 0x80 : 0)])
        result.appendBE(sequence); result.appendBE(timestamp); result.appendBE(ssrc); result.append(payload)
        sequence &+= 1
        return result
    }

    static func clock(_ timestamp: UInt64, rate: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: (timestamp / 1_000_000) &* rate &+ (timestamp % 1_000_000) * rate / 1_000_000)
    }

    private static func nalUnits(_ data: Data) -> [Data] {
        var starts: [(offset: Int, length: Int)] = []
        var offset = 0
        while offset + 2 < data.count {
            if data[offset] == 0, data[offset + 1] == 0 {
                if data[offset + 2] == 1 { starts.append((offset, 3)); offset += 3; continue }
                if offset + 3 < data.count, data[offset + 2] == 0, data[offset + 3] == 1 {
                    starts.append((offset, 4)); offset += 4; continue
                }
            }
            offset += 1
        }
        guard !starts.isEmpty else { return data.isEmpty ? [] : [data] }
        return starts.enumerated().compactMap { index, start in
            let end = index + 1 < starts.count ? starts[index + 1].offset : data.count
            let beginning = start.offset + start.length
            return end > beginning ? Data(data[beginning..<end]) : nil
        }
    }

    private static func audioError() -> SetbeamError {
        SetbeamError.unavailable("The Accsoon audio is not 48 kHz stereo AAC. Reconnect with audio disabled.")
    }
}

private extension Data {
    func u16LE(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func u32LE(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[offset + $1]) << ($1 * 8) }
    }
    func u64LE(_ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[offset + $1]) << ($1 * 8) }
    }
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var bytes = value.littleEndian; Swift.withUnsafeBytes(of: &bytes) { append(contentsOf: $0) }
    }
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var bytes = value.bigEndian; Swift.withUnsafeBytes(of: &bytes) { append(contentsOf: $0) }
    }
}
