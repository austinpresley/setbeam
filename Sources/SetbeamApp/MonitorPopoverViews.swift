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
            if model.setup?.kind != .sample { Button("Play Sample") { model.openSample() }.disabled(model.busy) }
            Button("Rename session…") { show(.rename) }
            Button("Source details…") { model.openSourceDetails() }.disabled(model.busy)
            if let previous = model.previousSourceName {
                Divider()
                Button("Return to previous source: \(previous)") { model.returnToPreviousSource() }.disabled(model.busy || model.protectsSourceDraft)
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
            LabeledContent("Local sound", value: model.localMuted ? "Muted" : "Unmuted")
                .accessibilityElement(children: .combine)
            Button(model.localMuted ? "Unmute this Mac" : "Mute this Mac") { model.toggleLocalSound() }
                .frame(maxWidth: .infinity).buttonStyle(.bordered).disabled(model.preview == nil)
            Text("Only affects local monitoring.").font(.caption).foregroundStyle(.secondary)
        }.font(.callout).padding(18).frame(width: 246)
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
