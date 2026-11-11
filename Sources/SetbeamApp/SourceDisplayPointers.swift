import AppKit
import SwiftUI
import SetbeamCore

/// Runs in the capturing app, whose windows ScreenCaptureKit excludes from the received feed.
@MainActor final class SourceDisplayPointers {
    private var panel: NSPanel?
    private var displayID: String?
    var windowNumber: Int? { panel?.isVisible == true ? panel?.windowNumber : nil }
    static func screen(for identity: String, in screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return MacDisplay.identity(number.uint32Value)?.caseInsensitiveCompare(identity) == .orderedSame
        }
    }
    func update(display identity: String?, visible: Bool, presence: PointerPresenceModel) {
        guard visible, let identity, let screen = Self.screen(for: identity) else { close(); return }
        if identity != displayID { close() }
        if panel == nil {
            let panel = PointerPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            panel.isExcludedFromWindowsMenu = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: PointerOverlay(presence: presence).accessibilityHidden(true))
            self.panel = panel; displayID = identity
        }
        if panel?.frame != screen.frame { panel?.setFrame(screen.frame, display: true) }
        panel?.orderFrontRegardless()
    }
    func close() { panel?.orderOut(nil); panel?.close(); panel = nil; displayID = nil }
    private final class PointerPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
}
