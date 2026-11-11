import Foundation
import SetbeamCore

enum SourceCategory: String, CaseIterable, Identifiable {
    case displays, cameras, windows, wireless
    var id: Self { self }
    var name: String {
        switch self {
        case .displays: return "Displays"
        case .cameras: return "Cameras & capture"
        case .windows: return "Application windows"
        case .wireless: return "Wireless transmitters"
        }
    }
    var symbol: String {
        switch self {
        case .displays: return "display"
        case .cameras: return "camera"
        case .windows: return "macwindow"
        case .wireless: return "antenna.radiowaves.left.and.right"
        }
    }
    static func initial(for source: SourceSetup?) -> Self {
        switch source?.kind {
        case .macScreen: return .displays
        case .capture: return .cameras
        case .network, .incoming, .accsoon: return .wireless
        default: return .windows
        }
    }
}

enum SourceChooserSelection {
    static func name(for saved: SourceSetup, window: MacWindow?) -> String {
        guard saved.kind == .macWindow else { return saved.name }
        if let window, window.identity == saved.window { return window.label }
        if let application = saved.deviceName {
            let prefix = application + " · "
            if saved.name.hasPrefix(prefix) { return String(saved.name.dropFirst(prefix.count)) }
        }
        return saved.name
    }

    /// These are source identities, never labels or thumbnail positions.
    static func matches(_ saved: SourceSetup, _ current: SourceSetup?) -> Bool {
        guard let current, saved.kind == current.kind else { return false }
        switch saved.kind {
        case .macWindow: return saved.window != nil && saved.window == current.window
        case .macScreen: return saved.videoID != nil && saved.videoID?.caseInsensitiveCompare(current.videoID ?? "") == .orderedSame
        case .capture: return saved.videoID != nil && saved.videoID == current.videoID && saved.audioID == current.audioID
        case .accsoon: return saved.wirelessUID != nil && saved.wirelessUID == current.wirelessUID
        case .network, .incoming: return saved.id == current.id
        case .sample: return false
        }
    }
}

/// Availability describes the complete saved capture route, including its explicit sound input.
enum SourceChooserAvailability {
    static func capture(_ saved: SourceSetup, devices: [CaptureHardware], cameraAllowed: Bool, microphoneAllowed: Bool) -> (text: String, available: Bool, unavailable: Bool) {
        guard cameraAllowed else { return ("Needs camera access", false, false) }
        if saved.audioID != nil && !microphoneAllowed { return ("Needs microphone access", false, false) }
        guard devices.contains(where: { !$0.audio && $0.id == saved.videoID }) else { return ("Device disconnected", false, true) }
        if let audio = saved.audioID, !devices.contains(where: { $0.audio && $0.id == audio }) {
            return ("Sound input disconnected", false, true)
        }
        return ("Available", true, false)
    }
}
