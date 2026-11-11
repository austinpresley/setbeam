import Foundation
import Network

/// Answers a typed local address, such as `http://setbeam.local/`, by sending the browser to the
/// gateway's ask-only short-address path.
///
/// A browser that is given only a name opens port 80. On the tested macOS 27 build an unprivileged
/// process can bind port 80 only on the wildcard address, so this listener binds IPv4 `0.0.0.0:80`
/// but answers only connections whose local destination is the selected viewing address and whose
/// `Host` is that address or its local name. Every other connection is closed unanswered, including
/// one still being read when the viewing address moves. It never
/// shares the port with another listener, and serves nothing but the redirect: no viewer assets,
/// media, publishing, or administration. The redirect carries the short-address code, never the
/// viewing link's code.
public final class ShortAddressListener: @unchecked Sendable {
    public enum Problem: String, Sendable { case inUse, denied, unavailable }
    public enum State: Equatable, Sendable { case stopped, starting, active, unavailable(Problem) }
    /// Where typed addresses go now. Updated in place when the viewing address or name changes.
    public struct Route: Equatable, Sendable {
        /// The viewing IPv4 address. Connections to any other local address are closed.
        public var address: String
        /// Names a viewer may type, such as `setbeam.local`.
        public var hosts: [String]
        /// The viewer gateway's port and the short-address path on it.
        public var port: UInt16
        public var path: String
        public init(address: String, hosts: [String], port: UInt16, path: String) {
            self.address = address; self.hosts = hosts; self.port = port; self.path = path
        }
    }
    public static let webPort: UInt16 = 80
    static let headerLimit = 4096

    private let queue = DispatchQueue(label: "app.setbeam.short-address", qos: .userInitiated)
    private let lock = NSLock()
    private let port: UInt16
    private let retryDelay: TimeInterval
    private let requestTimeout: TimeInterval
    private let maxConnections: Int
    private let makeListener: (NWParameters, NWEndpoint.Port) throws -> NWListener
    private var listener: NWListener?
    /// A stopped listener releases port 80 asynchronously; the next start waits briefly for it.
    private var stoppedListener: NWListener?
    private var attempt = UUID()
    private var route: Route?
    private var retry: DispatchWorkItem?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var current = State.stopped
    private var observer: (@Sendable (State) -> Void)?

    /// Receives each state change once, on the listener's queue.
    public var onChange: (@Sendable (State) -> Void)? {
        get { lock.withLock { observer } }
        set { lock.withLock { observer = newValue } }
    }
    public var state: State { lock.withLock { current } }
    /// The bound port while active. Port 80 unless a test asked for another.
    public var boundPort: UInt16? { lock.withLock { current == .active ? listener?.port?.rawValue : nil } }

    public convenience init() { self.init(port: Self.webPort) }
    /// For checks that need a faster retry or, with port 0, any free port.
    public convenience init(port: UInt16, retryDelay: TimeInterval) { self.init(port: port, retryDelay: retryDelay, requestTimeout: 3) }

    init(port: UInt16, retryDelay: TimeInterval = 10, requestTimeout: TimeInterval = 3, maxConnections: Int = 16,
         listenerFactory: @escaping (NWParameters, NWEndpoint.Port) throws -> NWListener = { try NWListener(using: $0, on: $1) }) {
        self.port = port; self.retryDelay = retryDelay; self.requestTimeout = requestTimeout
        self.maxConnections = maxConnections; makeListener = listenerFactory
    }

    /// Starts answering, or updates where answers go. A port another app holds or macOS refuses is
    /// reported and retried while a route is set. A new viewing address closes open requests made to
    /// the old one; a new name or path keeps them and answers with the new route.
    public func serve(_ route: Route) {
        let (start, moved) = lock.withLock { () -> (UUID?, [NWConnection]) in
            var moved: [NWConnection] = []
            if let previous = self.route, previous.address != route.address { moved = Array(connections.values); connections.removeAll() }
            self.route = route
            guard listener == nil, retry == nil, current != .starting else { return (nil, moved) }
            attempt = UUID(); return (attempt, moved)
        }
        moved.forEach { $0.cancel() }
        if let start { queue.async { [weak self] in self?.begin(start, until: .now() + 1) } }
    }

    /// Stops answering at once and releases the port. Open requests are closed unanswered.
    public func stop() {
        let (closing, notify) = lock.withLock { () -> ((NWListener?, DispatchWorkItem?, [NWConnection]), (@Sendable (State) -> Void)?) in
            let closing = (listener, retry, Array(connections.values))
            stoppedListener = listener ?? stoppedListener
            route = nil; listener = nil; retry = nil; connections.removeAll(); attempt = UUID()
            guard current != .stopped else { return (closing, nil) }
            current = .stopped; return (closing, observer)
        }
        closing.1?.cancel(); closing.2.forEach { $0.cancel() }; closing.0?.cancel()
        if let notify { queue.async { notify(.stopped) } }
    }

    private func begin(_ expected: UUID, until deadline: DispatchTime = .now()) {
        guard let previous = lock.withLock({ attempt == expected && route != nil ? .some(stoppedListener) : .none }) else { return }
        if let previous, previous.state != .cancelled, .now() < deadline {
            queue.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.begin(expected, until: deadline) }
            return
        }
        lock.withLock { stoppedListener = nil }
        if state == .stopped { set(.starting, attempt: expected) }
        let parameters = NWParameters.tcp
        // Never share port 80 with another app's listener.
        parameters.allowLocalEndpointReuse = false
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let listener: NWListener
        do { listener = try makeListener(parameters, NWEndpoint.Port(rawValue: port)!) }
        catch { fail(expected, error, until: deadline); return }
        let kept = lock.withLock { () -> Bool in
            guard attempt == expected, route != nil else { return false }
            self.listener = listener; return true
        }
        guard kept else { listener.cancel(); return }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.set(.active, attempt: expected)
            case .failed(let error), .waiting(let error): self.fail(expected, error, until: deadline)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, attempt: expected) }
        listener.start(queue: queue)
    }

    private func fail(_ expected: UUID, _ error: Error, until deadline: DispatchTime) {
        let problem = Self.problem(error)
        // Cancellation releases Network.framework's socket asynchronously, including when
        // another ShortAddressListener takes over. Give that handoff the same one-second
        // grace as a restart on this instance, without enabling endpoint reuse. A real
        // port owner still gets the named error and the ordinary, slower retry below.
        let handingOff = problem == .inUse && .now() < deadline
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let next = self.lock.withLock { () -> UUID? in
                guard self.attempt == expected, self.route != nil, self.retry != nil else { return nil }
                self.retry = nil; self.attempt = UUID(); return self.attempt
            }
            if let next { self.begin(next, until: deadline) }
        }
        let failed = lock.withLock { () -> NWListener?? in
            guard attempt == expected, route != nil else { return .none }
            let failed = listener; listener = nil
            stoppedListener = failed ?? stoppedListener
            retry?.cancel(); retry = work
            return .some(failed)
        }
        guard case .some(let previous) = failed else { return }
        previous?.cancel()
        if !handingOff { set(.unavailable(problem), attempt: expected) }
        queue.asyncAfter(deadline: .now() + (handingOff ? 0.01 : retryDelay), execute: work)
    }

    static func problem(_ error: Error) -> Problem {
        if case NWError.posix(let code) = error {
            if code == .EADDRINUSE { return .inUse }
            if code == .EACCES || code == .EPERM { return .denied }
        }
        return .unavailable
    }

    private func set(_ state: State, attempt expected: UUID?) {
        let notify = lock.withLock { () -> (@Sendable (State) -> Void)?? in
            if let expected, attempt != expected { return .none }
            guard route != nil, current != state else { return .none }
            current = state; return .some(observer)
        }
        if case .some(let observer) = notify { observer?(state) }
    }

    private func accept(_ connection: NWConnection, attempt expected: UUID) {
        let accepted = lock.withLock { () -> Bool in
            guard attempt == expected, route != nil, connections.count < maxConnections else { return false }
            connections[ObjectIdentifier(connection)] = connection; return true
        }
        guard accepted else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready: self.screen(connection)
            case .failed, .cancelled: _ = self.lock.withLock { self.connections.removeValue(forKey: ObjectIdentifier(connection)) }
            default: break
            }
        }
        connection.start(queue: queue)
        // Every request ends by this deadline, answered or not.
        queue.asyncAfter(deadline: .now() + requestTimeout) { connection.cancel() }
    }

    /// Answers only connections made to the viewing address. Others close without a reply.
    private func screen(_ connection: NWConnection) {
        guard let route = lock.withLock({ route }), Self.reachesViewingAddress(connection.currentPath?.localEndpoint, route.address) else {
            connection.cancel(); return
        }
        read(connection, buffer: Data())
    }

    static func reachesViewingAddress(_ endpoint: NWEndpoint?, _ address: String) -> Bool {
        guard case .hostPort(let host, _)? = endpoint, let wanted = IPv4Address(address) else { return false }
        switch host {
        case .ipv4(let local): return local.rawValue == wanted.rawValue
        case .ipv6(let local): return local.asIPv4?.rawValue == wanted.rawValue
        default: return false
        }
    }

    /// Reads the header, never more than `headerLimit` bytes in all, however it is split into packets.
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.headerLimit - buffer.count) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var combined = buffer; if let data { combined.append(data) }
            guard Self.headerEnd(in: combined) != nil || combined.count >= Self.headerLimit || complete || error != nil else {
                self.read(connection, buffer: combined); return
            }
            // Check the destination again against the route the reply comes from: the viewing address
            // may have moved while this request was arriving.
            guard let route = self.lock.withLock({ self.route }),
                  Self.reachesViewingAddress(connection.currentPath?.localEndpoint, route.address) else { connection.cancel(); return }
            connection.send(content: Self.reply(to: combined, route: route), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// Where the header ends, looking no further than `headerLimit` bytes.
    static func headerEnd(in request: Data) -> Range<Data.Index>? {
        request.prefix(headerLimit).range(of: Data("\r\n\r\n".utf8))
    }

    /// The whole response for one request. Only `GET /` or `HEAD /` with a known host is redirected.
    /// A header longer than `headerLimit` is refused before any of it is parsed.
    static func reply(to request: Data, route: Route) -> Data {
        guard let split = headerEnd(in: request) else { return response(request.count >= headerLimit ? 431 : 400, body: "") }
        let lines = String(decoding: request[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return response(400, body: "") }
        let method = String(parts[0]), target = String(parts[1])
        guard method == "GET" || method == "HEAD" else { return response(405, body: "", head: false) }
        var host: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "host" else { continue }
            host = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        guard path == "/", let typed = host.flatMap(normalizedHost), Set(route.hosts.compactMap(normalizedHost) + [route.address]).contains(typed) else {
            return response(404, body: "Not found", head: method == "HEAD")
        }
        let location = "http://\(typed):\(route.port)\(route.path)"
        let page = "<!doctype html><meta charset=\"utf-8\"><title>Setbeam</title><a href=\"\(location)\">Continue to Setbeam</a>"
        return response(302, body: page, mime: "text/html; charset=utf-8", location: location, head: method == "HEAD")
    }

    /// A `Host` value without port 80 or a trailing dot, lowercased. Other ports are not this listener.
    static func normalizedHost(_ value: String) -> String? {
        var host = value.lowercased()
        if host.hasSuffix(":80") { host.removeLast(3) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.contains(":"), !host.contains("/"), !host.contains(" ") else { return nil }
        return host
    }

    static func response(_ code: Int, body: String, mime: String = "text/plain; charset=utf-8", location: String? = nil, head: Bool = false) -> Data {
        let phrase = [302: "Found", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 431: "Request Header Fields Too Large"][code] ?? "Error"
        let content = Data(body.utf8)
        var header = "HTTP/1.1 \(code) \(phrase)\r\nContent-Type: \(mime)\r\nContent-Length: \(content.count)\r\n"
        if let location { header += "Location: \(location)\r\n" }
        if code == 405 { header += "Allow: GET, HEAD\r\n" }
        header += "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        return Data(header.utf8) + (head ? Data() : content)
    }

    deinit {
        retry?.cancel(); connections.values.forEach { $0.cancel() }; listener?.cancel()
    }
}
