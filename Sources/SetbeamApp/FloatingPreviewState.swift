import Foundation
import SetbeamCore

enum AudienceTarget: Equatable {
    case hold, resume
    init(holding: Bool) { self = holding ? .hold : .resume }
    var holding: Bool { self == .hold }
}

struct FloatingAudienceSummary: Equatable {
    let waiting: Int
    let joined: Int
    init(sharing: Bool, viewers: [ViewerActivity]) {
        waiting = sharing ? viewers.filter { $0.admission == .pending }.count : 0
        joined = sharing ? viewers.filter { $0.admission == .admitted }.count : 0
    }
    var count: Int { waiting > 0 ? waiting : joined }
    var visible: Bool { count > 0 }
    var symbol: String { waiting > 0 ? "person.badge.clock" : "person.2" }
    var label: String {
        waiting > 0 ? "\(waiting) asking to join. \(joined) joined browser sessions. Show viewer actions"
            : "\(joined) joined browser sessions. Show viewer actions"
    }
}

/// Presentation observes fresh outgoing media, rather than treating a requested change as complete.
struct AudienceControlState: Equatable {
    private(set) var confirmedHolding = false
    private(set) var pending: AudienceTarget?
    private(set) var failed: AudienceTarget?
    private var running = false
    private var deadline = Date.distantPast

    mutating func begin(_ target: AudienceTarget) {
        pending = target; failed = nil; running = true
        deadline = .distantFuture
    }
    mutating func complete(_ session: SessionState, at now: Date = Date()) {
        running = false; deadline = now.addingTimeInterval(10); observe(session, at: now)
    }
    mutating func fail(_ target: AudienceTarget, session: SessionState) {
        running = false; pending = nil; failed = target
        if !session.sharing { self = Self() }
    }
    mutating func observe(_ session: SessionState, at now: Date = Date()) {
        guard session.sharing else { self = Self(); return }
        if session.audienceAvailable {
            confirmedHolding = session.holding
            if !running, pending?.holding == session.holding { pending = nil }
            if failed?.holding == session.holding { failed = nil }
        }
        if !running, let target = pending, now >= deadline { pending = nil; failed = target }
    }
}

/// One action position, driven by observed session state. Private monitoring never publishes here.
struct FloatingPreviewState: Equatable {
    enum Center: Equatable { case hidden, hold, resume, pending, recovery, failed }
    let center: Center
    let washed: Bool
    let target: AudienceTarget?
    let audience: FloatingAudienceSummary
    let enabled: Bool
    let label: String

    init(session: SessionState, control: AudienceControlState, localReady: Bool, busy: Bool, starting: Bool = false, viewers: [ViewerActivity] = []) {
        audience = FloatingAudienceSummary(sharing: session.sharing, viewers: viewers)
        guard session.sharing else {
            center = .hidden; washed = false; target = nil; enabled = false; label = "Private local preview"
            return
        }
        if let target = control.pending {
            center = .pending; washed = control.confirmedHolding; self.target = target; enabled = false
            label = target.holding ? "Applying Hold. Source picture and sound may still reach viewers." : "Resuming sharing"
        } else if let target = control.failed {
            center = .failed; washed = control.confirmedHolding && session.holding
            self.target = target; enabled = !busy && (target.holding || localReady)
            label = target.holding ? "Hold did not finish. Retry Hold for viewers." : "Resume did not finish. Retry sharing."
        } else if session.holding && control.confirmedHolding {
            center = .resume; washed = true; target = .resume; enabled = !busy && localReady
            label = localReady ? "Resume sharing with viewers. Your local picture continues." : "On Hold. Waiting for a fresh local picture before resuming."
        } else if !session.audienceAvailable {
            center = .recovery; washed = false; target = .hold; enabled = !busy
            label = starting ? "Sharing is starting. Hold source picture and sound for viewers." : "Outgoing picture reconnecting. Hold source picture and sound for viewers."
        } else {
            center = .hold; washed = false; target = .hold; enabled = !busy
            label = "Hold source picture and sound for viewers. Your local picture continues."
        }
    }
    var symbol: String {
        switch center {
        case .resume: return "play.fill"
        case .pending: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        default: return "pause.fill"
        }
    }
    func centerVisible(hovered: Bool, keyboard: Bool) -> Bool {
        switch center {
        case .hidden: return false
        case .hold, .recovery: return hovered || keyboard
        default: return true
        }
    }
}

/// The system double-click interval and drag distance guard an action, not the whole picture.
struct FloatingClickGate {
    private var lastAction = -Double.infinity
    mutating func accept(at time: TimeInterval, count: Int = 1, dragged: Bool = false, interval: TimeInterval) -> Bool {
        guard !dragged, count <= 1, time - lastAction >= interval else { return false }
        lastAction = time; return true
    }
}
