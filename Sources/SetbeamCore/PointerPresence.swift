import Foundation

/// The validated preset pointer colors. Only these identifiers cross the network.
public enum PointerColor: String, CaseIterable, Sendable {
    // The first six keep their order so earlier sessions' default colors are unchanged.
    case blue, green, orange, pink, purple, yellow, red, teal, cyan, lime, indigo, brown

    public var label: String { rawValue.capitalized }
    /// sRGB fill for the pointer and its name label.
    public var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .blue: return (0.10, 0.37, 0.85)
        case .green: return (0.09, 0.47, 0.22)
        case .orange: return (0.98, 0.58, 0.10)
        case .pink: return (0.80, 0.16, 0.50)
        case .purple: return (0.46, 0.25, 0.80)
        case .yellow: return (0.98, 0.82, 0.12)
        case .red: return (0.77, 0.17, 0.17)
        case .teal: return (0.04, 0.45, 0.50)
        case .cyan: return (0.24, 0.78, 0.90)
        case .lime: return (0.65, 0.85, 0.23)
        case .indigo: return (0.26, 0.22, 0.79)
        case .brown: return (0.54, 0.33, 0.15)
        }
    }
    /// Name text uses whichever of white or near-black keeps at least 4.5:1 contrast.
    public var darkText: Bool { [.orange, .yellow, .cyan, .lime].contains(self) }

    /// A stable default that spreads session numbers across the palette.
    public static func fallback(for number: Int) -> PointerColor { allCases[(max(1, number) - 1) % allCases.count] }
    public static func validated(_ value: Any?) -> PointerColor? { (value as? String).flatMap(PointerColor.init(rawValue:)) }
}

/// One participant's visible pointer, relative to the shared picture (0...1 on each axis).
public struct SharedPointer: Sendable, Equatable {
    public let number: Int
    public let label: String
    public let color: PointerColor
    public let x: Double
    public let y: Double
    /// Seconds until the pointer fades from inactivity. Receivers expire it locally after this.
    public let remaining: TimeInterval
    public init(number: Int, label: String, color: PointerColor, x: Double, y: Double, remaining: TimeInterval) {
        self.number = number; self.label = label; self.color = color; self.x = x; self.y = y; self.remaining = remaining
    }
}

/// Bounded, picture-relative pointer state for one viewing link and publisher revision. It keeps
/// only each participant's latest position; nothing is retained as history.
struct PointerPresence {
    /// A stationary pointer and its name fade after this long without meaningful movement.
    static let idle: TimeInterval = 4
    /// Movement below this picture fraction (about 6 px across 1920) does not keep a pointer visible.
    static let meaningfulDistance = 0.003
    static let maxParticipants = 16
    static let updatesPerSecond = 30.0, burst = 30.0

    private struct Entry {
        var name: String
        var color: PointerColor
        var position: (x: Double, y: Double)?
        var anchor: (x: Double, y: Double)?
        var movedAt: Date?
        var tokens: Double
        var refilledAt: Date
    }
    private var entries: [Int: Entry] = [:]
    private(set) var revision: Int

    init(revision: Int) { self.revision = revision }

    var participants: Set<Int> { Set(entries.keys) }
    var isEmpty: Bool { entries.isEmpty }

    /// Joins or updates a participant. Returns false when the participant limit is reached.
    mutating func join(_ number: Int, name: String, color: PointerColor, now: Date) -> Bool {
        if var entry = entries[number] {
            entry.name = name; entry.color = color; entries[number] = entry
            return true
        }
        guard entries.count < Self.maxParticipants else { return false }
        entries[number] = Entry(name: name, color: color, tokens: Self.burst, refilledAt: now)
        return true
    }
    /// Returns true when a visible pointer disappeared.
    @discardableResult mutating func leave(_ number: Int) -> Bool {
        entries.removeValue(forKey: number)?.position != nil
    }

    /// Applies a validated position. Updates for another publisher revision, outside the picture,
    /// non-finite, or above the participant's rate are dropped. Returns true when the shared state changed.
    mutating func move(_ number: Int, x: Double, y: Double, revision: Int, explicit: Bool, now: Date) -> Bool {
        guard revision == self.revision, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
              var entry = entries[number] else { return false }
        entry.tokens = min(Self.burst, entry.tokens + now.timeIntervalSince(entry.refilledAt) * Self.updatesPerSecond)
        entry.refilledAt = now
        guard entry.tokens >= 1 else { entries[number] = entry; return false }
        entry.tokens -= 1
        // A hidden or new pointer has no anchor, so its first position always counts.
        let distance = entry.anchor.map { hypot(x - $0.x, y - $0.y) } ?? .infinity
        let samePosition = entry.position.map { $0.x == x && $0.y == y } ?? false
        var changed = !samePosition
        // Only meaningful movement or an explicit tap keeps a pointer visible; repeated or tiny
        // updates from a stationary hand never reset its inactivity timer.
        if explicit || distance >= Self.meaningfulDistance {
            entry.anchor = (x, y); entry.movedAt = now
            changed = true
        }
        entry.position = (x, y)
        entries[number] = entry
        return changed && entry.movedAt.map { now.timeIntervalSince($0) < Self.idle } == true
    }
    @discardableResult mutating func hide(_ number: Int) -> Bool {
        guard var entry = entries[number], entry.position != nil else { return false }
        entry.position = nil; entry.anchor = nil; entry.movedAt = nil
        entries[number] = entry
        return true
    }
    /// A new picture invalidates every position while keeping who is participating.
    mutating func reset(revision: Int) {
        self.revision = revision
        for key in entries.keys { entries[key]?.position = nil; entries[key]?.anchor = nil; entries[key]?.movedAt = nil }
    }
    mutating func removeAll(revision: Int) { entries.removeAll(); self.revision = revision }

    func pointers(now: Date) -> [SharedPointer] {
        let visible = entries.compactMap { number, entry -> (Int, Entry, (x: Double, y: Double), TimeInterval)? in
            guard let position = entry.position, let movedAt = entry.movedAt else { return nil }
            let remaining = Self.idle - now.timeIntervalSince(movedAt)
            return remaining > 0 ? (number, entry, position, remaining) : nil
        }.sorted { $0.0 < $1.0 }
        let counts = Dictionary(grouping: entries.values, by: { $0.name.lowercased() }).mapValues(\.count)
        return visible.map { number, entry, position, remaining in
            // Equal names stay separate people; the session number distinguishes them.
            SharedPointer(number: number, label: Self.label(entry.name, number: number, duplicate: (counts[entry.name.lowercased()] ?? 0) > 1),
                          color: entry.color, x: position.x, y: position.y, remaining: remaining)
        }
    }
    func nextExpiry(now: Date) -> Date? {
        entries.values.compactMap { entry in entry.position == nil ? nil : entry.movedAt?.addingTimeInterval(Self.idle) }
            .filter { $0 > now }.min()
    }
    static func label(_ name: String, number: Int, duplicate: Bool) -> String { duplicate ? "\(name) · \(number)" : name }
}
