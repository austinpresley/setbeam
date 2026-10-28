import SwiftUI
import SetbeamCore

struct AudiencePreviewView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var player: NativePreview
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Viewers see").font(.caption.weight(.medium))
            ZStack {
                Color.black
                if model.audiencePreviewPlaying && model.state.audienceAvailable, let picture = player.picture {
                    PictureView(picture: picture)
                } else {
                    VStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Checking outgoing picture").font(.caption2).multilineTextAlignment(.center)
                    }.padding(8).foregroundStyle(.white)
                }
            }.aspectRatio(16.0 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 6))
            Text(model.state.holding ? "On Hold · source picture and sound hidden" : model.outgoingNeedsAttention ? "Outgoing picture reconnecting" : model.audiencePreviewPlaying && model.state.audience == .live ? "Outgoing picture confirmed" : "Checking outgoing preview")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}

struct SetupCheckView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Test my setup").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { model.sheet = nil }.keyboardShortcut(.cancelAction)
            }
            Text("Confirm the current picture on another device before inviting everyone. Starting this test shares your feed.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            row("Fresh picture on this Mac", detail: model.localReady ? model.sourceLabel : "Connect a source and wait for a fresh picture.", passed: model.setupCheck.picture)
            row("Viewing address available", detail: model.setupCheck.viewingAddress ? model.viewingInstructions : "Start sharing on a network your viewers can join.", passed: model.setupCheck.viewingAddress)
            row("Playback on another device", detail: model.otherDeviceViewers > 0 ? "\(model.otherDeviceViewers) other-device browser(s) reporting fresh video." : "Scan the code on a phone or another computer. A browser on this Mac does not complete this check.", passed: model.setupCheck.otherDevicePlaying)
            if model.state.sharing && !model.canInviteOtherDevices {
                ViewingNetworkRequiredView(model: model)
            } else if model.state.sharing, let url = model.viewerURL {
                HStack(spacing: 18) {
                    QRView(payload: url.absoluteString, size: 144)
                    VStack(alignment: .leading, spacing: 9) {
                        Text(model.viewingInstructions).font(.caption).fixedSize(horizontal: false, vertical: true)
                        Button(model.copiedLink ? "Link copied" : "Copy viewing link") { model.copyLink() }
                        if model.state.holding {
                            Text("Viewers are on Hold. Inspect your picture before resuming.").font(.caption).foregroundStyle(.secondary)
                            Button("Resume sharing to test") { model.toggleHold() }.disabled(!model.canShare)
                        }
                    }
                }
            } else {
                Button("Start sharing for test") { model.startSharing() }.buttonStyle(.borderedProminent).disabled(!model.canShare)
            }
            Divider()
            Toggle("This feed should include sound", isOn: $model.expectsAudio)
            if model.expectsAudio {
                row("Source audio included", detail: model.audienceAudioLabel, passed: model.audienceHasAudio && model.state.audience == .live)
                Toggle("I enabled sound and heard it on the other device", isOn: $model.testSoundConfirmed)
                    .disabled(model.otherDeviceViewers == 0 || !model.audienceHasAudio || model.state.audience != .live)
                Text("An audio track alone does not confirm audible sound. Tap Enable sound in the viewer and listen.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Label(model.setupCheck.passed ? "Current setup check passed" : "Setup check incomplete", systemImage: model.setupCheck.passed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(model.setupCheck.passed ? Color.green : Color.secondary).font(.callout.weight(.medium))
            if model.setup?.kind == .sample { Text("This checks sample media. It does not verify your physical input.").font(.caption).foregroundStyle(.secondary) }
            if model.state.sharing { Button("Stop sharing") { model.stopSharing() }.disabled(model.busy) }
        }.padding(28).frame(width: 540)
    }
    private func row(_ title: String, detail: String, passed: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(passed ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }
}
