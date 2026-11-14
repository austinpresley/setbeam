import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var updater: AppUpdater
    var body: some View {
        TabView(selection: Binding(get: { model.settingsSection }, set: { model.selectSettings($0) })) {
            PermissionsView(model: model, inSettings: true)
                .tabItem { Label("Permissions", systemImage: "hand.raised") }.tag(SettingsSection.permissions)
            DiagnosticsView(model: model, inSettings: true)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }.tag(SettingsSection.diagnostics)
            UpdatesView(updater: updater)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag(SettingsSection.updates)
        }.frame(width: 640)
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: SessionModel
    var inSettings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Diagnostics").font(.title2.weight(.semibold))
            Text("Connection, recovery, and sharing events help explain a problem with this session.")
                .foregroundStyle(.secondary)
            Button(model.diagnosticCopied ? "Diagnostics Copied" : "Copy Diagnostics") { model.diagnostics() }
            Button("Show Session Log") { model.revealSessionLog() }
            Text("Logs leave out stream addresses, passwords, keys, and viewing links.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Device detection does not establish transmitter compatibility. Physical connection tests are recorded separately.")
                .font(.caption).foregroundStyle(.secondary)
            if !inSettings {
                HStack { Spacer(); Button("Done") { model.sheet = nil }.keyboardShortcut(.defaultAction) }
            }
        }.padding(24).frame(width: inSettings ? nil : 480, alignment: .leading)
    }
}


struct UpdatesView: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Updates").font(.title2.weight(.semibold))
            Text("Setbeam \(updater.currentVersion)").textSelection(.enabled)
            Text(updater.availability.explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if updater.availability == .enabled {
                Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.setAutomaticChecks($0) }))
                HStack(spacing: 12) {
                    Button(updater.waitingVersion.map { "Show Update \($0)" } ?? "Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheck && updater.waitingVersion == nil)
                    if let date = updater.lastChecked {
                        Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("An update found while you're sharing waits until you open it. Installing during a share asks before ending it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }
}
