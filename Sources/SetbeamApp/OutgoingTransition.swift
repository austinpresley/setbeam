import Foundation

/// Only an explicit audience change gets a bounded preparation state.
/// Fresh output ends that state, so later failures are reported immediately.
struct OutgoingTransition: Equatable {
    enum Change: Equatable {
        case startSharing, hold, resume
        var title: String {
            switch self {
            case .startSharing: return "Starting sharing"
            case .hold: return "Applying Hold"
            case .resume: return "Resuming sharing"
            }
        }
    }
    private var change: Change?
    private var deadline = Date.distantPast

    mutating func begin(_ change: Change, at now: Date = Date()) {
        self.change = change
        deadline = now.addingTimeInterval(10)
    }
    func activeChange(at now: Date = Date()) -> Change? { now < deadline ? change : nil }
    mutating func observeReady(_ ready: Bool) { if ready { reset() } }
    mutating func reset() { change = nil; deadline = .distantPast }
}
