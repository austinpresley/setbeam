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
