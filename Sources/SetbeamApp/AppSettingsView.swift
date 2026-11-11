import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        TabView(selection: Binding(get: { model.settingsSection }, set: { model.selectSettings($0) })) {
            PermissionsView(model: model, inSettings: true)
                .tabItem { Label("Permissions", systemImage: "hand.raised") }.tag(SettingsSection.permissions)
            DiagnosticsView(model: model, inSettings: true)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }.tag(SettingsSection.diagnostics)
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

