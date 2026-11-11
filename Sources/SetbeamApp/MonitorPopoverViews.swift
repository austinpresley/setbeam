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

/// Session options for who can watch and whether admitted viewers can point.
struct ViewerOptions: View {
    @ObservedObject var model: SessionModel
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SharingSwitch(title: "Viewers can point", detail: compact ? "" : "Viewers can point at the picture. Other pointing viewers see their name and color.",
                hint: "Viewers can point at the picture. Other pointing viewers see their name and color.",
                isOn: Binding(get: { model.sharedPointers }, set: { model.setSharedPointers($0) }))
            SharingSwitch(title: "Show pointers on this Mac", detail: compact ? "Local monitor and floating preview only." : "Draws viewers' pointers over your monitor and floating preview until sharing stops. Never sent in the picture.",
                hint: "Draws viewers' pointers over your monitor and floating preview until sharing stops. Never sent in the picture. External sending computers cannot be drawn on from this Mac.",
                isOn: Binding(get: { model.pointersOnThisMac }, set: { model.setPointersOnThisMac($0) }))
                .disabled(!model.sharedPointers).padding(.leading, compact ? 0 : 20)
            if model.setup?.kind == .macScreen {
                SharingSwitch(title: "Show pointers on shared display", detail: "Draws on the selected display without taking clicks or appearing in its captured video. Resets at Stop or a display change.",
                    isOn: Binding(get: { model.pointersOnSourceDisplay }, set: { model.setPointersOnSourceDisplay($0) }))
                    .disabled(!model.canShowPointersOnSourceDisplay).padding(.leading, compact ? 0 : 20)
            } else if !compact {
                Text("Pointers on the source display require This Mac's screen. External sending computers cannot be drawn on from this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.toggleStyle(.switch).controlSize(.small)
    }
}
