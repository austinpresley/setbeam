import Foundation
import Network

extension ViewerGateway {
    public var chatMessages: [ChatMessage] { lock.withLock { session?.state != .stopped ? chat.messages(for: 0) : [] } }
    public func chatFrame(id: Int) -> Data? { lock.withLock { session?.state != .stopped ? chat.frame(id) : nil } }
    public func setChatFramePermission(_ allowed: Bool) { lock.withLock { chatFramesAllowed = allowed && session?.state == .live } }
    public func postChat(text: String, replyTo: Int?, frame: Data?, revision: Int, token: String, name: String, color: PointerColor, requestID: String) throws {
        let prepared = try frame.map(SessionChat.sanitizedFrame)
        try lock.withLock {
            guard let session, session.token == token, session.state != .stopped else { throw SetbeamError.unavailable("Sharing ended. Start sharing before sending a message.") }
            if prepared != nil { try checkChatFrame(revision: revision) }
            try chat.post(author: ChatAuthor(number: 0, name: ViewerHealth.viewerName(SessionChat.clean(name)) ?? "DigiTech", color: color),
                          text: text, replyTo: replyTo, frame: prepared, requestID: requestID, now: Date(), sampleFrame: session.sample && prepared != nil)
        }
    }
    public func likeChat(id: Int, liked: Bool, token: String) throws {
        try lock.withLock {
            guard let session, session.token == token, session.state != .stopped else { throw SetbeamError.unavailable("Sharing ended.") }
            try chat.like(id: id, author: 0, liked: liked, now: Date())
        }
    }
    public func reactChat(id: Int, reaction: ChatReaction?, token: String) throws {
        try lock.withLock {
            guard let session, session.token == token, session.state != .stopped else { throw SetbeamError.unavailable("Sharing ended.") }
            try chat.react(id: id, author: 0, reaction: reaction, now: Date())
        }
    }
    public func removeChat(id: Int, token: String) {
        lock.withLock {
            guard session?.token == token, session?.state != .stopped else { return }
            chat.remove(id)
        }
    }
    private func checkChatFrame(revision: Int) throws {
        guard let session, session.state == .live, chatFramesAllowed, session.revision == revision else { throw SetbeamError.unavailable("The feed changed or is on hold. Capture a new frame after sharing resumes.") }
    }

    func respondChat(_ connection: NWConnection, method: String, suffix: String, headers: [String: String], body: Data, token: String) {
        let pass = ViewerAccessLedger.validPass(headers["x-setbeam-pass"])
        guard let host = headers["host"], headers["origin"].map({ $0 == "http://" + host }) ?? (method == "GET"),
              method == "GET" || headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            send(connection, code: 403, mime: "text/plain", body: Data()); return
        }
        do {
            // Authenticate before parsing user content or decoding a submitted image.
            let number = lock.withLock { () -> Int? in
                guard session?.token == token, session?.state != .stopped, let pass,
                      let record = ledger.record(pass), record.admission == .admitted else { return nil }
                return record.number
            }
            guard let number else { send(connection, code: 403, mime: "text/plain", body: Data()); return }
            if method == "GET" {
                let reply: (Int, String, Data) = lock.withLock {
                    guard session?.token == token, session?.state != .stopped, let pass, ledger.record(pass)?.admission == .admitted else { return (403, "text/plain", Data()) }
                    if suffix == "chat" { return (200, "application/json", (try? JSONEncoder().encode(chat.messages(for: number))) ?? Data("[]".utf8)) }
                    if suffix.hasPrefix("chat/frame/"), let id = Int(suffix.dropFirst("chat/frame/".count)), let frame = chat.frame(id) { return (200, "image/jpeg", frame) }
                    return (404, "text/plain", Data())
                }
                send(connection, code: reply.0, mime: reply.1, body: reply.2); return
            }
            guard suffix == "chat", let data = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw SetbeamError.invalidSource("This message could not be read.") }
            let rawFrame: Data?
            if let encoded = data["frame"] as? String {
                guard let decoded = Data(base64Encoded: encoded), decoded.count <= SessionChat.maxFrameBytes else { throw SetbeamError.invalidSource("Capture a smaller frame.") }
                // Gate before decoding, then recheck under the lock before publishing.
                try lock.withLock { try checkChatFrame(revision: data["revision"] as? Int ?? -1) }
                rawFrame = try SessionChat.sanitizedFrame(decoded)
            } else { rawFrame = nil }
            try lock.withLock {
                guard session?.token == token, session?.state != .stopped, let pass,
                      let record = ledger.record(pass), record.admission == .admitted else { throw SetbeamError.unavailable("Your session no longer has chat access.") }
                if data["action"] as? String == "like", let id = data["id"] as? Int, let liked = data["liked"] as? Bool {
                    try chat.like(id: id, author: number, liked: liked, now: Date())
                } else if data["action"] as? String == "react", let id = data["id"] as? Int {
                    let reaction: ChatReaction?
                    if let raw = data["reaction"] as? String, let value = ChatReaction(rawValue: raw) { reaction = value }
                    else if data["reaction"] is NSNull { reaction = nil }
                    else { throw SetbeamError.invalidSource("Choose one of the available reactions.") }
                    try chat.react(id: id, author: number, reaction: reaction, now: Date())
                } else if data["action"] as? String == "post" {
                    if rawFrame != nil { try checkChatFrame(revision: data["revision"] as? Int ?? -1) }
                    let name = SessionChat.clean(record.name ?? "Viewer \(number)")
                    try chat.post(author: ChatAuthor(number: number, name: name, color: record.color), text: data["text"] as? String ?? "",
                                  replyTo: data["replyTo"] as? Int, frame: rawFrame, requestID: data["requestID"] as? String ?? "", now: Date(), sampleFrame: session?.sample == true && rawFrame != nil)
                } else { throw SetbeamError.invalidSource("This chat action is unavailable.") }
            }
            sendJSON(connection, ["ok": true])
        } catch {
            let object = ["error": error.localizedDescription]
            send(connection, code: 400, mime: "application/json", body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
    }
}
