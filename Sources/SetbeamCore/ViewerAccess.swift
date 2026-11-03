import Foundation

/// A browser session's place in the optional approval flow.
public enum ViewerAdmission: String, Sendable {
    case pending, admitted, declined, removed
}

/// An individual read-only media credential for one admitted browser session.
public struct ViewerReader: Hashable, Sendable {
    public let user: String
    public let password: String
    public init(user: String, password: String) { self.user = user; self.password = password }
}

/// Server-issued browser-session identity and admission for one viewing link.
///
/// Each tab receives a secret pass from the gateway; client-chosen IDs and names never identify a
/// session. Without approval, every holder of the viewing link is admitted and plays with the
/// shared read credential, as before. With approval, a pending request must be admitted by the
/// operator and then plays only with its own reader, which removal revokes individually.
/// Names are bounded labels, not verified identities.
struct ViewerAccessLedger {
    static let maxRecords = 128, maxPending = 16
    /// Rows disappear from operator details after this long without contact.
    static let visibleFor: TimeInterval = 12
    /// An unanswered request lapses after this long without its page asking again.
    static let pendingFor: TimeInterval = 30

    struct Record {
        let pass: String
        let number: Int
        var name: String?
        var color: PointerColor
        var mobile: Bool
        var local: Bool
        var admission: ViewerAdmission
        let joinedAt: Date
        var lastSeen: Date
        var reader: ViewerReader?
        /// True once this session's media credential is accepted by the media server.
        var mediaReady: Bool
        var playing = false
        var revision = -1
        var health = ViewerHealth.connecting
    }
    enum JoinOutcome { case joined(Record), nameRequired, full }

    private(set) var approvalRequired = false
    private var records: [String: Record] = [:]
    private var nextNumber = 1
    private let secret: () -> String

    init(secret: @escaping () -> String = ViewerAccessLedger.randomSecret) { self.secret = secret }

    static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = Array((UUID().uuidString + UUID().uuidString).utf8.prefix(24))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func validPass(_ value: Any?) -> String? {
        guard let value = value as? String, value.count == 48, value.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return value
    }

    func record(_ pass: String) -> Record? { records[pass] }
    func record(number: Int) -> Record? { records.values.first { $0.number == number } }

    /// Resumes a known pass or creates one. A known declined or removed pass stays refused;
    /// a new request under approval needs a name, the viewer's explicit request, and the
    /// operator's decision. A saved name sent without `asking` never starts a request.
    mutating func join(pass: String?, name: String?, asking: Bool = false, color: PointerColor?, mobile: Bool, local: Bool, now: Date) -> JoinOutcome {
        prune(now: now)
        if let pass, var record = records[pass] {
            record.lastSeen = now; record.mobile = mobile; record.local = local
            if !approvalRequired, let name { record.name = name }
            if let color { record.color = color }
            records[pass] = record
            return .joined(record)
        }
        if approvalRequired, name == nil || !asking { return .nameRequired }
        if approvalRequired, records.values.filter({ $0.admission == .pending }).count >= Self.maxPending { return .full }
        if records.count >= Self.maxRecords {
            // Make room only from sessions that have stopped contacting the gateway.
            guard let oldest = records.values.filter({ now.timeIntervalSince($0.lastSeen) >= Self.visibleFor })
                .min(by: { $0.lastSeen < $1.lastSeen }) else { return .full }
            records.removeValue(forKey: oldest.pass)
        }
        let number = nextNumber; nextNumber += 1
        let record = Record(pass: secret(), number: number, name: name, color: color ?? .fallback(for: number), mobile: mobile, local: local,
                            admission: approvalRequired ? .pending : .admitted, joinedAt: now, lastSeen: now,
                            reader: nil, mediaReady: !approvalRequired)
        records[record.pass] = record
        return .joined(record)
    }

    /// Records playback observations for a known pass. Names change only without approval,
    /// so an admitted request cannot rename itself after the operator's decision. Under approval,
    /// a session admitted unnamed before approval may set its first label, as with `setName`.
    mutating func heartbeat(_ pass: String, playing: Bool, health: ViewerHealth, revision: Int, name: String??, mobile: Bool, local: Bool, now: Date) -> Record? {
        guard var record = records[pass] else { return nil }
        record.lastSeen = now; record.mobile = mobile; record.local = local
        if record.admission == .admitted {
            record.playing = playing; record.health = health; record.revision = revision
        }
        if let name, !approvalRequired || (record.name == nil && name != nil) { record.name = name }
        records[pass] = record
        return record
    }
    mutating func setColor(_ pass: String, _ color: PointerColor) { records[pass]?.color = color }
    /// Under approval an admitted name is fixed; a session admitted unnamed before approval may set its first label.
    mutating func setName(_ pass: String, _ name: String) {
        if !approvalRequired || records[pass]?.name == nil { records[pass]?.name = name }
    }

    @discardableResult mutating func approve(number: Int) -> Bool {
        guard let pass = record(number: number)?.pass, records[pass]?.admission == .pending else { return false }
        records[pass]?.admission = .admitted
        assignReader(pass)
        return true
    }
    @discardableResult mutating func decline(number: Int) -> Bool {
        guard let pass = record(number: number)?.pass, records[pass]?.admission == .pending else { return false }
        records[pass]?.admission = .declined
        return true
    }
    /// Individual removal is enforceable only when approval is on; otherwise the link itself admits.
    @discardableResult mutating func remove(number: Int) -> Bool {
        guard approvalRequired, let pass = record(number: number)?.pass, records[pass]?.admission == .admitted else { return false }
        records[pass]?.admission = .removed
        records[pass]?.reader = nil; records[pass]?.mediaReady = false; records[pass]?.playing = false
        return true
    }

    /// Turning approval on moves already-admitted sessions to their own readers; turning it off
    /// admits waiting requests with the link's shared credential. Refusals stay refused.
    mutating func setApproval(_ required: Bool) {
        guard required != approvalRequired else { return }
        approvalRequired = required
        for pass in Array(records.keys) {
            guard let record = records[pass] else { continue }
            if required, record.admission == .admitted, record.reader == nil { assignReader(pass) }
            if !required, record.admission == .pending { records[pass]?.admission = .admitted; records[pass]?.mediaReady = true }
        }
    }
    private mutating func assignReader(_ pass: String) {
        guard approvalRequired, let number = records[pass]?.number else { records[pass]?.mediaReady = true; return }
        records[pass]?.reader = ViewerReader(user: "viewer\(number)x\(secret().prefix(8))", password: secret())
        records[pass]?.mediaReady = false
    }

    /// Readers the media server must accept now.
    var readers: Set<ViewerReader> {
        Set(records.values.compactMap { $0.admission == .admitted ? $0.reader : nil })
    }
    /// Marks admitted sessions whose reader the media server has accepted.
    mutating func confirm(readers applied: Set<ViewerReader>) -> Bool {
        var changed = false
        for (pass, record) in records where record.admission == .admitted && !record.mediaReady {
            if let reader = record.reader, applied.contains(reader) { records[pass]?.mediaReady = true; changed = true }
        }
        return changed
    }

    func activity(session: ViewerSession?, now: Date) -> [ViewerActivity] {
        records.values.filter { [.pending, .admitted].contains($0.admission) && now.timeIntervalSince($0.lastSeen) < Self.visibleFor }
            .map { record in
                let age = now.timeIntervalSince(record.lastSeen)
                let admitted = record.admission == .admitted
                return ViewerActivity(id: "viewer-\(record.number)", label: record.mobile ? "Phone / tablet browser" : "Desktop browser",
                    playing: admitted && record.playing && record.revision == session?.revision && session?.state == .live && age < 8,
                    onThisMac: record.local, revision: record.revision, lastSeen: record.lastSeen, number: record.number, name: record.name,
                    health: admitted ? ViewerHealth.observed(record.health, playing: record.playing, revision: record.revision, session: session, age: age) : .connecting,
                    admission: record.admission, color: record.color, joinedAt: record.joinedAt)
            }.sorted { $0.number < $1.number }
    }

    private mutating func prune(now: Date) {
        records = records.filter { $0.value.admission != .pending || now.timeIntervalSince($0.value.lastSeen) < Self.pendingFor }
    }
    /// A new viewing link starts a new numbering; the approval choice stays.
    mutating func reset() { records.removeAll(); nextNumber = 1 }
}
