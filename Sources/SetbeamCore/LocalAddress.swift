import Foundation
import Darwin
import dnssd

/// The operator's chosen first label of a `.local` viewing name, such as `setbeam` in `setbeam.local`.
public enum LocalAddressName {
    public static let defaultLabel = "setbeam"
    public static let maxLength = 40
    public static let domain = "local"

    public enum Problem: Error, Equatable, Sendable {
        case empty, tooLong, characters, hyphenEdge
        public var message: String {
            switch self {
            case .empty: return "Enter a name, or turn off the local address."
            case .tooLong: return "Use \(LocalAddressName.maxLength) characters or fewer."
            case .characters: return "Use only letters, numbers, and hyphens."
            case .hyphenEdge: return "Start and end with a letter or number."
            }
        }
    }

    /// Accepts letters, digits, and inner hyphens, the portable host-label form. Case is not
    /// significant in DNS, so the result is lowercase. A typed `.local` suffix is ignored.
    public static func validated(_ raw: String) -> Result<String, Problem> {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".local.") { value.removeLast(7) } else if value.hasSuffix(".local") { value.removeLast(6) }
        guard !value.isEmpty else { return .failure(.empty) }
        guard value.count <= maxLength else { return .failure(.tooLong) }
        guard value.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else {
            return .failure(.characters)
        }
        guard value.first != "-", value.last != "-" else { return .failure(.hyphenEdge) }
        return .success(value)
    }

    /// The label tried after `attempt - 1` conflicts: `setbeam`, then `setbeam-2`, `setbeam-3`, and so on.
    public static func candidate(_ label: String, attempt: Int) -> String {
        attempt <= 1 ? label : "\(label)-\(attempt)"
    }

    public static func host(_ label: String) -> String { "\(label).\(domain)" }
}

public enum LocalAddressState: Equatable, Sendable {
    /// Not published. The viewing link uses the IP address.
    case stopped
    /// Probing the network for this label before it answers.
    case checking(String)
    /// Registered with the system responder on the selected interface. Resolves to the viewing address.
    case active(String)
    /// Not published. Viewers use the IP address link.
    case unavailable(LocalAddressProblem)

    public var activeLabel: String? { if case .active(let label) = self { return label }; return nil }
}

public enum LocalAddressProblem: Equatable, Sendable {
    /// The requested name and every alternative tried are in use on the network.
    case inUse
    /// The selected interface is not available to the system responder.
    case interface
    /// The system responder refused or lost the registration. Setbeam retries.
    case service(Int32)
}

/// Where a registration answers. The app always uses the selected viewing interface. Probes use
/// this Mac only so the check script never announces names on the network.
public enum LocalAddressScope: Equatable, Sendable {
    case interface(String)
    case thisMacOnly
}

public enum LocalNameEvent: Equatable, Sendable {
    case registered
    case conflict
    case failed(Int32)
}

public protocol LocalNameRegistration: AnyObject {
    /// Removes the record. No event is delivered after this returns on the registrar's queue.
    func cancel()
}

public protocol LocalNameRegistrar: Sendable {
    /// Called on `queue`. Events are delivered on `queue`. A synchronous refusal is returned instead.
    func register(host: String, interfaceIndex: UInt32, address: in_addr, queue: DispatchQueue,
                  events: @escaping (LocalNameEvent) -> Void) -> Result<LocalNameRegistration, LocalNameRefusal>
}

public enum LocalNameRefusal: Error, Equatable, Sendable {
    case conflict
    case failed(Int32)
}

/// Publishes one `.local` IPv4 address record for the viewing address while sharing.
///
/// The record is unique, so the system responder probes before answering and reports a conflict
/// when another host holds the name with a different address. DNS-SD does not rename address
/// records itself, so this publisher tries `-2`, `-3`, and so on. A conflict can also arrive after
/// the name became active, for example when another Mac joins the network; it is handled the same way.
/// Nothing here changes the Mac's own name or network configuration.
public final class LocalAddressPublisher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.setbeam.local-address", qos: .utility)
    private let registrar: LocalNameRegistrar
    private let retryDelay: TimeInterval
    private let maxCandidates: Int
    private let resolveInterface: @Sendable (String) -> UInt32
    private let lock = NSLock()
    private var observer: (@Sendable (LocalAddressState) -> Void)?
    private var current: LocalAddressState = .stopped

    // Queue-confined.
    private struct Desired: Equatable { var label: String; var scope: LocalAddressScope; var address: String }
    private var desired: Desired?
    private var attempt = 1
    private var registration: LocalNameRegistration?
    private var generation = 0
    private var retry: DispatchWorkItem?

    public init(registrar: LocalNameRegistrar = DNSServiceRegistrar(), retryDelay: TimeInterval = 5, maxCandidates: Int = 20,
                resolveInterface: @escaping @Sendable (String) -> UInt32 = { if_nametoindex($0) }) {
        self.registrar = registrar; self.retryDelay = retryDelay; self.maxCandidates = maxCandidates
        self.resolveInterface = resolveInterface
    }

    /// Receives every state change in order, on the publisher's queue.
    public var onChange: (@Sendable (LocalAddressState) -> Void)? {
        get { lock.withLock { observer } }
        set { lock.withLock { observer = newValue } }
    }
    public var state: LocalAddressState { lock.withLock { current } }

    /// Publishes `label.local` for `address`. Repeating the same request keeps the registration.
    /// A new address keeps the label currently held, so links already sent keep their name.
    public func publish(label: String, scope: LocalAddressScope, address: String) {
        queue.async { [self] in
            let next = Desired(label: label, scope: scope, address: address)
            guard next != desired else { return }
            if desired?.label != label { attempt = 1 }
            desired = next
            register()
        }
    }

    public func stop() {
        queue.async { [self] in
            desired = nil; attempt = 1
            tearDown()
            set(.stopped)
        }
    }

    /// Completes after earlier publish and stop requests have been applied.
    public func settle() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private func tearDown() {
        generation += 1
        retry?.cancel(); retry = nil
        registration?.cancel(); registration = nil
    }

    private func register() {
        tearDown()
        guard let desired else { return }
        let index: UInt32
        switch desired.scope {
        case .thisMacOnly: index = UInt32(kDNSServiceInterfaceIndexLocalOnly)
        case .interface(let name): index = resolveInterface(name)
        }
        var address = in_addr()
        guard index != 0, inet_pton(AF_INET, desired.address, &address) == 1 else {
            set(.unavailable(.interface)); scheduleRetry(); return
        }
        while attempt <= maxCandidates {
            let label = LocalAddressName.candidate(desired.label, attempt: attempt)
            let token = generation
            let result = registrar.register(host: LocalAddressName.host(label), interfaceIndex: index, address: address, queue: queue) { [weak self] event in
                self?.handle(event, label: label, generation: token)
            }
            switch result {
            case .success(let value): registration = value; set(.checking(label)); return
            case .failure(.conflict): attempt += 1
            case .failure(.failed(let code)): set(.unavailable(.service(code))); scheduleRetry(); return
            }
        }
        set(.unavailable(.inUse))
    }

    private func handle(_ event: LocalNameEvent, label: String, generation token: Int) {
        guard token == generation, desired != nil else { return }
        switch event {
        case .registered: set(.active(label))
        case .conflict:
            attempt += 1
            register()
        case .failed(let code):
            registration?.cancel(); registration = nil
            set(.unavailable(.service(code))); scheduleRetry()
        }
    }

    private func scheduleRetry() {
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.desired != nil else { return }
            self.register()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + retryDelay, execute: work)
    }

    private func set(_ state: LocalAddressState) {
        let observer = lock.withLock { () -> (@Sendable (LocalAddressState) -> Void)? in
            guard current != state else { return nil }
            current = state
            return self.observer
        }
        observer?(state)
    }

    deinit { registration?.cancel(); retry?.cancel() }
}

/// The system DNS-SD responder (mDNSResponder). It needs no administrator rights, and its records
/// end when the connection is deallocated, including when the app exits.
public struct DNSServiceRegistrar: LocalNameRegistrar {
    public init() {}
    public func register(host: String, interfaceIndex: UInt32, address: in_addr, queue: DispatchQueue,
                         events: @escaping (LocalNameEvent) -> Void) -> Result<LocalNameRegistration, LocalNameRefusal> {
        var connection: DNSServiceRef?
        let created = DNSServiceCreateConnection(&connection)
        guard created == kDNSServiceErr_NoError, let connection else { return .failure(.failed(created)) }
        let attached = DNSServiceSetDispatchQueue(connection, queue)
        guard attached == kDNSServiceErr_NoError else { DNSServiceRefDeallocate(connection); return .failure(.failed(attached)) }
        let registration = DNSServiceRecordRegistration(connection: connection, events: events)
        var record: DNSRecordRef?
        var rdata = address
        let status = withUnsafeBytes(of: &rdata) { bytes in
            DNSServiceRegisterRecord(connection, &record, DNSServiceFlags(kDNSServiceFlagsUnique), interfaceIndex, host,
                UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN), UInt16(bytes.count), bytes.baseAddress, 120,
                { _, _, _, error, context in
                    guard let context else { return }
                    let box = Unmanaged<DNSServiceRecordRegistration>.fromOpaque(context).takeUnretainedValue()
                    box.events(error == kDNSServiceErr_NoError ? .registered : error == kDNSServiceErr_NameConflict ? .conflict : .failed(error))
                }, Unmanaged.passUnretained(registration).toOpaque())
        }
        guard status == kDNSServiceErr_NoError else {
            registration.cancel()
            return .failure(status == kDNSServiceErr_NameConflict ? .conflict : .failed(status))
        }
        return .success(registration)
    }
}

/// Owns one DNS-SD connection and its single address record. Deallocating the connection on the
/// queue it was attached to removes the record and guarantees no later callback.
final class DNSServiceRecordRegistration: LocalNameRegistration {
    private var connection: DNSServiceRef?
    let events: (LocalNameEvent) -> Void
    init(connection: DNSServiceRef, events: @escaping (LocalNameEvent) -> Void) { self.connection = connection; self.events = events }
    func cancel() {
        guard let connection else { return }
        self.connection = nil
        DNSServiceRefDeallocate(connection)
    }
    deinit { cancel() }
}
