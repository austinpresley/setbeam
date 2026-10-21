import Foundation

/// Connection milestones, independent of audience sharing and elapsed time.
public enum ConnectionStage: String, Sendable {
    case preparingMonitor, findingTransmitter, connectingTransmitter, waitingForPicture, openingPreview

    public var title: String {
        switch self {
        case .preparingMonitor: return "Preparing monitor"
        case .findingTransmitter: return "Finding transmitter"
        case .connectingTransmitter: return "Connecting to transmitter"
        case .waitingForPicture: return "Waiting for picture"
        case .openingPreview: return "Opening preview"
        }
    }

    public static func steps(for kind: InputKind) -> [ConnectionStage] {
        kind == .accsoon
            ? [.preparingMonitor, .findingTransmitter, .connectingTransmitter, .waitingForPicture, .openingPreview]
            : [.preparingMonitor, .waitingForPicture, .openingPreview]
    }

    static func resolve(serverReady: Bool, sourceFresh: Bool, isTransmitter: Bool,
                        transmitterFound: Bool, receiverRunning: Bool, connectionAcknowledged: Bool) -> ConnectionStage {
        guard serverReady else { return .preparingMonitor }
        if sourceFresh { return .openingPreview }
        guard isTransmitter else { return .waitingForPicture }
        guard receiverRunning else { return transmitterFound ? .connectingTransmitter : .findingTransmitter }
        return connectionAcknowledged ? .waitingForPicture : .connectingTransmitter
    }
}
