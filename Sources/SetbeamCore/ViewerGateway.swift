import Foundation
import Network

public struct ViewerSession: Sendable {
    public var token: String
    public var title: String
    public var sample: Bool
    public var state: AudienceState
    public var playback: PlaybackDescriptor
    public init(token: String, title: String, sample: Bool, state: AudienceState, playback: PlaybackDescriptor) {
        self.token = token; self.title = title; self.sample = sample; self.state = state; self.playback = playback
    }
}

public struct ViewerActivity: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let playing: Bool
    public let lastSeen: Date
}

/// A small, authenticated static viewer host. It exposes no media-control proxy or file browsing.
public final class ViewerGateway: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.setbeam.viewer", qos: .userInitiated)
    private let lock = NSLock()
    private let assets: [String: Data]
    private var listener: NWListener?
    private var session: ViewerSession?
    private var activity: [String: ViewerActivity] = [:]
    private var running = false
    public init(assets: [String: Data]) { self.assets = assets }
    public func update(_ session: ViewerSession) {
        lock.lock(); defer { lock.unlock() }
        if self.session?.token != session.token { activity.removeAll() }
        self.session = session
    }
    public var viewers: [ViewerActivity] {
        lock.lock(); defer { lock.unlock() }
        activity = activity.filter { Date().timeIntervalSince($0.value.lastSeen) < 12 }
        return activity.values.sorted { $0.id < $1.id }
    }
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    public func start(address: String) async throws -> UInt16 {
        stop()
        return try await withCheckedThrowingContinuation { continuation in
            let completion = ListenerStart(continuation)
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: .init(address), port: .any)
                let listener = try NWListener(using: parameters, on: .any)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.lock.lock(); self.running = true; self.lock.unlock()
                        completion.finish(.success(listener?.port?.rawValue ?? 0))
                    case .failed(let error):
                        self.lock.lock(); self.running = false; self.lock.unlock()
                        completion.finish(.failure(error))
                    case .cancelled:
                        self.lock.lock(); self.running = false; self.lock.unlock()
                        completion.finish(.failure(SetbeamError.unavailable("Viewer server stopped before it was ready.")))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
            } catch { completion.finish(.failure(error)) }
        }
    }
    public func stop() {
        listener?.cancel(); listener = nil
        lock.lock(); running = false; activity.removeAll(); lock.unlock()
    }
    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 6) { connection.cancel() }
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
        guard let current else { send(connection, code: 404, mime: "text/plain", body: Data()); return }
        let prefix = "/s/\(current.token)/"
        guard path.hasPrefix(prefix) else { send(connection, code: 404, mime: "text/plain", body: Data("Session unavailable".utf8)); return }
        let suffix = String(path.dropFirst(prefix.count))
        if suffix == "heartbeat", method == "POST" {
            if let data = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let id = data["id"] as? String, (8...64).contains(id.count), id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) {
                let label = (data["mobile"] as? Bool ?? false) ? "Phone / tablet browser" : "Desktop browser"
                lock.lock()
                if activity.count < 64 || activity[id] != nil {
                    activity[id] = ViewerActivity(id: id, label: label, playing: data["playing"] as? Bool ?? false, lastSeen: Date())
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
        if suffix == "state.json" {
            sendJSON(connection, ["state": current.state.rawValue, "title": current.title, "sample": current.sample]); return
        }
        let file = suffix.isEmpty ? "viewer.html" : suffix
        guard let data = assets[file], ["viewer.html", "viewer.js", "viewer.css", "reader.js"].contains(file) else { send(connection, code: 404, mime: "text/plain", body: Data()); return }
        let mime = file.hasSuffix(".html") ? "text/html; charset=utf-8" : file.hasSuffix(".css") ? "text/css; charset=utf-8" : "text/javascript; charset=utf-8"
        send(connection, code: 200, mime: mime, body: data)
    }
    private func sendJSON(_ connection: NWConnection, _ object: [String: Any]) {
        send(connection, code: 200, mime: "application/json", body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
    }
    private func send(_ connection: NWConnection, code: Int, mime: String, body: Data) {
        let phrase = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large"][code] ?? "Error"
        let header = "HTTP/1.1 \(code) \(phrase)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
    deinit { listener?.cancel() }
}

private final class ListenerStart: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func finish(_ result: Result<UInt16, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}
