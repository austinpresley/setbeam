import SwiftUI
import SetbeamCore

struct MonitorSourcePopover: View {
    @ObservedObject var model: SessionModel
    let show: (AppSheet) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current source").font(.caption).foregroundStyle(.secondary)
            Text(model.sourceLabel).font(.headline)
            Label(model.localReady ? "Picture confirmed" : model.statusLabel, systemImage: model.localReady ? "checkmark.circle" : "circle.dashed")
                .font(.caption).foregroundStyle(.secondary)
            if model.setupRemembered { Text("Setup remembered").font(.caption).foregroundStyle(.secondary) }
            Divider()
            Button("Choose source…") { model.openSources() }
            Button("Rename session…") { show(.rename) }
            Button("Connection details…") { model.openAdvanced() }
            if let previous = model.previousSourceName {
                Divider()
                Button("Return to previous source: \(previous)") { model.returnToPreviousSource() }.disabled(model.busy)
            }
        }.buttonStyle(.link).padding(18).frame(width: 270, alignment: .leading)
    }
}

struct MonitorSoundPopover: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sound on this Mac").font(.headline)
            LabeledContent("Input", value: !model.state.sourceAvailable ? "Waiting" : model.sourceHasAudio ? "Audio track received" : "No audio track")
                .accessibilityElement(children: .combine)
            LabeledContent("Mac speakers", value: model.localMuted ? "Muted" : "On")
                .accessibilityElement(children: .combine)
            Button(model.localMuted ? "Unmute this Mac" : "Mute this Mac") { model.toggleLocalSound() }
                .frame(maxWidth: .infinity).buttonStyle(.bordered).disabled(model.preview == nil)
            Text("Only affects local monitoring.").font(.caption).foregroundStyle(.secondary)
        }.font(.callout).padding(18).frame(width: 246)
    }
}

struct MonitorInvitePopover: View {
    @ObservedObject var model: SessionModel
    let show: (AppSheet) -> Void
    var body: some View {
        VStack(spacing: 14) {
            Text("Scan to watch").font(.headline)
            if model.state.sharing, let url = model.viewerURL { QRView(payload: url.absoluteString, size: 176) }
            else { ProgressView("Preparing viewing link").frame(width: 176, height: 176) }
            Text(model.viewingInstructions).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(model.copiedLink ? "Link copied" : "Viewing link").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.copyLink() } label: { Image(systemName: model.copiedLink ? "checkmark" : "link").frame(width: 24, height: 22) }
                    .help(model.copiedLink ? "Link copied" : "Copy viewing link")
                    .accessibilityLabel(model.copiedLink ? "Link copied" : "Copy viewing link")
                    .disabled(model.viewerURL == nil || !model.state.sharing)
            }.padding(7).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
            Button("Show join codes…") { model.loadPrivateSettings(); show(.join) }
                .buttonStyle(.link).font(.caption).disabled(!model.state.sharing)
            if model.viewerAddress == "127.0.0.1" {
                Button("Open Wi-Fi Settings") { model.openWiFiSettings() }.buttonStyle(.link).font(.caption)
            }
        }.padding(18).frame(width: 252)
    }
}

struct MonitorSharingPopover: View {
    @ObservedObject var model: SessionModel
    let show: (AppSheet) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.state.sharing {
                AudiencePreviewView(model: model, player: model.audiencePlayer)
                LabeledContent("Audience sound", value: model.state.holding ? "Silent" : model.state.audience != .live ? "Reconnecting" : model.audienceHasAudio ? "Included" : "No audio track")
                    .font(.caption).accessibilityElement(children: .combine)
                Divider()
                LabeledContent("Playing", value: "\(model.verifiedViewers)")
                    .accessibilityElement(children: .combine)
                LabeledContent("Opened the link", value: "\(model.openedViewers)")
                    .accessibilityElement(children: .combine)
                Button("Viewer details…") { show(.viewers) }.buttonStyle(.link).font(.caption)
            } else {
                Text("Private monitoring").font(.headline)
                Text("Sharing is off. Your picture stays on this Mac.").font(.callout).foregroundStyle(.secondary)
            }
        }.font(.callout).padding(18).frame(width: 280)
    }
}

struct SessionNameView: View {
    @ObservedObject var model: SessionModel
    @State private var name: String
    init(model: SessionModel) { self.model = model; _name = State(initialValue: model.title) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename session").font(.title2.weight(.semibold))
            TextField("Session name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 360)
    }
    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        model.title = trimmed.isEmpty ? "My feed" : trimmed
        model.sheet = nil
    }
}
