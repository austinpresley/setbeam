import Foundation
import Network

/// One browser's presence WebSocket. Mutable fields are guarded by the gateway lock.
final class PresenceClient: @unchecked Sendable {
    let connection: NWConnection
    let opened: Date
    var number: Int?
    var pass: String?
    var buffer = Data()
    var sending = false, dirty = false
    var sendStartedAt: Date?
    var closing = false
    var repliesInFlight = 0
    var repliesStartedAt: Date?
    var lastHeard: Date
    var frames = 0
    var framesSince: Date
    init(connection: NWConnection, now: Date) {
        self.connection = connection; opened = now; lastHeard = now; framesSince = now
    }
}

/// Shared pointers over a small WebSocket subset. A channel is presence only: it carries
/// a participant's validated picture position and receives the others' latest positions. It
/// never reaches media control, publishing, administration, or the operator's roster.
extension ViewerGateway {
    static let presenceFrameLimit = 512, presenceBufferLimit = 4096, presenceFramesPerSecond = 120
    static let maxPresenceReplies = 8
    static let presenceHelloDeadline: TimeInterval = 3, presenceSilence: TimeInterval = 20, presenceSendDeadline: TimeInterval = 5
    /// About 30 updates per second, independent of source capture and viewer video frame rates.
    static let presenceFlushInterval: TimeInterval = 0.033

    func openPresence(_ connection: NWConnection, headers: [String: String], token: String, extra: Data) {
        // Same-origin pages only. The pass in the first message still decides access.
        guard headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().contains("upgrade") == true,
              headers["sec-websocket-version"] == "13",
              let key = headers["sec-websocket-key"], let accept = WebSocketFrame.acceptKey(for: key),
              let host = headers["host"], headers["origin"] == "http://" + host else {
            send(connection, code: 400, mime: "text/plain", body: Data()); return
        }
        let client = PresenceClient(connection: connection, now: Date())
        client.buffer = extra
        let accepted = lock.withLock { () -> Bool in
            guard session?.token == token, pointersEnabled, presenceClients.count < maxPresenceClients,
                  upgradeRequestLocked(connection) else { return false }
            presenceClients[ObjectIdentifier(connection)] = client
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let connection else { return }
                switch state { case .failed, .cancelled: self?.closePresence(connection); default: break }
            }
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            return sendPresenceReplyLocked(Data(response.utf8), to: client)
        }
        guard accepted else { send(connection, code: 503, mime: "text/plain", body: Data()); return }
        if processPresence(client) { readPresence(client) }
        schedulePresenceMaintenance()
    }

    private func readPresence(_ client: PresenceClient) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: Self.presenceBufferLimit) { [weak self] data, _, complete, error in
            guard let self else { client.connection.cancel(); return }
            if let data, !data.isEmpty {
                let fits = self.lock.withLock { () -> Bool in
                    guard self.presenceClients[ObjectIdentifier(client.connection)] === client else { return false }
                    client.buffer.append(data)
                    return client.buffer.count <= Self.presenceBufferLimit
                }
                guard fits else { self.closePresence(client.connection); return }
                // A refused or invalid frame has already closed the channel with its final message.
                guard self.processPresence(client) else { return }
            }
            if complete || error != nil { self.closePresence(client.connection); return }
            self.readPresence(client)
        }
    }

    private enum PresenceReply { case data(Data), close(Data?) }

    /// Handles every complete frame. Returns false once the channel must close.
    @discardableResult private func processPresence(_ client: PresenceClient) -> Bool {
        let now = Date()
        let replies = lock.withLock { () -> [PresenceReply] in
            guard presenceClients[ObjectIdentifier(client.connection)] === client else { return [.close(nil)] }
            let frames: [WebSocketFrame]
            do { frames = try WebSocketFrame.parse(&client.buffer, maxPayload: Self.presenceFrameLimit) }
            catch { return [.close(WebSocketFrame.encode(opcode: 0x8, payload: Data([0x03, 0xEA])))] }
            var replies: [PresenceReply] = []
            for frame in frames {
                client.lastHeard = now
                if now.timeIntervalSince(client.framesSince) >= 1 { client.framesSince = now; client.frames = 0 }
                client.frames += 1
                guard client.frames <= Self.presenceFramesPerSecond else { return replies + [.close(nil)] }
                switch frame {
                case .close: return replies + [.close(WebSocketFrame.encode(opcode: 0x8, payload: Data()))]
                case .ping(let payload): replies.append(.data(WebSocketFrame.encode(opcode: 0xA, payload: payload)))
                case .pong: break
                case .text(let text):
                    guard let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { continue }
                    if let reply = presenceMessageLocked(message, client: client, now: now) {
                        replies.append(reply)
                        if case .close = reply { return replies }
                    }
                }
            }
            return replies
        }
        var open = true
        for reply in replies {
            switch reply {
            case .data(let data):
                guard lock.withLock({ sendPresenceReplyLocked(data, to: client) }) else {
                    closePresence(client.connection)
                    return false
                }
            case .close(let data):
                open = false
                closePresence(client.connection, finalMessage: data)
            }
        }
        schedulePresenceFlush()
        return open
    }

    private func presenceMessageLocked(_ message: [String: Any], client: PresenceClient, now: Date) -> PresenceReply? {
        func deny(_ reason: String) -> PresenceReply {
            .close(WebSocketFrame.encode(text: Self.json(["t": "denied", "reason": reason])) + WebSocketFrame.encode(opcode: 0x8, payload: Data()))
        }
        let type = message["t"] as? String
        guard let number = client.number, let pass = client.pass else {
            // The first message must authenticate this admitted session.
            guard type == "hello", let pass = ViewerAccessLedger.validPass(message["pass"]), pointersEnabled,
                  let record = ledger.record(pass), record.admission == .admitted else { return deny("access") }
            // Under approval the name is the one the operator admitted.
            let offered = ViewerHealth.viewerName(message["name"] as? String)
            let name = ledger.approvalRequired ? record.name ?? offered : offered ?? record.name
            guard let name else { return deny("name") }
            let color = PointerColor.validated(message["color"]) ?? record.color
            guard presence.join(record.number, name: name, color: color, now: now) else { return deny("full") }
            ledger.setName(pass, name); ledger.setColor(pass, color)
            // A participant has one channel. A reopened tab replaces its earlier channel.
            for (key, other) in presenceClients where other !== client && other.number == record.number {
                presenceClients.removeValue(forKey: key)
                let connection = other.connection
                queue.async { connection.cancel() }
            }
            client.number = record.number; client.pass = pass
            return .data(WebSocketFrame.encode(text: Self.json(["t": "welcome", "n": record.number, "r": presence.revision,
                                                                 "name": name, "color": color.rawValue])))
        }
        guard ledger.record(pass)?.admission == .admitted, pointersEnabled else { return deny("access") }
        switch type {
        case "move":
            guard session?.state == .live, let x = Self.finite(message["x"]), let y = Self.finite(message["y"]),
                  let revision = message["r"] as? Int else { return nil }
            _ = presence.move(number, x: x, y: y, revision: revision, explicit: message["tap"] as? Bool == true, now: now)
        case "hide": presence.hide(number)
        default: break
        }
        return nil
    }

    /// Presence snapshots coalesce separately. Bound small control writes as well.
    private func sendPresenceReplyLocked(_ data: Data, to client: PresenceClient, final: Bool = false) -> Bool {
        guard presenceClients[ObjectIdentifier(client.connection)] === client,
              client.repliesInFlight < Self.maxPresenceReplies else { return false }
        if client.repliesInFlight == 0 { client.repliesStartedAt = Date() }
        client.repliesInFlight += 1
        client.connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                               completion: .contentProcessed { [weak self] error in
            guard let self else { client.connection.cancel(); return }
            if final || error != nil { self.closePresence(client.connection); return }
            self.lock.withLock {
                client.repliesInFlight -= 1
                if client.repliesInFlight == 0 { client.repliesStartedAt = nil }
            }
        })
        return true
    }

    /// Ends presence immediately. A final frame keeps its slot until sent or timed out.
    func closePresence(_ connection: NWConnection, finalMessage: Data? = nil) {
        let removed = lock.withLock {
            let id = ObjectIdentifier(connection)
            guard let client = presenceClients[id] else { return false }
            if let number = client.number { presence.leave(number) }
            client.number = nil; client.pass = nil
            schedulePresenceFlushLocked()
            if let finalMessage, !client.closing {
                client.closing = true
                if sendPresenceReplyLocked(finalMessage, to: client, final: true) { return false }
            }
            presenceClients.removeValue(forKey: id)
            return true
        }
        if removed { connection.cancel() }
    }

    /// A ledger eviction or revocation also frees the participant and its channel.
    func retireUnauthorizedPresenceLocked() {
        for (id, client) in presenceClients {
            guard let pass = client.pass, ledger.record(pass)?.admission != .admitted else { continue }
            if let number = client.number { presence.leave(number) }
            presenceClients.removeValue(forKey: id)
            client.connection.cancel()
            schedulePresenceFlushLocked()
        }
    }

    func schedulePresenceFlush() { lock.withLock { schedulePresenceFlushLocked() } }

    func schedulePresenceFlushLocked() {
        guard !presenceFlushScheduled else { return }
        presenceFlushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.presenceFlushInterval) { [weak self] in self?.flushPresence() }
    }

    /// Sends each participant the others' latest pointers. A receiver with a send in flight gets
    /// only the newest state after it finishes, so slow receivers never accumulate a queue.
    private func flushPresence() {
        let now = Date()
        let (sends, observer, pointers, expiry) = lock.withLock { () -> ([(PresenceClient, Data)], (@Sendable ([SharedPointer]) -> Void)?, [SharedPointer], Date?) in
            presenceFlushScheduled = false
            let pointers = presence.pointers(now: now)
            var sends: [(PresenceClient, Data)] = []
            for client in presenceClients.values {
                guard let number = client.number else { continue }
                if client.sending { client.dirty = true; continue }
                client.sending = true; client.sendStartedAt = now
                let items = pointers.filter { $0.number != number }.map { pointer -> [String: Any] in
                    ["n": pointer.number, "label": pointer.label, "color": pointer.color.rawValue, "x": pointer.x, "y": pointer.y,
                     "ttl": Int((pointer.remaining * 1000).rounded(.down))]
                }
                sends.append((client, WebSocketFrame.encode(text: Self.json(["t": "pointers", "r": presence.revision, "items": items]))))
            }
            let changed = !Self.samePointers(pointers, at: now, notifiedPointers, at: notifiedAt)
            if changed { notifiedPointers = pointers; notifiedAt = now }
            return (sends, changed ? pointerObserver : nil, pointers, presence.nextExpiry(now: now))
        }
        for (client, data) in sends {
            client.connection.send(content: data, completion: .contentProcessed { [weak self] error in self?.presenceSent(client, error: error) })
        }
        observer?(pointers)
        if let expiry {
            let work = DispatchWorkItem { [weak self] in self?.schedulePresenceFlush() }
            lock.withLock { presenceExpiry?.cancel(); presenceExpiry = work }
            queue.asyncAfter(deadline: .now() + max(0, expiry.timeIntervalSince(Date())) + 0.02, execute: work)
        }
    }

    func presenceSent(_ client: PresenceClient, error: NWError?) {
        guard error == nil else { closePresence(client.connection); return }
        let again = lock.withLock { () -> Bool in
            client.sending = false; client.sendStartedAt = nil
            let dirty = client.dirty; client.dirty = false
            return dirty
        }
        if again { schedulePresenceFlush() }
    }

    /// Closes unidentified, silent, or stuck channels without waiting for the browser.
    func schedulePresenceMaintenance() {
        let schedule = lock.withLock { () -> Bool in
            guard !presenceMaintenanceScheduled, !presenceClients.isEmpty else { return false }
            presenceMaintenanceScheduled = true; return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let now = Date()
            let stale = self.lock.withLock { () -> [NWConnection] in
                self.presenceMaintenanceScheduled = false
                return self.presenceClients.values.filter { client in
                    (client.number == nil && now.timeIntervalSince(client.opened) > Self.presenceHelloDeadline) ||
                    now.timeIntervalSince(client.lastHeard) > Self.presenceSilence ||
                    client.sendStartedAt.map { now.timeIntervalSince($0) > Self.presenceSendDeadline } == true ||
                    client.repliesStartedAt.map { now.timeIntervalSince($0) > Self.presenceSendDeadline } == true
                }.map(\.connection)
            }
            stale.forEach { self.closePresence($0) }
            self.schedulePresenceMaintenance()
        }
    }

    static func finite(_ value: Any?) -> Double? {
        // JSON booleans also bridge to NSNumber; only real numbers are coordinates.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
    static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8), as: UTF8.self)
    }
    /// Equal when nothing visible changed and no pointer's fade time moved, such as a tap in place.
    static func samePointers(_ a: [SharedPointer], at aTime: Date, _ b: [SharedPointer], at bTime: Date) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.number == $1.number && $0.x == $1.x && $0.y == $1.y && $0.label == $1.label &&
            $0.color == $1.color && abs(aTime.addingTimeInterval($0.remaining).timeIntervalSince(bTime.addingTimeInterval($1.remaining))) < 0.001 }
    }
}
