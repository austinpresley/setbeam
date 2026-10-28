import SwiftUI
import AppKit

@MainActor @main struct SetbeamApp: App {
    @StateObject private var model: SessionModel
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    init() {
        let args = CommandLine.arguments
        if let icon = AppAssets.icon { NSApplication.shared.applicationIconImage = icon }
        if args.contains("--preferences-suite"), let index = args.firstIndex(of: "--appearance"), index + 1 < args.count {
            NSApplication.shared.appearance = NSAppearance(named: args[index + 1] == "light" ? .aqua : .darkAqua)
        }
        let value = SessionModel(); _model = StateObject(wrappedValue: value); ApplicationDelegate.model = value
    }
    var body: some Scene {
        Window("Setbeam", id: "main") { MainView(model: model) }
            .defaultSize(width: 900, height: 636)
            .windowToolbarStyle(.unified)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .appInfo) { Button("About Setbeam") { model.sheet = .about } }
                CommandGroup(replacing: .newItem) {}
                CommandMenu("Feed") {
                    Button(model.pipVisible ? "Hide Floating Preview" : "Show Floating Preview") { model.togglePiP() }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(model.preview == nil)
                    Button("Save Frame") { model.saveFrame() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!model.localReady)
                    Button(model.localMuted ? "Unmute This Mac" : "Mute This Mac") { model.toggleLocalSound() }.disabled(model.preview == nil)
                    Divider()
                    Button("Start Sharing") { model.startSharing() }.keyboardShortcut(.return, modifiers: .command).disabled(model.state.sharing || !model.canShare)
                    Button(model.state.holding ? "Resume Sharing" : "Hold Audience") { model.toggleHold() }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(!model.state.sharing || model.busy || model.state.holding && !model.localReady)
                    Button("Stop Sharing") { model.stopSharing() }.disabled(!model.state.sharing || model.busy)
                    Button("Show Join Codes…") { model.loadPrivateSettings(); model.sheet = .join }.disabled(!model.state.sharing)
                    Button("Copy Viewing Link") { model.copyLink() }.disabled(!model.state.sharing)
                    Button("Picture and Viewers…") { model.sheet = .viewers }
                    Divider()
                    Button("Choose Source…") { model.openSources() }.keyboardShortcut("o", modifiers: .command)
                    Button("Rename Session…") { model.sheet = .rename }
                    Button("Picture Settings…") { model.sheet = .picture }
                    Button("Advanced…") { model.openAdvanced() }.keyboardShortcut(",", modifiers: .command)
                    Button("Test My Setup…") { model.sheet = .setupCheck }
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
        } else { Button("Start Sharing") { model.startSharing() }.disabled(!model.canShare) }
        Divider(); Button("Quit Setbeam") { NSApp.terminate(nil) }
    }
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    static weak var model: SessionModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model = Self.model, model.state.sharing {
            let alert = NSAlert()
            alert.messageText = "Quit and end sharing?"
            let count = model.openedViewers
            alert.informativeText = count > 0 ? "\(count) viewer browser(s) are connected. Quitting ends their session and stops local monitoring." : "Sharing is active. Quitting ends the viewing session and stops local monitoring."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Keep Sharing")
            alert.addButton(withTitle: "Quit and End Sharing")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        Task { await Self.model?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
