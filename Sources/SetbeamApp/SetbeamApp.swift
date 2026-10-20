import SwiftUI
import AppKit

@MainActor @main struct SetbeamApp: App {
    @StateObject private var model: SessionModel
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    init() {
        let value = SessionModel(); _model = StateObject(wrappedValue: value); ApplicationDelegate.model = value
    }
    var body: some Scene {
        Window("Setbeam", id: "main") { MainView(model: model) }
            .defaultSize(width: 820, height: 550)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .appInfo) { Button("About Setbeam") { model.sheet = .about } }
                CommandGroup(replacing: .newItem) {}
                CommandMenu("Feed") {
                    Button(model.pipVisible ? "Hide Floating Preview" : "Show Floating Preview") { model.togglePiP() }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(model.preview == nil)
                    Button("Save Frame") { model.saveFrame() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!model.state.sourceAvailable)
                    Divider()
                    Button(model.state.holding ? "Resume Sharing" : "Hold Audience") { model.toggleHold() }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(!model.state.sharing)
                    Button("Connection Settings…") { model.loadPrivateSettings(); model.sheet = .connection }.keyboardShortcut(",", modifiers: .command)
                }
            }
        MenuBarExtra("Setbeam", systemImage: model.state.sharing ? "dot.radiowaves.left.and.right" : "rectangle.on.rectangle") {
            SetbeamMenu(model: model)
        }
    }
}

private struct SetbeamMenu: View {
    @ObservedObject var model: SessionModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.title); Text(model.statusLabel)
        Divider()
        Button("Show Setbeam") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(model.pipVisible ? "Hide Floating Preview" : "Show Floating Preview") { model.togglePiP() }.disabled(model.preview == nil)
        if model.state.sharing {
            Button(model.state.holding ? "Resume Sharing" : "Hold Audience") { model.toggleHold() }
            Button("Copy Viewing Link") { model.copyLink() }
            Button("Stop Sharing") { model.stopSharing() }
        } else { Button("Start Sharing") { model.startSharing() }.disabled(!model.state.monitoring) }
        Divider(); Button("Quit Setbeam") { NSApp.terminate(nil) }
    }
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    static weak var model: SessionModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await Self.model?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
