import Foundation

enum SharingSection: String, CaseIterable, Identifiable {
    case invite = "Invite", viewers = "Viewers", options = "Options", chat = "Chat"
    var id: String { rawValue }
}

enum SettingsSection: String { case permissions, diagnostics }

enum SharingDestination: Equatable {
    case hidden, inline, window
    static func resolve(section: SharingSection?, preferWindow: Bool, hasSheet: Bool, screenWidth: CGFloat) -> Self {
        guard section != nil else { return .hidden }
        return preferWindow || hasSheet || !SharingPanelLayout.fits(on: screenWidth) ? .window : .inline
    }
}

enum ViewerRequestPresentation {
    static func isVisible(appActive: Bool, section: SharingSection?, detached: Bool,
                          keyIsMonitor: Bool, keyIsSharing: Bool, hasSheet: Bool) -> Bool {
        appActive && section == .viewers && (detached ? keyIsSharing : keyIsMonitor && !hasSheet)
    }
}

/// Opening the optional panel preserves the monitor width whenever the screen has room.
/// Smaller screens use a separate Sharing window instead of covering the picture with a sheet.
enum SharingPanelLayout {
    static let width: CGFloat = 320
    static let extraWidth = width + 1
    static let minimumMonitorWindow: CGFloat = 640
    static func fits(on screenWidth: CGFloat) -> Bool {
        screenWidth >= minimumMonitorWindow + extraWidth
    }
}
