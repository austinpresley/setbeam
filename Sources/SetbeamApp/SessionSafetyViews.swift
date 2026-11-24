import SwiftUI
import SetbeamCore

struct SetupCheckView: View {
    @ObservedObject var model: SessionModel
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Test My Setup").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                Spacer()
                Button("Done") { model.sheet = nil }.keyboardShortcut(.cancelAction)
            }
            ViewThatFits(in: .vertical) {
                checklist
                ScrollView { checklist }
            }
            .frame(maxHeight: max(240, (model.monitorWindow?.screen?.visibleFrame.height ?? 800) - 160))
        }
        .padding(24).frame(width: 560)
        .task { headingFocused = true }
        .onChange(of: model.setupCheck.passed) { _, passed in
            AccessibilityNotification.Announcement(passed ? "Current setup check passed" : "Current setup check incomplete").post()
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up a test viewer before inviting everyone. Starting the test shares your current feed.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            source
            network
            approval
            sound
            Divider()
            playback
            Label(model.setupCheck.passed ? "Current setup check passed" : "Setup check incomplete",
                  systemImage: model.setupCheck.passed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(model.setupCheck.passed ? Color.green : Color.secondary).font(.callout.weight(.medium))
            if model.state.sharing || model.canStopSharing {
                Button("Stop Sharing") { model.stopSharing() }.disabled(!model.canStopSharing)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Source", detail: model.deniedSourceRequest?.instructions ?? sourceDetail, confirmed: model.setupCheck.picture)
            if model.deniedSourceRequest != nil {
                SourcePermissionActions(model: model, offersSourceChooser: true)
            } else {
                Button(model.setupCheck.picture ? "Change Source…" : "Choose a Source…") { model.openSources() }
                    .disabled(model.busy)
            }
        }
    }

    private var sourceDetail: String {
        guard model.setup != nil else { return "Choose a source and wait for a fresh picture on this Mac." }
        if model.setup?.kind == .sample { return "Sample media. Use your actual source to rehearse a shoot." }
        return model.localReady ? model.sourceLabel : "\(model.sourceLabel) is waiting for a fresh picture on this Mac."
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Viewing Network", detail: networkDetail, confirmed: model.setupCheck.viewingAddress)
            Button("Choose Viewing Network…") { model.showViewingNetwork() }.disabled(model.busy)
        }
    }

    private var networkDetail: String {
        if let network = model.setupViewingNetwork {
            return "\(network.name) (\(network.address)). Use a test device that can reach this network."
        }
        if model.canInviteOtherDevices { return "The selected viewing network is unavailable. Check the connection or choose another network." }
        return "This Mac only. Choose a network your test device can reach."
    }

    private var approval: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Ask Before Viewers Join", isOn: Binding(get: { model.viewerApproval }, set: model.setViewerApproval))
                .disabled(model.busy || model.state.sharing || model.applyingViewerApproval)
            Text(approvalDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.state.sharing && model.viewerApproval {
                Button(model.pendingViewers.isEmpty ? "Open People" : "Review Join Requests…") { model.showSharing(.viewers) }
            }
        }
    }

    private var approvalDetail: String {
        if !model.setupApprovalReady { return "Waiting for the current viewer approval setting to take effect." }
        if model.viewerApproval { return "Admit the test device in People before it can play." }
        return "Anyone who can reach the network and has the viewing link can join."
    }

    private var sound: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Expected Sound", selection: $model.expectsAudio) {
                Text("Choose for this test").tag(nil as Bool?)
                Text("Sound is required").tag(true as Bool?)
                Text("Sound isn’t required").tag(false as Bool?)
            }.pickerStyle(.menu).fixedSize()
            if model.setup != nil {
                Text(model.state.sharing ? model.audienceAudioLabel : model.incomingAudioLabel)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.expectsAudio == true && model.state.sharing {
                Toggle("I enabled sound and heard it on the test device", isOn: $model.testSoundConfirmed)
                    .disabled(!model.canConfirmSetupSound)
            }
        }
    }

    @ViewBuilder private var playback: some View {
        if !model.state.sharing {
            Button("Start Sharing for Test") { model.startSharing() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canShare || !model.setupCheck.picture || model.setupViewingNetwork == nil || model.expectsAudio == nil)
        } else {
            let count = model.setupCheckPlayingCount
            row("Playback on Another Device", detail: count > 0
                ? "\(count) reporting fresh video for this output."
                : "Open the viewing link on a phone, tablet, or another computer and wait for playback.",
                confirmed: count > 0)
            if model.setupViewingLinkReady, let url = model.viewingInvitation?.ipURL {
                HStack(spacing: 16) {
                    QRView(payload: url.absoluteString, size: 112)
                        .accessibilityLabel("Test QR code. Use Copy Test Link for the viewing link.")
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.viewingInstructions).font(.caption).fixedSize(horizontal: false, vertical: true)
                        Button(model.copiedIPLink ? "Link Copied" : "Copy Test Link") { model.copyIPLink() }
                    }
                }
            }
            let audience = model.audiencePresentation
            if audience.phase != .sharing {
                Text(audience.outputDetail).font(.caption).foregroundStyle(.secondary)
                if audience.primaryTarget == .resume {
                    Button(audience.primaryTitle) { model.performAudienceAction() }
                        .disabled(!audience.primaryEnabled)
                }
            }
        }
    }

    private func row(_ title: String, detail: String, confirmed: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: confirmed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(confirmed ? Color.green : Color.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
            .accessibilityValue(confirmed ? "Confirmed" : "Unconfirmed")
    }
}
