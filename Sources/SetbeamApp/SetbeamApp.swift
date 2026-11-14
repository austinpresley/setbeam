import SwiftUI
import AppKit

@MainActor @main struct SetbeamApp: App {
    @StateObject private var model: SessionModel
    @StateObject private var updater: AppUpdater
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    init() {
        let args = CommandLine.arguments
        if let icon = AppAssets.icon { NSApplication.shared.applicationIconImage = icon }
        if args.contains("--preferences-suite"), let index = args.firstIndex(of: "--appearance"), index + 1 < args.count {
            NSApplication.shared.appearance = NSAppearance(named: args[index + 1] == "light" ? .aqua : .darkAqua)
        }
        let value = SessionModel(); _model = StateObject(wrappedValue: value); ApplicationDelegate.model = value
        let updates = AppUpdater(); updates.isSharing = { [weak value] in value?.state.sharing ?? false }
        _updater = StateObject(wrappedValue: updates)
    }
    var body: some Scene {
        monitorScene
        Window("Sharing", id: "sharing") { SharingWindowView(model: model) }
            .defaultSize(width: 360, height: 640)
            .windowResizability(.contentMinSize)
        Settings { AppSettingsView(model: model, updater: updater) }
        MenuBarExtra("Setbeam", systemImage: !model.joinRequests.requests.isEmpty ? "person.badge.clock" : model.state.sharing ? "dot.radiowaves.left.and.right" : "rectangle.on.rectangle") {
            SetbeamMenu(model: model, updater: updater)
        }
    }
    private var monitorScene: some Scene {
        let action = openWindow
        model.openMonitor = { action(id: "main") }
        return Window("Setbeam", id: "main") { MainView(model: model) }
            .defaultSize(width: 900, height: 636)
            .windowToolbarStyle(.unified)
            .windowResizability(.contentMinSize)
            .commands { SetbeamCommands(model: model, updater: updater) }
    }
}

private struct SetbeamCommands: Commands {
    @ObservedObject var model: SessionModel
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Setbeam") { show(.about) }.disabled(model.protectsSourceDraft)
            if updater.availability == .enabled {
                Button(updater.waitingVersion.map { "Update Available: \($0)…" } ?? "Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck && updater.waitingVersion == nil)
            }
        }
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Source") {
            Button("Choose Source…") { main(); model.openSources() }.keyboardShortcut("o", modifiers: .command).disabled(model.protectsSourceDraft || model.busy)
            Button("Enter Stream Address…") { main(); model.openNetworkSource() }.disabled(model.protectsSourceDraft || model.busy)
            Button("Source Details…") { main(); model.openSourceDetails() }.disabled(model.setup == nil || model.protectsSourceDraft || model.busy)
            if let previous = model.previousSourceName {
                Button("Return to Previous Source: \(previous)") { model.returnToPreviousSource() }.disabled(model.busy || model.protectsSourceDraft)
            }
            Divider()
            Button("Rename Session…") { show(.rename) }.disabled(model.protectsSourceDraft)
        }
        CommandMenu("Monitor") {
            Button(model.pipVisible ? "Hide Floating Preview" : "Show Floating Preview") { model.togglePiP() }
                .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(model.preview == nil)
            Button("Focus Floating Preview") { model.focusFloatingPreview() }.disabled(model.preview == nil)
            Button("Save Frame") { model.saveFrame() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!model.localReady)
            Button(model.localMuted ? "Unmute This Mac" : "Mute This Mac") { model.toggleLocalSound() }.disabled(model.preview == nil)
            Toggle("Show Viewer Pointers on This Mac", isOn: Binding(get: { model.pointersOnThisMac }, set: { model.setPointersOnThisMac($0) }))
                .disabled(!model.sharedPointers)
            Toggle("Show Pointers on Shared Display", isOn: Binding(get: { model.pointersOnSourceDisplay }, set: { model.setPointersOnSourceDisplay($0) }))
                .disabled(!model.canShowPointersOnSourceDisplay)
        }
        CommandMenu("Sharing") {
            Button("Start Sharing") { model.startSharing() }.keyboardShortcut(.return, modifiers: .command).disabled(model.state.sharing || !model.canShare || model.busy)
            Button(model.audiencePresentation.primaryTitle) { model.performAudienceAction() }
                .keyboardShortcut("h", modifiers: [.command, .shift]).disabled(!model.state.sharing || !model.audiencePresentation.primaryEnabled)
            Button("Stop Sharing") { model.stopSharing() }.disabled(!model.state.sharing || model.busy)
            Divider()
            Button("Invite Viewers") { sharing(.invite) }.keyboardShortcut("1", modifiers: .command)
            Button("Show Viewers") { sharing(.viewers) }.keyboardShortcut("2", modifiers: .command)
            Button("Sharing Options…") { sharing(.options) }.keyboardShortcut("3", modifiers: .command)
            Button("Show Chat") { sharing(.chat) }.keyboardShortcut("4", modifiers: .command)
            Button(model.sharingInWindow ? "Show Sharing Beside Monitor" : "Open Sharing in Window") {
                if model.sharingInWindow { model.dockSharing() }
                else { sharing(model.sharingSection ?? .invite); model.showSharingInWindow() }
            }.disabled(model.sharingInWindow && !model.sharingCanDock)
            Divider()
            Button("Show Large Join Codes…") { main(); model.showJoinCodes() }.disabled(!model.state.sharing && model.wifiSSID.isEmpty || model.protectsSourceDraft)
            Button("Open Join Codes in Window") { model.showJoinCodeWindow() }.disabled(!model.state.sharing && model.wifiSSID.isEmpty)
            Button("Copy Viewing Link") { model.copyLink() }.disabled(!model.state.sharing || !model.canInviteOtherDevices)
            Button("Show Join Requests") { model.joinRequests.show() }.disabled(model.pendingViewers.isEmpty)
        }
        CommandGroup(replacing: .help) {
            Button("Test My Setup…") { show(.setupCheck) }.disabled(model.protectsSourceDraft)
            Button("Permissions…") { model.selectSettings(.permissions); openSettings() }
            Button("Diagnostics…") { model.selectSettings(.diagnostics); openSettings() }
        }
    }
    private func main() { model.reopenMonitor() }
    private func show(_ sheet: AppSheet) { main(); model.present(sheet) }
    private func sharing(_ section: SharingSection) { main(); model.showSharing(section) }
}

private struct SetbeamMenu: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Setbeam") { model.reopenMonitor() }
        Text(model.title); Text(model.statusLabel)
        Divider()
        // Requests stay here until answered, whether or not their card is showing.
        if !model.joinRequests.requests.isEmpty {
            Menu("Join Requests (\(model.joinRequests.requests.count))") {
                ForEach(model.joinRequests.requests) { request in
                    Menu("\(request.name) · session \(request.number)") {
                        Button("Admit") { model.joinRequests.answer(request, admit: true) }
                        Button("Decline") { model.joinRequests.answer(request, admit: false) }
                    }
                }
            }
            Divider()
        }
        if model.state.sharing {
            Button(model.audiencePresentation.primaryTitle) { model.performAudienceAction() }.disabled(!model.audiencePresentation.primaryEnabled)
            Button("Stop Sharing") { model.stopSharing() }.disabled(model.busy)
        } else { Button("Start Sharing") { model.startSharing() }.disabled(!model.canShare || model.busy) }
        Button(model.pipVisible ? "Hide Floating Preview" : "Show Floating Preview") { model.togglePiP() }.disabled(model.preview == nil)
        Menu("Sharing") {
            Button("Invite Viewers") { show(.invite) }
            Button("Show Viewers") { show(.viewers) }
            Button(model.chatUnreadCount > 0 ? "Show Chat (\(model.chatUnreadCount) Unread)" : "Show Chat") { show(.chat) }
            Button("Copy Viewing Link") { model.copyLink() }.disabled(!model.state.sharing || !model.canInviteOtherDevices)
            Button("Show Join Codes") { model.showJoinCodeWindow() }.disabled(!model.state.sharing && model.wifiSSID.isEmpty)
        }
        if let version = updater.waitingVersion {
            Divider(); Button("Update Available: \(version)…") { updater.checkForUpdates() }
        }
        Divider(); Button("Quit Setbeam") { NSApp.terminate(nil) }
    }
    private func show(_ section: SharingSection) {
        model.reopenMonitor(); model.showSharing(section)
    }
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    static weak var model: SessionModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.model?.launch()
        DispatchQueue.main.async { Self.model?.reopenMonitor() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.model?.reopenMonitor()
        return false
    }
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
