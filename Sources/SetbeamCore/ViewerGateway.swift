import Foundation
import Network

public struct ViewerSession: Equatable, Sendable {
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
    public var admission: ViewerAdmission = .admitted
    public var color: PointerColor = .blue
    public var joinedAt: Date = .distantPast
    /// Asked to join from the short address rather than the viewing link.
    public var shortAddress = false
    /// No recent heartbeat. Under approval this session still has media access and can be removed.
    public var updatesMissing = false
    /// Shares a named pointer with other participants.
    public var pointing = false
    public var mobile = false
    public var admittedAt: Date? = nil
    public var playbackUpdatedAt: Date? = nil
    public var measurements: ViewerMeasurements? = nil

    var ledgerIdentity: UUID? = nil

    public var displayName: String { name ?? "\(label) \(number)" }
}

public enum ViewerHealth: String, Sendable {
    case good, struggling, checking, playing, connecting, reconnecting, paused, background, ready, holding

    static let freshFor: TimeInterval = 8

    var canShowMeasurements: Bool {
        [.good, .struggling, .checking, .playing].contains(self)
    }

    static func observed(_ reported: ViewerHealth, playing: Bool, revision: Int, session: ViewerSession?, age: TimeInterval) -> ViewerHealth {
        if session?.state == .holding { return .holding }
        if age >= freshFor { return .reconnecting }
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
    let queue = DispatchQueue(label: "app.setbeam.viewer", qos: .userInitiated)
    let lock = NSLock()
    private let assets: [String: Data]
    private var listener: NWListener?
    /// A stopped listener releases its socket asynchronously; a same-port start waits for it.
    private var stoppedListener: NWListener?
    var session: ViewerSession?
    var ledger = ViewerAccessLedger()
    /// The ask-only short-address path code. It is never the viewing link's code, which is also the
    /// shared media read credential, and it changes with every new link and at Stop.
    private var shortAddressCode = ViewerAccessLedger.randomSecret(bytes: 32)
    var presence = PointerPresence(revision: 0)
    var pointersEnabled = false
    var chat = SessionChat()
    var chatFramesAllowed = false
    /// Open presence channels, at most one per participant once identified.
    var presenceClients: [ObjectIdentifier: PresenceClient] = [:]
    var presenceFlushScheduled = false
    var presenceMaintenanceScheduled = false
    var presenceExpiry: DispatchWorkItem?
    var notifiedPointers: [SharedPointer] = []
    var notifiedAt = Date.distantPast
    let maxPresenceClients: Int
    /// Receives the participants' current pointers for native monitoring, on the gateway queue.
    public var onPointers: (@Sendable ([SharedPointer]) -> Void)? {
        get { lock.withLock { pointerObserver } }
        set { lock.withLock { pointerObserver = newValue } }
    }
    var pointerObserver: (@Sendable ([SharedPointer]) -> Void)?
    private var running = false
    private var sequence = 0
    /// Connections are budgeted as ordinary HTTP until upgraded under the lock.
    private struct Request {
        let connection: NWConnection
        let deadline: DispatchTime
    }
    private var requests: [ObjectIdentifier: Request] = [:]
    var ordinaryConnectionCount: Int { lock.withLock { requests.count } }
    private var maintenanceScheduled = false
    private let maxRequests: Int
    private let streamSendTimeout: TimeInterval
    private var generation = UUID()
    private var listenerAttempt = UUID()
    private var desiredListener: (address: String, port: UInt16)?
    private var retry: DispatchWorkItem?
    private var startup: ListenerStart?
    private let retryDelay: TimeInterval
    private let startupTimeout: TimeInterval
    private let makeListener: (NWParameters, NWEndpoint.Port) throws -> NWListener
    /// Open state streams. Each is an accepted connection held past the request deadline.
    var streams: [ObjectIdentifier: ViewerStateStream] = [:]
    private var keepaliveScheduled = false
    private let maxStreams: Int
    private let keepaliveInterval: TimeInterval
    private let requestTimeout: TimeInterval

    public convenience init(assets: [String: Data]) {
        self.init(assets: assets, retryDelay: 1, startupTimeout: 5) { try NWListener(using: $0, on: $1) }
    }

    init(assets: [String: Data], retryDelay: TimeInterval, startupTimeout: TimeInterval = 5,
         requestTimeout: TimeInterval = 6, keepaliveInterval: TimeInterval = 10, maxStreams: Int = 64, maxPresenceClients: Int = 24,
         maxRequests: Int = 64, streamSendTimeout: TimeInterval = 5,
         listenerFactory: @escaping (NWParameters, NWEndpoint.Port) throws -> NWListener) {
        self.maxRequests = maxRequests
        self.streamSendTimeout = streamSendTimeout
        self.maxPresenceClients = maxPresenceClients
        self.assets = assets
        self.retryDelay = retryDelay
        self.startupTimeout = startupTimeout
        self.requestTimeout = requestTimeout
        self.keepaliveInterval = keepaliveInterval
        self.maxStreams = maxStreams
        self.makeListener = listenerFactory
    }
    public func update(_ session: ViewerSession) {
        let closed = lock.withLock { () -> [NWConnection] in
            let previous = self.session
            self.session = session
            // A new token is a new viewing link. Readers of the old link must reconnect and get 404.
            if previous?.token != session.token {
                chat.reset(); chatFramesAllowed = false
                ledger.reset(); shortAddressCode = ViewerAccessLedger.randomSecret(bytes: 32)
                presence.removeAll(revision: session.revision)
                sequence = 0
                let closed = streams.values.map(\.connection) + presenceClients.values.map(\.connection)
                streams.removeAll(); presenceClients.removeAll()
                return closed
            }
            // Positions belong to one live picture. Hold, Stop, and every publisher revision clear them.
            if previous?.revision != session.revision || previous?.state != session.state {
                presence.reset(revision: session.revision)
                ledger.clearMeasurements()
            }
            if previous?.revision != session.revision || session.state != .live { chatFramesAllowed = false }
            if session.state == .stopped { chat.reset() }
            if previous != session { publishStateLocked() }
            return []
        }
        closed.forEach { $0.cancel() }
        schedulePresenceFlush()
    }

    /// Session options for joining and shared pointers. They never grant publishing or administration.
    public func setAccess(approval: Bool, pointers: Bool) {
        let closed = lock.withLock { () -> [NWConnection] in
            let changed = approval != ledger.approvalRequired || pointers != pointersEnabled
            ledger.setApproval(approval); pointersEnabled = pointers
            var closed: [NWConnection] = []
            if !pointers {
                closed = presenceClients.values.map(\.connection); presenceClients.removeAll()
                presence.removeAll(revision: session?.revision ?? 0)
            }
            if changed { publishStateLocked() }
            return closed
        }
        closed.forEach { $0.cancel() }
        schedulePresenceFlush()
    }
    public var approvalRequired: Bool { lock.withLock { ledger.approvalRequired } }

    /// Opens the short address for new requests while approval is on. Closing it declines its waiting
    /// requests; admitted sessions continue. It never opens without approval.
    public func setShortAddress(open: Bool) { lock.withLock { ledger.setShortAddress(open: open) } }
    public struct Binding: Equatable, Sendable {
        public let id: UUID
        public let address: String
        public let port: UInt16
        public let shortAddressPath: String?
    }

    /// A single snapshot for redirects and discovery. Re-read after a listener or link change.
    public var readyBinding: Binding? {
        lock.withLock {
            guard running, let desiredListener, desiredListener.port != 0 else { return nil }
            let path = ledger.shortAddressOpen && session != nil && session?.state != .stopped
                ? "/s/\(shortAddressCode)/" : nil
            return Binding(id: listenerAttempt, address: desiredListener.address, port: desiredListener.port, shortAddressPath: path)
        }
    }
    public var shortAddressPath: String? { readyBinding?.shortAddressPath }

    /// Readers the media server must accept for admitted sessions under approval.
    public var desiredReaders: Set<ViewerReader> { lock.withLock { ledger.readers } }
    /// Called after the media server has accepted these readers. Only then can admitted pages
    /// obtain their own playback credential.
    public func confirm(readers: Set<ViewerReader>) { lock.withLock { _ = ledger.confirm(readers: readers) } }

    @discardableResult public func approve(number: Int) -> Bool { lock.withLock { ledger.approve(number: number) } }
    @discardableResult public func decline(number: Int) -> Bool { lock.withLock { ledger.decline(number: number) } }
    /// Compare the original roster row and decide under the same lock.
    @discardableResult public func approve(_ viewer: ViewerActivity) -> Bool {
        lock.withLock { ledger.matches(viewer) && ledger.approve(number: viewer.number) }
    }
    @discardableResult public func decline(_ viewer: ViewerActivity) -> Bool {
        lock.withLock { ledger.matches(viewer) && ledger.decline(number: viewer.number) }
    }
    /// Ends this session's access to playback and presence at once. The caller revokes its reader.
    @discardableResult public func remove(_ viewer: ViewerActivity) -> Bool {
        remove(number: viewer.number, matching: viewer)
    }
    @discardableResult public func remove(number: Int) -> Bool { remove(number: number, matching: nil) }

    private func remove(number: Int, matching viewer: ViewerActivity?) -> Bool {
        let removed = lock.withLock {
            if let viewer, !ledger.matches(viewer) { return false }
            guard ledger.remove(number: number) else { return false }
            retireUnauthorizedPresenceLocked()
            return true
        }
        if removed { schedulePresenceFlush() }
        return removed
    }
    public var viewers: [ViewerActivity] {
        lock.lock(); defer { lock.unlock() }
        let participants = presence.participants
        return ledger.activity(session: session, now: Date()).map { item in
            var item = item; item.pointing = participants.contains(item.number); return item
        }
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
                closeConnectionsLocked()
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
            let previous = (listener, retry, startup)
            generation = UUID(); listenerAttempt = UUID(); desiredListener = nil
            stoppedListener = listener; listener = nil; retry = nil; startup = nil
            running = false; ledger.reset(); chat.reset(); chatFramesAllowed = false
            closeConnectionsLocked()
            shortAddressCode = ViewerAccessLedger.randomSecret(bytes: 32)
            return previous
        }
        schedulePresenceFlush()
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
                guard let self else { connection.cancel(); return }
                self.accept(connection, generation: current, attempt: attempt)
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
            closeConnectionsLocked()
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
    /// The caller holds the lock. Listener replacement invalidates accepted sockets as well.
    private func closeConnectionsLocked() {
        let hadPresence = !presenceClients.isEmpty
        let closed = requests.values.map(\.connection) + streams.values.map(\.connection) + presenceClients.values.map(\.connection)
        requests.removeAll(); streams.removeAll(); presenceClients.removeAll()
        if session != nil { sequence += 1 }
        presence.removeAll(revision: session?.revision ?? 0)
        if hadPresence { schedulePresenceFlushLocked() }
        closed.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection, generation current: UUID, attempt: UUID) {
        let accepted = lock.withLock {
            guard generation == current, listenerAttempt == attempt, running, requests.count < maxRequests else { return false }
            requests[ObjectIdentifier(connection)] = Request(connection: connection, deadline: .now() + requestTimeout)
            scheduleMaintenanceLocked()
            return true
        }
        guard accepted else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state { case .failed, .cancelled: self?.finishRequest(connection); default: break }
        }
        connection.start(queue: queue)
        receiveHeader(connection)
    }

    func requestActiveLocked(_ connection: NWConnection) -> Bool {
        requests[ObjectIdentifier(connection)].map { $0.deadline > .now() } == true
    }

    func upgradeRequestLocked(_ connection: NWConnection) -> Bool {
        guard requestActiveLocked(connection) else { return false }
        requests.removeValue(forKey: ObjectIdentifier(connection))
        return true
    }

    private func finishRequest(_ connection: NWConnection) {
        lock.withLock { _ = requests.removeValue(forKey: ObjectIdentifier(connection)) }
        connection.cancel()
    }

    private func scheduleMaintenanceLocked() {
        guard !maintenanceScheduled else { return }
        maintenanceScheduled = true
        queue.asyncAfter(deadline: .now() + min(0.25, requestTimeout, streamSendTimeout)) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                self.maintenanceScheduled = false
                let now = DispatchTime.now()
                for (id, request) in self.requests where request.deadline <= now {
                    self.requests.removeValue(forKey: id)
                    request.connection.cancel()
                }
                for (id, stream) in self.streams where stream.deadline.map({ $0 <= now }) == true {
                    self.streams.removeValue(forKey: id)
                    stream.connection.cancel()
                }
                if !self.requests.isEmpty || self.streams.values.contains(where: { $0.deadline != nil }) {
                    self.scheduleMaintenanceLocked()
                }
            }
        }
    }

    private static let headerLimit = 8192
    private static let headerEnd = Data("\r\n\r\n".utf8)

    private func receiveHeader(_ connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.headerLimit + Self.headerEnd.count - buffer.count) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            guard self.lock.withLock({ self.requestActiveLocked(connection) }) else { self.finishRequest(connection); return }
            var combined = buffer
            if let data { combined.append(data) }
            guard let split = combined.range(of: Self.headerEnd) else {
                if combined.count == Self.headerLimit + Self.headerEnd.count {
                    self.send(connection, code: 413, mime: "text/plain", body: Data())
                } else if complete || error != nil { self.finishRequest(connection) }
                else { self.receiveHeader(connection, buffer: combined) }
                return
            }
            let lines = String(decoding: combined[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let request = lines[0].split(separator: " ")
            guard request.count == 3, ["GET", "POST"].contains(String(request[0])), request[1].utf8.count < 2048 else {
                self.send(connection, code: 400, mime: "text/plain", body: Data()); return
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let field = line[..<colon].lowercased()
                if field == "content-length", headers[field] != nil {
                    self.send(connection, code: 400, mime: "text/plain", body: Data()); return
                }
                headers[field] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil else {
                self.send(connection, code: 400, mime: "text/plain", body: Data()); return
            }
            let length = Int(headers["content-length"] ?? "0") ?? -1
            let path = String(request[1]).components(separatedBy: "?")[0]
            let method = String(request[0])
            let chatBody = method == "POST" && self.lock.withLock {
                self.session.map { path == "/s/\($0.token)/chat" } == true || path == "/s/\(self.shortAddressCode)/chat"
            }
            guard (0...(chatBody ? 196_608 : 2048)).contains(length) else {
                self.send(connection, code: 413, mime: "text/plain", body: Data()); return
            }
            let parsedHeaders = headers
            let body = Data(combined[split.upperBound...])
            if body.count >= length {
                self.respond(connection, method: method, path: path, headers: parsedHeaders,
                             body: Data(body.prefix(length)), extra: Data(body.dropFirst(length)))
            } else if complete || error != nil {
                self.send(connection, code: 400, mime: "text/plain", body: Data())
            } else {
                self.receiveBody(connection, remaining: length - body.count, buffer: body) { [weak self] body in
                    self?.respond(connection, method: method, path: path, headers: parsedHeaders, body: body, extra: Data())
                }
            }
        }
    }

    private func receiveBody(_ connection: NWConnection, remaining: Int, buffer: Data, completion: @escaping @Sendable (Data) -> Void) {
        connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            guard self.lock.withLock({ self.requestActiveLocked(connection) }) else { self.finishRequest(connection); return }
            guard let data, data.count == remaining else {
                self.send(connection, code: 400, mime: "text/plain", body: Data()); return
            }
            completion(buffer + data)
        }
    }

    private func respond(_ connection: NWConnection, method: String, path: String, headers: [String: String], body: Data, extra: Data) {
        let (current, shortPrefix) = lock.withLock {
            (requestActiveLocked(connection) ? session : nil, "/s/\(shortAddressCode)/")
        }
        guard let current else { unavailable(connection, method: method, path: path); return }
        // The viewing link, or the short address's ask-only path. Both reach the same pass-based
        // admission; only the link's code is a media credential.
        let prefix = "/s/\(current.token)/"
        let shortAddress = !path.hasPrefix(prefix) && path.hasPrefix(shortPrefix)
        guard path.hasPrefix(prefix) || shortAddress else { unavailable(connection, method: method, path: path); return }
        let suffix = String(path.dropFirst(shortAddress ? shortPrefix.count : prefix.count))
        if suffix == "chat" || suffix.hasPrefix("chat/frame/") {
            respondChat(connection, method: method, suffix: suffix, headers: headers, body: body, token: current.token); return
        }
        if method == "POST", suffix == "join" || suffix == "heartbeat" {
            guard let data = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                send(connection, code: 400, mime: "text/plain", body: Data()); return
            }
            let local = isLocal(connection), mobile = data["mobile"] as? Bool ?? false
            if suffix == "join" { join(connection, data, token: current.token, local: local, mobile: mobile, shortAddress: shortAddress); return }
            // Only a gateway-issued pass identifies a session. Unknown passes must join again.
            guard let pass = ViewerAccessLedger.validPass(data["pass"]) else { sendJSON(connection, ["ok": false, "admission": "unknown"]); return }
            let name: String?? = data.keys.contains("name") ? .some(ViewerHealth.viewerName(data["name"] as? String)) : .none
            let health = (data["health"] as? String).flatMap(ViewerHealth.init(rawValue:)) ?? .playing
            let revision = data["revision"] as? Int ?? -1
            let playing = data["playing"] as? Bool ?? false
            let response = lock.withLock { () -> [String: Any] in
                guard requestActiveLocked(connection), let session, session.token == current.token else {
                    return ["ok": false, "admission": "unknown"]
                }
                let now = Date()
                let measurements = playing && health.canShowMeasurements && revision == session.revision && session.state == .live
                    ? ViewerMeasurements(json: data["measurements"], receivedAt: now) : nil
                let record = ledger.heartbeat(pass, playing: playing, health: health, revision: revision, name: name,
                    color: PointerColor.validated(data["color"]), mobile: mobile, local: local, now: now, measurements: measurements)
                var response: [String: Any] = ["ok": record != nil, "admission": record?.admission.rawValue ?? "unknown"]
                if record?.admission == .admitted { response["chatLastID"] = chat.lastMessageID }
                return response
            }
            sendJSON(connection, response); return
        }
        if suffix == "presence", method == "GET" { openPresence(connection, headers: headers, token: current.token, extra: extra); return }
        guard method == "GET" else { send(connection, code: 405, mime: "text/plain", body: Data()); return }
        if suffix == "config.json" {
            let pass = ViewerAccessLedger.validPass(headers["x-setbeam-pass"])
            let config = lock.withLock { () -> (Int, [String: Any])? in
                guard requestActiveLocked(connection), let session, session.token == current.token else { return nil }
                // Read the admission, credential, and playback generation together.
                let record = pass.flatMap { ledger.record($0, now: Date()) }
                guard let record, record.admission == .admitted else {
                    return (403, ["admission": record?.admission.rawValue ?? "unknown"])
                }
                guard record.mediaReady else { return (503, [:]) }
                return (200, ["title": session.title, "sample": session.sample, "whepURL": session.playback.whepURL,
                    "user": record.reader?.user ?? session.playback.user, "pass": record.reader?.password ?? session.playback.password,
                    "revision": session.revision, "sequence": sequence])
            }
            if let (status, value) = config {
                if status == 503 { send(connection, code: status, mime: "text/plain", body: Data()) }
                else { sendJSON(connection, value, code: status) }
            } else { unavailable(connection, method: method, path: path) }
            return
        }
        if suffix == "state.json" {
            let state = lock.withLock { () -> [String: Any]? in
                guard requestActiveLocked(connection), let session, session.token == current.token else { return nil }
                return stateLocked(session)
            }
            if let state { sendJSON(connection, state) }
            else { unavailable(connection, method: method, path: path) }
            return
        }
        if suffix == "events" { openStream(connection, token: current.token); return }
        let file = suffix.isEmpty ? "viewer.html" : suffix
        guard let data = assets[file], Self.publicAssets.contains(file) else { send(connection, code: 404, mime: "text/plain", body: Data()); return }
        let mime = file.hasSuffix(".html") ? "text/html; charset=utf-8" : file.hasSuffix(".css") ? "text/css; charset=utf-8" : "text/javascript; charset=utf-8"
        send(connection, code: 200, mime: mime, body: data)
    }
    static let publicAssets: Set<String> = ["viewer.html", "viewer.js", "viewer.css", "reader.js", "keepawake.js", "pointers.js", "chat.js"]

    private func isLocal(_ connection: NWConnection) -> Bool {
        let host: String
        if case .hostPort(let endpoint, _) = connection.endpoint { host = String(describing: endpoint) } else { host = "" }
        return host == "127.0.0.1" || host == "::1" || NetworkAddress.available().contains { $0.address == host }
    }

    /// Issues or resumes a browser session. The response carries only that session's own status.
    private func join(_ connection: NWConnection, _ data: [String: Any], token: String, local: Bool, mobile: Bool, shortAddress: Bool) {
        let requestID = (data["requestID"] as? String).flatMap(UUID.init(uuidString:))
        let asking = (data["ask"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } == true
        let outcome = lock.withLock { () -> ViewerAccessLedger.JoinOutcome? in
            guard requestActiveLocked(connection), let session, session.token == token else { return nil }
            // A closed short path can still resume a known pass, but cannot create a record.
            let pass = ViewerAccessLedger.validPass(data["pass"])
            if shortAddress, !running || session.state == .stopped {
                return .closed
            }
            let outcome = ledger.join(pass: pass, name: ViewerHealth.viewerName(data["name"] as? String),
                                      asking: asking, color: PointerColor.validated(data["color"]),
                                      mobile: mobile, local: local, shortAddress: shortAddress, requestID: requestID, now: Date())
            retireUnauthorizedPresenceLocked()
            return outcome
        }
        switch outcome {
        case .joined(let record)?:
            var value: [String: Any] = ["pass": record.pass, "number": record.number, "admission": record.admission.rawValue,
                                        "ready": record.mediaReady, "color": record.color.rawValue]
            value["name"] = record.name
            sendJSON(connection, value)
        case .nameRequired?: send(connection, code: 400, mime: "application/json", body: Data(#"{"error":"name"}"#.utf8))
        case .full?: send(connection, code: 503, mime: "application/json", body: Data(#"{"error":"full"}"#.utf8))
        // A closed short address takes no new requests; the page shows the link as no longer active.
        case .closed?, nil: unavailable(connection, method: "POST", path: "")
        }
    }
    private func unavailable(_ connection: NWConnection, method: String, path: String) {
        if method == "GET", path.hasPrefix("/s/"), path.hasSuffix("/") || path.hasSuffix("/viewer.html"),
           let page = assets["expired.html"] {
            send(connection, code: 404, mime: "text/html; charset=utf-8", body: page)
        } else {
            send(connection, code: 404, mime: "text/plain", body: Data("Session unavailable".utf8))
        }
    }
    func sendJSON(_ connection: NWConnection, _ object: [String: Any], code: Int = 200) {
        send(connection, code: code, mime: "application/json", body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
    }
    func send(_ connection: NWConnection, code: Int, mime: String, body: Data) {
        let phrase = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 503: "Service Unavailable"][code] ?? "Error"
        let header = "HTTP/1.1 \(code) \(phrase)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        lock.withLock {
            guard requestActiveLocked(connection) else { connection.cancel(); return }
            connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in
                if let self { self.finishRequest(connection) } else { connection.cancel() }
            })
        }
    }
    /// Public session state. It names no viewers; the caller holds the lock.
    private func stateLocked(_ session: ViewerSession) -> [String: Any] {
        ["state": session.state.rawValue, "title": session.title, "sample": session.sample,
         "revision": session.revision, "sequence": sequence, "wifiSSID": session.wifiSSID,
         "approval": ledger.approvalRequired, "pointers": pointersEnabled]
    }

    private func stateEventLocked(_ session: ViewerSession) -> Data {
        Data("data: \(Self.json(stateLocked(session)))\n\n".utf8)
    }

    /// Register the stream and enqueue its header and initial snapshot under the same lock.
    private func openStream(_ connection: NWConnection, token: String) {
        let status = lock.withLock { () -> Int in
            guard let session, session.token == token else { return 404 }
            guard streams.count < maxStreams, upgradeRequestLocked(connection) else { return 503 }
            let stream = ViewerStateStream(connection)
            streams[ObjectIdentifier(connection)] = stream
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let connection else { return }
                switch state { case .failed, .cancelled: self?.closeStream(connection); default: break }
            }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n\r\nretry: 3000\n\n"
            pushLocked(Data(header.utf8) + stateEventLocked(session), to: stream)
            scheduleKeepaliveLocked()
            return 200
        }
        guard status == 200 else { send(connection, code: status, mime: "text/plain", body: Data()); return }
        // A state stream has no further requests. Close on EOF or any extra input.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
            self?.closeStream(connection)
        }
    }

    private func closeStream(_ connection: NWConnection) {
        let removed = lock.withLock { streams.removeValue(forKey: ObjectIdentifier(connection)) != nil }
        if removed { connection.cancel() }
    }

    private func pushLocked(_ data: Data, to stream: ViewerStateStream) {
        stream.deadline = .now() + streamSendTimeout
        stream.dirty = false
        scheduleMaintenanceLocked()
        stream.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            self?.stateSent(stream, error: error)
        })
    }

    func stateSent(_ stream: ViewerStateStream, error: NWError?) {
        lock.withLock {
            let id = ObjectIdentifier(stream.connection)
            guard streams[id] === stream else { return }
            guard error == nil, stream.deadline.map({ $0 > .now() }) == true, let session else {
                streams.removeValue(forKey: id)
                stream.connection.cancel()
                return
            }
            stream.deadline = nil
            if stream.dirty { pushLocked(stateEventLocked(session), to: stream) }
        }
    }

    private func publishStateLocked() {
        guard session != nil else { return }
        sequence += 1
        sendCurrentStateLocked()
    }

    /// Broadcasts and keepalives use the same send slot. While it is occupied,
    /// retain only the fact that a fresh snapshot is owed.
    private func sendCurrentStateLocked() {
        guard let session, !streams.isEmpty else { return }
        let message = stateEventLocked(session)
        for stream in streams.values {
            if stream.deadline != nil { stream.dirty = true }
            else { pushLocked(message, to: stream) }
        }
    }

    private func scheduleKeepaliveLocked() {
        guard !keepaliveScheduled, !streams.isEmpty else { return }
        keepaliveScheduled = true
        queue.asyncAfter(deadline: .now() + keepaliveInterval) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                self.keepaliveScheduled = false
                self.sendCurrentStateLocked()
                self.scheduleKeepaliveLocked()
            }
        }
    }

    deinit {
        requests.values.forEach { $0.connection.cancel() }
        streams.values.forEach { $0.connection.cancel() }
        presenceClients.values.forEach { $0.connection.cancel() }
        presenceExpiry?.cancel()
        retry?.cancel()
        startup?.finish(.failure(SetbeamError.unavailable("Viewer server stopped before it was ready.")))
        listener?.cancel()
    }
}

/// A state stream's send slot. Mutable fields are guarded by the gateway lock.
final class ViewerStateStream: @unchecked Sendable {
    let connection: NWConnection
    var deadline: DispatchTime?
    var dirty = false

    init(_ connection: NWConnection) { self.connection = connection }
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
