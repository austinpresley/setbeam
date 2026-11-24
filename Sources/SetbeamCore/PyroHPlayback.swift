import Darwin
import Foundation
import os

/// One FFmpeg connection on loopback, backed by one interface-bound RTSP-over-TCP socket.
final class PyroHPlayback: Sendable {
    let inputURL: String
    private let work: DispatchGroup
    private let state: OSAllocatedUnfairLock<State>
    private struct State {
        var stopped = false
        var problem: String?
    }

    var problem: String? { state.withLock { $0.problem } }

    init(route: PyroHRoute, currentNetworks: @escaping @Sendable () -> [PyroHNetwork]) throws {
        try route.requireCurrent(currentNetworks())
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Self.listenerError }
        var local = PyroHSocket.address("127.0.0.1")!
        var length = PyroHSocket.addressSize
        let bound = PyroHSocket.configure(listener) && PyroHSocket.bind(listener, &local) && listen(listener, 1) == 0
        let named = bound && withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) == 0 }
        }
        guard named else { close(listener); throw Self.listenerError }

        let origin = "rtsp://127.0.0.1:\(UInt16(bigEndian: local.sin_port))"
        inputURL = origin + "/live"
        let state = OSAllocatedUnfairLock(initialState: State())
        self.state = state
        work = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: work) {
            let stopped = { state.withLock { $0.stopped } }
            var nextCheck: UInt64 = 0
            func routeLost() -> Bool {
                if stopped() { return true }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now >= nextCheck else { return false }
                nextCheck = now + 500_000_000
                do { try route.requireCurrent(currentNetworks()); return false }
                catch { state.withLock { $0.problem = error.localizedDescription }; return true }
            }

            guard let client = Self.accept(listener, cancelled: routeLost) else { return }
            defer { close(client) }
            // Recheck immediately before opening the source, regardless of the health-check cadence.
            nextCheck = 0
            guard let upstream = PyroHSocket.connect(route, deadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000,
                                                      cancelled: routeLost) else { return }
            defer { close(upstream) }
            nextCheck = 0
            Self.forward(client: client, upstream: upstream, route: route, localOrigin: origin, cancelled: routeLost)
        }
    }

    func stop() { state.withLock { $0.stopped = true }; work.wait() }
    deinit { stop() }

    private static var listenerError: SetbeamError { .runtime("Setbeam could not open the private Pyro H playback port.") }

    private static func accept(_ listener: Int32, cancelled: () -> Bool) -> Int32? {
        defer { close(listener) }
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while PyroHSocket.wait(listener, events: Int16(POLLIN), deadline: deadline, cancelled: cancelled) {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard client >= 0 else { return nil }
            guard PyroHSocket.configure(client) else { close(client); return nil }
            return client
        }
        return nil
    }

    private static func forward(client: Int32, upstream: Int32, route: PyroHRoute, localOrigin: String, cancelled: () -> Bool) {
        let upstreamOrigin = "rtsp://\(route.network.router):\(route.port)"
        var request = RTSPDirection(clientRequest: true, localOrigin: localOrigin, upstreamOrigin: upstreamOrigin)
        var response = RTSPDirection(clientRequest: false, localOrigin: localOrigin, upstreamOrigin: upstreamOrigin)
        var fds = [pollfd(fd: client, events: 0, revents: 0), pollfd(fd: upstream, events: 0, revents: 0)]
        while !cancelled() {
            fds[0].events = request.pending ? 0 : Int16(POLLIN)
            fds[1].events = response.pending ? 0 : Int16(POLLIN)
            if response.pending { fds[0].events |= Int16(POLLOUT) }
            if request.pending { fds[1].events |= Int16(POLLOUT) }
            let count = poll(&fds, 2, 50)
            if count < 0 && errno != EINTR { return }
            if count <= 0 { continue }
            if fds.contains(where: { $0.revents & Int16(POLLERR | POLLNVAL | POLLHUP) != 0 }) { return }
            do {
                if fds[0].revents & Int16(POLLOUT) != 0 { try response.flush(to: client) }
                if fds[1].revents & Int16(POLLOUT) != 0 { try request.flush(to: upstream) }
                if fds[0].revents & Int16(POLLIN) != 0 { try request.read(from: client) }
                if fds[1].revents & Int16(POLLIN) != 0 { try response.read(from: upstream) }
            } catch { return }
        }
    }
}

/// Bound the bytes held per direction and never pass a redirect to the player. Interleaved RTP/RTCP
/// shares the TCP socket, so a status line is interpreted only at a control message boundary.
private struct RTSPDirection {
    let clientRequest: Bool
    let localOrigin: String
    let upstreamOrigin: String
    private let boundary = Data("\r\n\r\n".utf8)
    private var bytes = [UInt8](repeating: 0, count: 65_536)
    private var buffer = Data()
    private var output = Data()
    private var written = 0

    init(clientRequest: Bool, localOrigin: String, upstreamOrigin: String) {
        self.clientRequest = clientRequest; self.localOrigin = localOrigin; self.upstreamOrigin = upstreamOrigin
    }

    var pending: Bool { !output.isEmpty }

    mutating func flush(to fd: Int32) throws {
        let count = output.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: written), output.count - written, 0) }
        if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
        guard count > 0 else { throw Closed.connection }
        written += count
        if written == output.count { output.removeAll(keepingCapacity: true); written = 0 }
    }

    mutating func read(from fd: Int32) throws {
        let count = bytes.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
        guard count > 0 else { throw Closed.connection }
        buffer.append(contentsOf: bytes.prefix(count))
        var start = buffer.startIndex
        while start < buffer.endIndex {
            if buffer[start] == 0x24 {
                guard buffer.endIndex - start >= 4 else { break }
                let end = start + 4 + (Int(buffer[start + 2]) << 8) + Int(buffer[start + 3])
                guard buffer.endIndex >= end else { break }
                output.append(buffer[start..<end]); start = end
                continue
            }

            guard let split = buffer.range(of: boundary, in: start..<buffer.endIndex) else {
                guard buffer.endIndex - start <= 16_384 else { throw Closed.connection }
                break
            }
            guard split.upperBound - start <= 16_384,
                  let header = String(data: buffer[start..<split.lowerBound], encoding: .utf8) else { throw Closed.connection }
            let lines = header.components(separatedBy: "\r\n")
            var length: Int?
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw Closed.connection }
                if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    guard length == nil, let size = Int(value), (0...65_536).contains(size) else { throw Closed.connection }
                    length = size
                }
            }
            let end = split.upperBound + (length ?? 0)
            guard buffer.endIndex >= end else { break }
            let firstLine = try forwardLine(lines[0])
            if firstLine == lines[0] { output.append(buffer[start..<end]) }
            else {
                output.append(contentsOf: ([firstLine] + lines.dropFirst()).joined(separator: "\r\n").utf8)
                output.append(boundary)
                output.append(buffer[split.upperBound..<end])
            }
            start = end
        }
        if start == buffer.endIndex { buffer.removeAll(keepingCapacity: true) }
        else if start > buffer.startIndex { buffer = Data(buffer[start...]) }
    }

    private func forwardLine(_ line: String) throws -> String {
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count == 3 else { throw Closed.connection }
        if !clientRequest {
            guard parts[0] == "RTSP/1.0", let status = Int(parts[1]), (100...599).contains(status),
                  !(300...399).contains(status) else { throw Closed.connection }
            return line
        }
        guard parts[2] == "RTSP/1.0" else { throw Closed.connection }
        let uri = parts[1]
        if uri.hasPrefix(localOrigin + "/") {
            return "\(parts[0]) \(upstreamOrigin)\(uri.dropFirst(localOrigin.count)) \(parts[2])"
        }
        if uri == "*" || uri.hasPrefix(upstreamOrigin + "/") ||
            (upstreamOrigin.hasSuffix(":554") && uri.hasPrefix(upstreamOrigin.dropLast(4) + "/")) { return line }
        throw Closed.connection
    }

    private enum Closed: Error { case connection }
}
