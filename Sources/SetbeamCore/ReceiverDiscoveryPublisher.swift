import Foundation
import Darwin
import dnssd

/// The DNS-SD service a native receiver browses for: the short address's ask-only root on port 80.
///
/// It exists only while typing the short address works, so it points at nothing a typed name cannot
/// already reach. It carries no code, pass, credential, title, or viewer name; the receiver still
/// follows the root's redirect and waits for the operator's Admit. See `docs/receiver-protocol.md`.
public struct ReceiverAdvertisement: Equatable, Sendable {
    public static let serviceType = "_setbeam._tcp"
    public static let version = "1"
    public static let rootPath = "/"

    /// The active local-address label. It names the instance and, with `.local`, the SRV target.
    public var label: String
    public var scope: LocalAddressScope
    public var port: UInt16
    /// A random, stable per-installation hint that lets a paired receiver pick this Mac. Not authentication.
    public var installationID: String

    public init(label: String, scope: LocalAddressScope, port: UInt16 = ShortAddressListener.webPort, installationID: String) {
        self.label = label; self.scope = scope; self.port = port; self.installationID = installationID
    }

    /// The SRV target, the same name the local address publishes, such as `setbeam.local`.
    public var host: String { LocalAddressName.host(label) }

    /// TXT entries, in order. Every value is public already: the name is in the address record and the
    /// root path is what anyone types.
    public var txt: [(key: String, value: String)] {
        [("v", Self.version), ("path", Self.rootPath), ("host", host), ("id", installationID)]
    }

    /// The TXT record in DNS wire format: each `key=value` preceded by its length.
    public var txtRecord: Data {
        var data = Data()
        for entry in txt {
            let item = Data("\(entry.key)=\(entry.value)".utf8)
            data.append(UInt8(min(item.count, 255))); data.append(item.prefix(255))
        }
        return data
    }

    /// What to advertise now, or nil to withdraw. Advertises exactly when the short address answers:
    /// open under approval for this link, the port 80 listener ready, and the `.local` name active on a
    /// network others can join.
    public static func current(shortAddressOpen: Bool, listener: ShortAddressListener.State, localAddress: LocalAddressState,
                               askPath: String?, interface: String, installationID: String) -> ReceiverAdvertisement? {
        guard shortAddressOpen, listener == .active, askPath != nil, let label = localAddress.activeLabel,
              (try? LocalAddressName.validated(label).get()) == label,
              !interface.isEmpty, interface != "lo0", isInstallationID(installationID) else { return nil }
        return ReceiverAdvertisement(label: label, scope: .interface(interface), installationID: installationID)
    }

    public static func isInstallationID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    public static func newInstallationID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = withUnsafeBytes(of: UUID().uuid) { Array($0) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public enum ReceiverDiscoveryState: Equatable, Sendable {
    /// Not advertised.
    case stopped
    /// Handed to the system responder; not yet confirmed.
    case registering(String)
    /// Advertised with this instance name, which DNS-SD may have renamed after a conflict.
    case active(String)
    /// Not advertised. Retried while an advertisement is wanted.
    case unavailable(LocalAddressProblem)
}

public enum ReceiverServiceEvent: Equatable, Sendable {
    case registered(name: String)
    case failed(Int32)
}

public struct ReceiverServiceRefusal: Error, Equatable, Sendable {
    public let code: Int32
    public init(_ code: Int32) { self.code = code }
}

public protocol ReceiverServiceRegistrar: Sendable {
    /// Called on `queue`. Events are delivered on `queue`. A synchronous refusal is returned instead.
    func register(_ advertisement: ReceiverAdvertisement, interfaceIndex: UInt32, queue: DispatchQueue,
                  events: @escaping (ReceiverServiceEvent) -> Void) -> Result<LocalNameRegistration, ReceiverServiceRefusal>
}

/// Publishes at most one `_setbeam._tcp` service, on the viewing interface only.
///
/// `publish(nil)` and `stop()` withdraw it. A changed advertisement (name, interface, identifier)
/// replaces the registration; an identical one keeps it. Responder failures and a missing interface
/// retry every 5 s while an advertisement is wanted. Deallocating the DNS-SD reference sends goodbye
/// packets and ends callbacks, including at Quit.
public final class ReceiverDiscoveryPublisher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.setbeam.receiver-discovery", qos: .utility)
    private let registrar: ReceiverServiceRegistrar
    private let retryDelay: TimeInterval
    private let resolveInterface: @Sendable (String) -> UInt32
    private let lock = NSLock()
    private var observer: (@Sendable (ReceiverDiscoveryState) -> Void)?
    private var current: ReceiverDiscoveryState = .stopped

    // Queue-confined.
    private var desired: ReceiverAdvertisement?
    private var registration: LocalNameRegistration?
    private var generation = 0
    private var retry: DispatchWorkItem?

    public init(registrar: ReceiverServiceRegistrar = DNSServiceReceiverRegistrar(), retryDelay: TimeInterval = 5,
                resolveInterface: @escaping @Sendable (String) -> UInt32 = { if_nametoindex($0) }) {
        self.registrar = registrar; self.retryDelay = retryDelay; self.resolveInterface = resolveInterface
    }

    /// Receives every state change in order, on the publisher's queue.
    public var onChange: (@Sendable (ReceiverDiscoveryState) -> Void)? {
        get { lock.withLock { observer } }
        set { lock.withLock { observer = newValue } }
    }
    public var state: ReceiverDiscoveryState { lock.withLock { current } }

    /// Advertises `advertisement`, or withdraws with nil. Repeating the same request keeps the registration.
    public func publish(_ advertisement: ReceiverAdvertisement?) {
        queue.async { [self] in
            guard advertisement != desired else { return }
            desired = advertisement
            if advertisement == nil { tearDown(); set(.stopped) } else { register() }
        }
    }

    public func stop() { publish(nil) }

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
        guard index != 0 else { set(.unavailable(.interface)); scheduleRetry(); return }
        let token = generation
        let result = registrar.register(desired, interfaceIndex: index, queue: queue) { [weak self] event in
            self?.handle(event, generation: token)
        }
        switch result {
        case .success(let value): registration = value; set(.registering(desired.label))
        case .failure(let refusal): set(.unavailable(.service(refusal.code))); scheduleRetry()
        }
    }

    private func handle(_ event: ReceiverServiceEvent, generation token: Int) {
        guard token == generation, desired != nil else { return }
        switch event {
        case .registered(let name): set(.active(name))
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

    private func set(_ state: ReceiverDiscoveryState) {
        let observer = lock.withLock { () -> (@Sendable (ReceiverDiscoveryState) -> Void)? in
            guard current != state else { return nil }
            current = state
            return self.observer
        }
        observer?(state)
    }

    deinit { registration?.cancel(); retry?.cancel() }
}

/// Registers the service with the system DNS-SD responder. No administrator rights are needed.
/// The SRV target is the local address's own name; this registration creates no address record.
public struct DNSServiceReceiverRegistrar: ReceiverServiceRegistrar {
    public init() {}
    public func register(_ advertisement: ReceiverAdvertisement, interfaceIndex: UInt32, queue: DispatchQueue,
                         events: @escaping (ReceiverServiceEvent) -> Void) -> Result<LocalNameRegistration, ReceiverServiceRefusal> {
        let registration = DNSServiceRegistration(events: events)
        let txt = advertisement.txtRecord
        var reference: DNSServiceRef?
        let status = txt.withUnsafeBytes { bytes in
            DNSServiceRegister(&reference, 0, interfaceIndex, advertisement.label, ReceiverAdvertisement.serviceType, "local.",
                               advertisement.host + ".", advertisement.port.bigEndian, UInt16(bytes.count), bytes.baseAddress,
                               { _, flags, error, name, _, _, context in
                                   guard let context else { return }
                                   let box = Unmanaged<DNSServiceRegistration>.fromOpaque(context).takeUnretainedValue()
                                   if error != kDNSServiceErr_NoError { box.events(.failed(error)) }
                                   else if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 { box.events(.registered(name: name.map { String(cString: $0) } ?? "")) }
                                   else { box.events(.failed(Int32(kDNSServiceErr_NameConflict))) }
                               }, Unmanaged.passUnretained(registration).toOpaque())
        }
        guard status == kDNSServiceErr_NoError, let reference else { return .failure(ReceiverServiceRefusal(status)) }
        let attached = DNSServiceSetDispatchQueue(reference, queue)
        guard attached == kDNSServiceErr_NoError else { DNSServiceRefDeallocate(reference); return .failure(ReceiverServiceRefusal(attached)) }
        registration.attach(reference)
        return .success(registration)
    }
}

/// Owns one service registration. Deallocating the reference on its queue removes the service and
/// guarantees no later callback.
final class DNSServiceRegistration: LocalNameRegistration {
    private var reference: DNSServiceRef?
    let events: (ReceiverServiceEvent) -> Void
    init(events: @escaping (ReceiverServiceEvent) -> Void) { self.events = events }
    func attach(_ reference: DNSServiceRef) { self.reference = reference }
    func cancel() {
        guard let reference else { return }
        self.reference = nil
        DNSServiceRefDeallocate(reference)
    }
    deinit { cancel() }
}
