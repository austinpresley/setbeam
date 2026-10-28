import Foundation
import Network

public struct ViewerSession: Sendable {
    public var token: String
    public var title: String
    public var sample: Bool
    public var state: AudienceState
    public var playback: PlaybackDescriptor
    public var revision: Int
    public var wifiSSID: String
    public init(token: String, title: String, sample: Bool, state: AudienceState, playback: PlaybackDescriptor, revision: Int = 0, wifiSSID: String = "") {
        self.token = token; self.title = title; self.sample = sample; self.state = state; self.playback = playback
        self.revision = revision; self.wifiSSID = wifiSSID
    }
}

public struct ViewerActivity: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let playing: Bool
    public let onThisMac: Bool
    public let revision: Int
    public let lastSeen: Date
    public let number: Int
    public let name: String?
    public let health: ViewerHealth

    public var displayName: String { name ?? "\(label) \(number)" }
}

public enum ViewerHealth: String, Sendable {
    case good, struggling, checking, playing, connecting, reconnecting, paused, background, ready, holding

    static func observed(_ reported: ViewerHealth, playing: Bool, revision: Int, session: ViewerSession?, age: TimeInterval) -> ViewerHealth {
        if session?.state == .holding { return .holding }
        if age >= 8 { return .reconnecting }
        if revision != session?.revision { return .connecting }
        if [.background, .paused, .ready].contains(reported) { return reported }
        guard playing, session?.state == .live else { return reported == .connecting ? .connecting : .reconnecting }
        return [.good, .struggling, .checking].contains(reported) ? reported : .playing
    }

    static func viewerName(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }))
        let words = clean.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let name = String(words.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// A small, authenticated static viewer host. It exposes no media-control proxy or file browsing.
public final class ViewerGateway: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.setbeam.viewer", qos: .userInitiated)
    private let lock = NSLock()
    private let assets: [String: Data]
    private var listener: NWListener?
    /// A stopped listener releases its socket asynchronously; a same-port start waits for it.
    private var stoppedListener: NWListener?
    private var session: ViewerSession?
    private var activity: [String: ViewerActivity] = [:]
    private var nextViewerNumber = 1
    private var running = false
    private var generation = UUID()
    private var listenerAttempt = UUID()
    private var desiredListener: (address: String, port: UInt16)?
    private var retry: DispatchWorkItem?
    private var startup: ListenerStart?
    private let retryDelay: TimeInterval
    private let startupTimeout: TimeInterval
    private let makeListener: (NWParameters, NWEndpoint.Port) throws -> NWListener
    /// Open state streams. Each is an accepted connection held past the request deadline.
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    private var keepaliveScheduled = false
    private let maxStreams: Int
    private let keepaliveInterval: TimeInterval
    private let requestTimeout: TimeInterval

    public convenience init(assets: [String: Data]) {
        self.init(assets: assets, retryDelay: 1, startupTimeout: 5) { try NWListener(using: $0, on: $1) }
    }

    init(assets: [String: Data], retryDelay: TimeInterval, startupTimeout: TimeInterval = 5,
         requestTimeout: TimeInterval = 6, keepaliveInterval: TimeInterval = 10, maxStreams: Int = 64,
         listenerFactory: @escaping (NWParameters, NWEndpoint.Port) throws -> NWListener) {
        self.assets = assets
        self.retryDelay = retryDelay
        self.startupTimeout = startupTimeout
        self.requestTimeout = requestTimeout
        self.keepaliveInterval = keepaliveInterval
        self.maxStreams = maxStreams
        self.makeListener = listenerFactory
    }
    public func update(_ session: ViewerSession) {
        let (closed, changed) = lock.withLock { () -> ([NWConnection], Bool) in
            let previous = self.session
            self.session = session
            // A new token is a new viewing link. Readers of the old link must reconnect and get 404.
            if previous?.token != session.token {
                activity.removeAll()
                nextViewerNumber = 1
                let closed = Array(streams.values); streams.removeAll()
                return (closed, false)
            }
            return ([], previous.map { Self.stateObject($0) as NSDictionary != Self.stateObject(session) as NSDictionary } ?? true)
        }
        closed.forEach { $0.cancel() }
        if changed { broadcast(session) }
    }
    public var viewers: [ViewerActivity] {
        lock.lock(); defer { lock.unlock() }
        activity = activity.filter { Date().timeIntervalSince($0.value.lastSeen) < 12 }
        return activity.values.map { item in
            let age = Date().timeIntervalSince(item.lastSeen)
            return ViewerActivity(id: item.id, label: item.label, playing: item.playing && item.revision == session?.revision && session?.state == .live && age < 8, onThisMac: item.onThisMac, revision: item.revision, lastSeen: item.lastSeen,
                number: item.number, name: item.name, health: ViewerHealth.observed(item.health, playing: item.playing, revision: item.revision, session: session, age: age))
        }.sorted { $0.number < $1.number }
    }
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Requests this address until stop or another start. A bounded startup error still leaves
    /// recovery enabled; callers abandoning the sharing request must call stop.
    public func start(address: String, port: UInt16 = 0) async throws -> UInt16 {
        return try await withCheckedThrowingContinuation { continuation in
            let completion = ListenerStart(continuation)
            let current = UUID()
            let previous = lock.withLock {
                let previous = (listener ?? stoppedListener, retry, startup)
                generation = current; listenerAttempt = UUID(); stoppedListener = nil
                desiredListener = (address, port); listener = nil; retry = nil
                startup = completion; running = false
                return previous
            }
            previous.1?.cancel()
            previous.2?.finish(.failure(SetbeamError.unavailable("Viewer server was replaced.")))
            let previousListener = previous.0
            previousListener?.cancel()
            queue.async { [weak self] in
                self?.beginListener(generation: current, waitingFor: previousListener, until: .now() + 1)
            }
            queue.asyncAfter(deadline: .now() + startupTimeout) { [weak self] in
                self?.startupExpired(generation: current)
            }
        }
    }
    public func stop() {
        let previous = lock.withLock {
            let previous = (listener, retry, startup, Array(streams.values))
            generation = UUID(); listenerAttempt = UUID(); desiredListener = nil
            stoppedListener = listener; listener = nil; retry = nil; startup = nil
            running = false; activity.removeAll(); nextViewerNumber = 1; streams.removeAll()
            return previous
        }
        previous.3.forEach { $0.cancel() }
        previous.1?.cancel()
        previous.2?.finish(.failure(SetbeamError.unavailable("Viewer server stopped before it was ready.")))
        previous.0?.cancel()
    }

    private func beginListener(generation current: UUID, waitingFor previous: NWListener? = nil,
                               until cancellationDeadline: DispatchTime = .now()) {
        guard lock.withLock({ generation == current && desiredListener != nil }) else { return }
        // Network releases a cancelled listener's socket on its own queue. Give a replacement
        // a bounded wait so an explicit same-port restart does not race that release.
        if let previous, case .cancelled = previous.state { }
        else if previous != nil, .now() < cancellationDeadline {
            queue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.beginListener(generation: current, waitingFor: previous, until: cancellationDeadline)
            }
            return
        }
        guard let desired = lock.withLock({ generation == current ? desiredListener : nil }) else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: .init(desired.address), port: .any)
            let listener = try makeListener(parameters, NWEndpoint.Port(rawValue: desired.port)!)
            let attempt = UUID()
            let accepted = lock.withLock {
                guard generation == current, desiredListener != nil else { return false }
                self.listener = listener; listenerAttempt = attempt; retry = nil
                return true
            }
            guard accepted else { listener.cancel(); return }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                self.listenerChanged(state, listener: listener, generation: current, attempt: attempt)
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.lock.withLock({ self.generation == current && self.listenerAttempt == attempt && self.desiredListener != nil }) else {
                    connection.cancel(); return
                }
                self.accept(connection)
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + startupTimeout) { [weak self] in
                self?.retryUnreadyListener(generation: current, attempt: attempt)
            }
        } catch {
            let completion = lock.withLock {
                guard generation == current else { return nil as ListenerStart? }
                let completion = startup; startup = nil; running = false
                return completion
            }
            completion?.finish(.failure(error))
            scheduleRetry(generation: current)
        }
    }

    private func listenerChanged(_ state: NWListener.State, listener: NWListener,
                                 generation current: UUID, attempt: UUID) {
        guard lock.withLock({ generation == current && listenerAttempt == attempt && desiredListener != nil }) else { return }
        switch state {
        case .ready:
            let completion = lock.withLock {
                guard generation == current, listenerAttempt == attempt, desiredListener != nil else { return nil as ListenerStart? }
                running = true
                // Port zero chooses once. Recovery must not change an already-issued viewing link.
                if let port = listener.port?.rawValue { desiredListener?.port = port }
                let completion = startup; startup = nil
                return completion
            }
            completion?.finish(.success(listener.port?.rawValue ?? 0))
        case .failed(let error):
            retireListener(generation: current, attempt: attempt, error: error)
        case .cancelled:
            retireListener(generation: current, attempt: attempt,
                           error: SetbeamError.unavailable("Viewer server stopped before it was ready."))
        case .waiting:
            let waitingAfterStartup = lock.withLock {
                guard generation == current, listenerAttempt == attempt else { return false }
                running = false
                return startup == nil
            }
            if waitingAfterStartup {
                queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                    self?.retryUnreadyListener(generation: current, attempt: attempt)
                }
            }
        default: break
        }
    }

    private func startupExpired(generation current: UUID) {
        let pending = lock.withLock {
            guard generation == current, startup != nil else { return nil as UUID? }
            return listenerAttempt
        }
        if let pending { retryUnreadyListener(generation: current, attempt: pending) }
    }

    private func retryUnreadyListener(generation current: UUID, attempt: UUID) {
        guard lock.withLock({ generation == current && listenerAttempt == attempt && !running && desiredListener != nil }) else { return }
        retireListener(generation: current, attempt: attempt,
                       error: SetbeamError.unavailable("The viewing network is not ready. Setbeam will retry."))
    }

    private func retireListener(generation current: UUID, attempt: UUID, error: Error) {
        let previous = lock.withLock {
            guard generation == current, listenerAttempt == attempt, desiredListener != nil else { return nil as (NWListener?, ListenerStart?)? }
            let previous = (listener, startup)
            listener = nil; startup = nil; running = false; listenerAttempt = UUID()
            return previous
        }
        guard let previous else { return }
        previous.1?.finish(.failure(error))
        previous.0?.cancel()
        scheduleRetry(generation: current, waitingFor: previous.0)
    }

    private func scheduleRetry(generation current: UUID, waitingFor previous: NWListener? = nil) {
        let work = DispatchWorkItem { [weak self] in
            self?.beginListener(generation: current, waitingFor: previous, until: .now() + 1)
        }
        let accepted = lock.withLock {
            guard generation == current, desiredListener != nil else { return false }
            retry?.cancel(); retry = work
            return true
        }
        if accepted { queue.asyncAfter(deadline: .now() + retryDelay, execute: work) }
    }
    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Ordinary requests must finish within the deadline. Only an opened state stream outlives it.
        queue.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            if self?.isStreaming(connection) != true { connection.cancel() }
        }
        receive(connection, buffer: Data())
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var combined = buffer; if let data { combined.append(data) }
            guard combined.count <= 65_536 else { self.send(connection, code: 413, mime: "text/plain", body: Data("Request too large".utf8)); return }
            guard let split = combined.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete && error == nil { self.receive(connection, buffer: combined) } else { connection.cancel() }
                return
            }
            let header = String(decoding: combined[..<split.lowerBound], as: UTF8.self)
            let lines = header.components(separatedBy: "\r\n")
            guard let first = lines.first else { connection.cancel(); return }
            let request = first.split(separator: " ")
            guard request.count == 3, ["GET", "POST"].contains(String(request[0])), request[1].count < 2048 else { self.send(connection, code: 400, mime: "text/plain", body: Data()); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil else { self.send(connection, code: 400, mime: "text/plain", body: Data()); return }
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard (0...2048).contains(length) else { self.send(connection, code: 413, mime: "text/plain", body: Data()); return }
            let body = combined[split.upperBound...]
            if body.count < length && !complete && error == nil { self.receive(connection, buffer: combined); return }
            guard body.count >= length else { self.send(connection, code: 400, mime: "text/plain", body: Data()); return }
            let rawPath = String(request[1]).components(separatedBy: "?")[0]
            self.respond(connection, method: String(request[0]), path: rawPath, body: Data(body.prefix(length)))
        }
    }
    private func respond(_ connection: NWConnection, method: String, path: String, body: Data) {
        lock.lock(); let current = session; lock.unlock()
        guard let current else { unavailable(connection, method: method, path: path); return }
        let prefix = "/s/\(current.token)/"
        guard path.hasPrefix(prefix) else { unavailable(connection, method: method, path: path); return }
        let suffix = String(path.dropFirst(prefix.count))
        if suffix == "heartbeat", method == "POST" {
            if let data = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let id = data["id"] as? String, (8...64).contains(id.count), id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) {
                let label = (data["mobile"] as? Bool ?? false) ? "Phone / tablet browser" : "Desktop browser"
                let host: String
                if case .hostPort(let endpoint, _) = connection.endpoint { host = String(describing: endpoint) }
                else { host = "" }
                let local = host == "127.0.0.1" || host == "::1" || NetworkAddress.available().contains { $0.address == host }
                lock.lock()
                if session?.token == current.token, activity.count < 64 || activity[id] != nil {
                    let number = activity[id]?.number ?? nextViewerNumber
                    if activity[id] == nil { nextViewerNumber += 1 }
                    activity[id] = ViewerActivity(id: id, label: label, playing: data["playing"] as? Bool ?? false, onThisMac: local, revision: data["revision"] as? Int ?? -1, lastSeen: Date(),
                        number: number, name: ViewerHealth.viewerName(data["name"] as? String), health: (data["health"] as? String).flatMap(ViewerHealth.init(rawValue:)) ?? .playing)
                }
                lock.unlock()
            }
            sendJSON(connection, ["ok": true]); return
        }
        guard method == "GET" else { send(connection, code: 405, mime: "text/plain", body: Data()); return }
        if suffix == "config.json" {
            sendJSON(connection, ["title": current.title, "sample": current.sample,
                "whepURL": current.playback.whepURL, "user": current.playback.user, "pass": current.playback.password]); return
        }
        if suffix == "state.json" { sendJSON(connection, Self.stateObject(current)); return }
        if suffix == "events" { openStream(connection, session: current); return }
        let file = suffix.isEmpty ? "viewer.html" : suffix
        guard let data = assets[file], ["viewer.html", "viewer.js", "viewer.css", "reader.js", "keepawake.js"].contains(file) else { send(connection, code: 404, mime: "text/plain", body: Data()); return }
        let mime = file.hasSuffix(".html") ? "text/html; charset=utf-8" : file.hasSuffix(".css") ? "text/css; charset=utf-8" : "text/javascript; charset=utf-8"
        send(connection, code: 200, mime: mime, body: data)
    }
    private func unavailable(_ connection: NWConnection, method: String, path: String) {
        if method == "GET", path.hasPrefix("/s/"), path.hasSuffix("/") || path.hasSuffix("/viewer.html"),
           let page = assets["expired.html"] {
            send(connection, code: 404, mime: "text/html; charset=utf-8", body: page)
        } else {
            send(connection, code: 404, mime: "text/plain", body: Data("Session unavailable".utf8))
        }
    }
    private func sendJSON(_ connection: NWConnection, _ object: [String: Any]) {
        send(connection, code: 200, mime: "application/json", body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
    }
    private func send(_ connection: NWConnection, code: Int, mime: String, body: Data) {
        let phrase = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 503: "Service Unavailable"][code] ?? "Error"
        let header = "HTTP/1.1 \(code) \(phrase)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
    private static func stateObject(_ session: ViewerSession) -> [String: Any] {
        ["state": session.state.rawValue, "title": session.title, "sample": session.sample,
         "revision": session.revision, "wifiSSID": session.wifiSSID]
    }
    private static func event(_ session: ViewerSession) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: stateObject(session))) ?? Data("{}".utf8)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    /// Server-sent events carry the same JSON as state.json: once on open, on every change, and as a keepalive.
    private func openStream(_ connection: NWConnection, session current: ViewerSession) {
        let accepted = lock.withLock { () -> Bool in
            guard self.session?.token == current.token, streams.count < maxStreams else { return false }
            streams[ObjectIdentifier(connection)] = connection
            return true
        }
        guard accepted else { send(connection, code: 503, mime: "text/plain", body: Data()); return }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n\r\nretry: 3000\n\n"
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state { case .failed, .cancelled: self?.closeStream(connection); default: break }
        }
        push(Data(header.utf8) + Self.event(current), to: connection)
        watchForClose(connection)
        scheduleKeepalive()
    }
    /// A viewer sends nothing after its request, so any completed read means the browser went away.
    private func watchForClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, complete, error in
            if complete || error != nil { self?.closeStream(connection) } else { self?.watchForClose(connection) }
        }
    }
    private func isStreaming(_ connection: NWConnection) -> Bool {
        lock.withLock { streams[ObjectIdentifier(connection)] != nil }
    }
    private func closeStream(_ connection: NWConnection) {
        let removed = lock.withLock { streams.removeValue(forKey: ObjectIdentifier(connection)) != nil }
        if removed { connection.cancel() }
    }
    private func push(_ data: Data, to connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.closeStream(connection) }
        })
    }
    private func broadcast(_ session: ViewerSession) {
        let event = Self.event(session)
        let targets = lock.withLock { Array(streams.values) }
        queue.async { [weak self] in targets.forEach { self?.push(event, to: $0) } }
    }
    private func scheduleKeepalive() {
        let schedule = lock.withLock { () -> Bool in
            guard !keepaliveScheduled, !streams.isEmpty else { return false }
            keepaliveScheduled = true; return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + keepaliveInterval) { [weak self] in
            guard let self else { return }
            let current = self.lock.withLock { () -> ViewerSession? in
                self.keepaliveScheduled = false
                return self.streams.isEmpty ? nil : self.session
            }
            guard let current else { return }
            self.broadcast(current)
            self.scheduleKeepalive()
        }
    }
    deinit {
        streams.values.forEach { $0.cancel() }
        retry?.cancel()
        startup?.finish(.failure(SetbeamError.unavailable("Viewer server stopped before it was ready.")))
        listener?.cancel()
    }
}

private final class ListenerStart: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<UInt16, Error>) -> Bool {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }
}
