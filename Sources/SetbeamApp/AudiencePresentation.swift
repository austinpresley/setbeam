import Foundation
import SetbeamCore

/// Shared operator truth. A requested output is not a confirmed picture or sound state.
struct AudiencePresentation: Equatable {
    enum Phase: Equatable {
        case privateMonitoring, starting, stopping, sharing, applyingHold, resuming, holding
        case failedHold, failedResume, reconnecting
    }
    let phase: Phase
    let primaryTarget: AudienceTarget?
    let primaryEnabled: Bool

    init(session: SessionState, control: AudienceControlState, change: OutgoingTransition.Change? = nil,
         localReady: Bool, busy: Bool, stopping: Bool = false) {
        if stopping { phase = .stopping }
        else if !session.sharing { phase = change == .startSharing ? .starting : .privateMonitoring }
        else if let pending = control.pending { phase = pending.holding ? .applyingHold : .resuming }
        else if let failed = control.failed { phase = failed.holding ? .failedHold : .failedResume }
        else if !session.audienceAvailable || !session.holding && !session.sourceAvailable {
            switch change {
            case .startSharing: phase = .starting
            case .hold: phase = .applyingHold
            case .resume: phase = .resuming
            case nil: phase = .reconnecting
            }
        } else { phase = session.holding ? .holding : .sharing }
        switch phase {
        case .privateMonitoring, .starting, .stopping: primaryTarget = nil
        case .holding, .resuming, .failedResume: primaryTarget = .resume
        default: primaryTarget = .hold
        }
        primaryEnabled = !busy && ![Phase.starting, .stopping, .applyingHold, .resuming].contains(phase) && primaryTarget.map { $0.holding || localReady } == true
    }

    var isChanging: Bool { [.starting, .stopping, .applyingHold, .resuming].contains(phase) }
    var needsAttention: Bool { [.failedHold, .failedResume, .reconnecting].contains(phase) }
    var confirmedHold: Bool { phase == .holding }
    var title: String {
        switch phase {
        case .privateMonitoring: return "Private"
        case .starting: return "Starting sharing"
        case .stopping: return "Stopping sharing"
        case .sharing: return "Sharing"
        case .applyingHold: return "Applying Hold"
        case .resuming: return "Resuming sharing"
        case .holding: return "On Hold"
        case .failedHold: return "Hold did not finish"
        case .failedResume: return "Resume did not finish"
        case .reconnecting: return "Reconnecting"
        }
    }
    var symbol: String {
        if needsAttention { return "exclamationmark.circle" }
        if isChanging { return "arrow.triangle.2.circlepath" }
        if confirmedHold { return "pause.circle.fill" }
        return phase == .sharing ? "circle.fill" : "lock"
    }
    var primaryTitle: String {
        switch phase {
        case .failedHold: return "Retry Hold"
        case .failedResume: return "Retry Resume"
        default: return primaryTarget == .resume ? "Resume Sharing" : "Hold"
        }
    }
    var primarySymbol: String { primaryTarget == .resume ? "play.fill" : "pause.fill" }
    var primaryHelp: String {
        primaryTarget == .resume ? "Send the source picture and sound to viewers after a fresh local picture."
            : "Replace the outgoing source picture and sound with Hold. Your local monitor continues."
    }
    var recoveryDetail: String? {
        switch phase {
        case .failedHold: return "Holding output is not confirmed. Retry Hold or stop sharing."
        case .failedResume: return "Source output is not confirmed. Retry Resume, put viewers on Hold, or stop sharing."
        case .reconnecting: return "Outgoing picture and sound are not confirmed. Your local monitor continues."
        default: return nil
        }
    }
    var outputDetail: String {
        switch phase {
        case .privateMonitoring: return "Sharing is off"
        case .holding: return "Picture hidden · Sound off"
        case .sharing: return "Outgoing feed available"
        case .applyingHold: return "Hold is not confirmed yet"
        case .resuming: return "Source output is not confirmed yet"
        case .failedHold, .failedResume, .reconnecting: return "Outgoing picture and sound not confirmed"
        case .starting: return "Waiting for outgoing media"
        case .stopping: return "Ending viewer access"
        }
    }
    func visibleOutputDetail(pictureConfirmed: Bool, hasAudio: Bool) -> String {
        switch phase {
        case .sharing:
            return "\(pictureConfirmed ? "Picture confirmed" : "Checking outgoing picture") · \(hasAudio ? "Sound included" : "No audio track")"
        case .holding: return "Holding picture confirmed · Source audio suppressed"
        default: return outputDetail
        }
    }
    var sourceRecoveryDetail: String {
        switch phase {
        case .privateMonitoring: return "Sharing is off. Viewers cannot see or hear this source."
        case .holding: return "Viewers remain on Hold. Source picture and audio are suppressed."
        default: return "\(title). \(outputDetail)."
        }
    }
    var incomingReadyDetail: String {
        switch phase {
        case .privateMonitoring: return "Your local monitor is ready. Sharing is off."
        case .sharing: return "Your local monitor is ready. Sharing is active."
        case .holding: return "Your local monitor is ready. Viewers remain on Hold."
        default: return "Your local monitor is ready. \(title). \(outputDetail)."
        }
    }
}

enum IncomingDestination {
    /// The input binding is independent of the network selected for viewers.
    static func isLocalOnly(_ server: String) -> Bool {
        guard let host = URLComponents(string: server)?.host?.lowercased() else { return false }
        let parts = host.split(separator: ".")
        return host == "localhost" || host == "::1" || host == "[::1]" ||
            parts.count == 4 && parts.first == "127" && parts.allSatisfy { UInt8($0) != nil }
    }
}
