import Foundation
import Network

/// Binds the selected input interface without reconfiguring the audience media server.
/// RTMP authentication and path permissions remain inside the private MediaMTX listener.
final class IncomingStreamRelay: @unchecked Sendable {
    private struct Destination: Equatable {
        let address: String
        let port: UInt16
        let targetPort: UInt16
    }
    private final class Start {
        let destination: Destination
        let keepTrying: Bool
        var completion: CheckedContinuation<Void, Error>?
        var listener: NWListener?
        init(_ destination: Destination, keepTrying: Bool, completion: CheckedContinuation<Void, Error>?) {
            self.destination = destination; self.keepTrying = keepTrying; self.completion = completion
        }
        func finish(_ result: Result<Void, Error>) { completion?.resume(with: result); completion = nil }
    }
    private final class Connection {
        let input: NWConnection
        let output: NWConnection
        var lastActivity = Date()
        init(_ input: NWConnection, output: NWConnection) { self.input = input; self.output = output }
        func stop() { input.stateUpdateHandler = nil; output.stateUpdateHandler = nil; input.cancel(); output.cancel() }
    }
    private let queue = DispatchQueue(label: "app.setbeam.incoming", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private var listener: NWListener?
    private var destination: Destination?
    private var startup: Start?
    private var connections: [UUID: Connection] = [:]
    private var timer: DispatchSourceTimer?
    init() { queue.setSpecific(key: queueKey, value: ()) }

    /// A failed new binding leaves the existing listener alone. Initial restoration
    /// can keep retrying an absent interface after its bounded startup result.
    func start(address: String, port: UInt16, targetPort: UInt16, keepTrying: Bool = false) async throws {
        try await withCheckedThrowingContinuation { completion in
            queue.async { [self] in
                let requested = Destination(address: address, port: port, targetPort: targetPort)
                if destination == requested, listener?.state == .ready { completion.resume(); return }
                startup?.listener?.cancel()
                startup?.finish(.failure(SetbeamError.unavailable("The incoming destination changed.")))
                let attempt = Start(requested, keepTrying: keepTrying, completion: completion)
                startup = attempt
                begin(attempt)
            }
        }
    }

    private func begin(_ attempt: Start) {
        guard startup === attempt else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .init(attempt.destination.address), port: .any)
            let candidate = try NWListener(using: parameters, on: .init(rawValue: attempt.destination.port)!)
            attempt.listener = candidate
            candidate.newConnectionHandler = { [weak self, weak candidate] connection in
                guard let self, let candidate, self.listener === candidate,
                      Self.allows(connection.endpoint, network: NetworkAddress.subnet(for: attempt.destination.address)) else { connection.cancel(); return }
                self.accept(connection, targetPort: attempt.destination.targetPort)
            }
            candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                guard let self, let candidate else { return }
                switch state {
                case .ready:
                    guard self.startup === attempt else { return }
                    let previous = self.listener
                    self.closeConnections()
                    self.listener = candidate; self.destination = attempt.destination; self.startup = nil
                    attempt.listener = nil
                    previous?.cancel()
                    self.startIdleTimer()
                    attempt.finish(.success(()))
                case .failed(let error), .waiting(let error):
                    if self.startup === attempt { self.failed(attempt, error: error) }
                    else if self.listener === candidate {
                        candidate.stateUpdateHandler = nil; candidate.cancel()
                        self.listener = nil; self.closeConnections()
                        let retry = Start(attempt.destination, keepTrying: true, completion: nil)
                        self.startup = retry
                        self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.begin(retry) }
                    }
                default: break
                }
            }
            candidate.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { [weak self, weak candidate] in
                guard let self, self.startup === attempt, attempt.listener === candidate else { return }
                self.failed(attempt, error: SetbeamError.unavailable("The selected incoming address is unavailable."))
            }
        } catch { failed(attempt, error: error) }
    }

    static func allows(_ endpoint: NWEndpoint, network: String) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let bytes: [UInt8]
        switch host {
        case .ipv4(let address): bytes = [UInt8](address.rawValue)
        case .ipv6(let address):
            let raw = [UInt8](address.rawValue)
            if raw.dropLast().allSatisfy({ $0 == 0 }), raw.last == 1 { return true }
            guard raw.prefix(10).allSatisfy({ $0 == 0 }), raw[10] == 255, raw[11] == 255 else { return false }
            bytes = Array(raw.suffix(4))
        default: return false
        }
        if bytes == [127, 0, 0, 1] { return true }
        let parts = network.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix),
              let address = IPv4Address(String(parts[0])) else { return false }
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        func integer(_ values: [UInt8]) -> UInt32 { values.reduce(0) { ($0 << 8) | UInt32($1) } }
        return integer(bytes) & mask == integer([UInt8](address.rawValue)) & mask
    }

    private func failed(_ attempt: Start, error: Error) {
        guard startup === attempt else { return }
        attempt.listener?.stateUpdateHandler = nil
        attempt.listener?.cancel(); attempt.listener = nil
        attempt.finish(.failure(SetbeamError.unavailable("The incoming destination could not open. Choose an available input address and port. \(error.localizedDescription)")))
        if attempt.keepTrying {
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.begin(attempt) }
        } else { startup = nil }
    }

    private func accept(_ input: NWConnection, targetPort: UInt16) {
        guard connections.count < 8 else { input.cancel(); return }
        let output = NWConnection(host: "127.0.0.1", port: .init(rawValue: targetPort)!, using: .tcp)
        let identifier = UUID(), connection = Connection(input, output: output)
        connections[identifier] = connection
        input.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close(identifier) }
            if case .cancelled = state { self?.close(identifier) }
        }
        output.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.copy(identifier, from: input, to: output)
                self?.copy(identifier, from: output, to: input)
            }
            if case .failed = state { self?.close(identifier) }
            if case .cancelled = state { self?.close(identifier) }
        }
        input.start(queue: queue); output.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.connections[identifier] != nil, output.state != .ready { self?.close(identifier) }
        }
    }

    private func copy(_ identifier: UUID, from input: NWConnection, to output: NWConnection) {
        guard connections[identifier] != nil else { return }
        // A direction reads its next 64 KiB only after the previous write completes.
        input.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, let connection = self.connections[identifier] else { return }
            guard error == nil, !complete, let data, !data.isEmpty else { self.close(identifier); return }
            connection.lastActivity = Date()
            output.send(content: data, completion: .contentProcessed { [weak self] error in
                guard error == nil else { self?.close(identifier); return }
                self?.copy(identifier, from: input, to: output)
            })
        }
    }

    private func startIdleTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let expired = self.connections.filter { Date().timeIntervalSince($0.value.lastActivity) > 30 }.map(\.key)
            for identifier in expired { self.close(identifier) }
        }
        self.timer = timer; timer.resume()
    }
    private func close(_ identifier: UUID) { connections.removeValue(forKey: identifier)?.stop() }
    private func closeConnections() { let old = connections; connections.removeAll(); for connection in old.values { connection.stop() } }
    private func onQueue(_ action: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { action() }
        else { queue.sync(execute: action) }
    }
    func disconnectSenders() { onQueue { closeConnections() } }
    func stop() {
        onQueue {
            startup?.listener?.cancel(); startup?.finish(.failure(SetbeamError.unavailable("The incoming destination stopped."))); startup = nil
            listener?.cancel(); listener = nil; destination = nil
            timer?.cancel(); timer = nil; closeConnections()
        }
    }
    deinit { stop() }
}
