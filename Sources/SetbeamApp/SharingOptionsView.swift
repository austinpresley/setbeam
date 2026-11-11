import SwiftUI
import SetbeamCore

struct SharingOptionsView: View {
    @ObservedObject var model: SessionModel
    private var draft: Binding<SharingOptionsDraft> {
        Binding(get: { model.sharingDraft ?? SharingOptionsDraft(address: model.localAddressLabel, network: model.networkChoice, quality: model.audienceQuality, frameRate: model.audienceFrameRate) },
                set: { model.sharingDraft = $0 })
    }
    private var localProblem: LocalAddressName.Problem? {
        guard case .failure(let problem) = LocalAddressName.validated(draft.wrappedValue.address) else { return nil }
        return problem
    }
    private var addressChanged: Bool { draft.wrappedValue.address != model.localAddressLabel }
    private var outputChanged: Bool { draft.wrappedValue.quality != model.audienceQuality || draft.wrappedValue.frameRate != model.audienceFrameRate }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewerNetworkEditor(model: model).id("viewing-network")
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Joining").font(.headline)
                SharingSwitch(title: "Ask before viewers join", detail: approvalDetail,
                    isOn: Binding(get: { model.viewerApproval }, set: { model.setViewerApproval($0) }))
                if model.canInviteOtherDevices {
                    SharingSwitch(title: "Offer a local address", isOn: Binding(
                        get: { model.localAddressEnabled },
                        set: { model.setLocalAddress(enabled: $0, label: model.localAddressLabel) }
                    ))
                    if model.localAddressEnabled {
                        HStack(spacing: 4) {
                            TextField("Local address name", text: draft.address).textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Local address name").onSubmit(applyAddress)
                            Text(".local").foregroundStyle(.secondary)
                        }
                        if let localProblem { Text(localProblem.message).font(.caption).foregroundStyle(.orange) }
                        if addressChanged {
                            Text("Not applied. This draft is kept when you close Sharing.").font(.caption).foregroundStyle(.secondary)
                            Button("Apply Address", action: applyAddress).disabled(localProblem != nil)
                            if model.state.sharing {
                                Text("Viewers using the previous name need the new link.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Label(model.localAddressStatus.text.unbrokenHyphens, systemImage: model.localAddressStatus.attention ? "exclamationmark.triangle" : "link")
                            .font(.caption).foregroundStyle(model.localAddressStatus.attention ? .orange : .secondary)
                        Text("The full viewing link keeps its private code. QR codes use the IP address for devices that cannot open .local names.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    SharingSwitch(title: "Let viewers ask from the short address", detail: shortAddressDetail,
                        isOn: Binding(get: { model.viewerApproval && model.localAddressEnabled && model.shortAddressEnabled }, set: { model.setShortAddress(enabled: $0) }))
                        .disabled(!model.viewerApproval || !model.localAddressEnabled).padding(.leading, 20)
                    if model.shortAddressEnabled && model.viewerApproval && model.localAddressEnabled {
                        Label(model.shortAddressStatus.text, systemImage: model.shortAddressStatus.attention ? "exclamationmark.triangle" : "keyboard")
                            .font(.caption).foregroundStyle(model.shortAddressStatus.attention ? .orange : .secondary).padding(.leading, 20)
                    }
                } else {
                    Text("Address joining is unavailable on This Mac only. Choose a viewing network above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Pointers").font(.headline)
                ViewerOptions(model: model)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Viewer output").font(.headline)
                Picker("Picture quality", selection: draft.quality) {
                    ForEach(AudienceQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityLabel("Viewer picture quality")
                Picker("Frame rate", selection: draft.frameRate) {
                    ForEach(VideoFrameRate.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityLabel("Viewer frame rate")
                Text("Applies only to viewers. Changes reconnect their picture. Your local monitor continues.")
                    .font(.caption).foregroundStyle(.secondary)
                if outputChanged { Text("Not applied. This draft is kept when you close Sharing.").font(.caption).foregroundStyle(.secondary) }
                Button("Apply Viewer Output") {
                    let value = draft.wrappedValue
                    model.setVideoSettings(quality: value.quality, frameRate: value.frameRate, screenRate: model.screenFrameRate)
                }.disabled(model.busy || !outputChanged)
            }
        }.controlSize(.small).onAppear { model.prepareSharingDraft() }
    }
    private var approvalDetail: String {
        if let host = model.shortAddressHost {
            return "Viewers enter a name and wait for you to admit them, including anyone who types \(host)."
        }
        if model.shortAddressEnabled && model.localAddressEnabled && !model.viewerApproval {
            return "Viewers enter a name and wait for you to admit them. Needed for viewers to ask from \(LocalAddressName.host(model.localAddressLabel))."
        }
        return "Viewers enter a name and wait for you to admit them."
    }
    private var shortAddressDetail: String {
        let saved = model.shortAddressEnabled ? " Your saved choice is kept." : ""
        if !model.viewerApproval { return "Inactive. Requires Ask before viewers join." + saved }
        if !model.localAddressEnabled { return "Inactive. Offer a local address to use this." + saved }
        if model.shortAddressEnabled { return "You admit every request." }
        return "Viewers on this network can type \(LocalAddressName.host(model.localAddress.activeLabel ?? model.localAddressLabel).unbrokenHyphens) while you share. You admit every request."
    }
    private func applyAddress() {
        guard localProblem == nil else { return }
        model.setLocalAddress(enabled: true, label: draft.wrappedValue.address)
        model.sharingDraft?.address = model.localAddressLabel
    }
}

struct ViewerNetworkEditor: View {
    @ObservedObject var model: SessionModel
    @State private var confirmChange = false
    private var network: Binding<String> {
        Binding(get: { model.sharingDraft?.network ?? model.networkChoice }, set: { model.prepareSharingDraft(); model.sharingDraft?.network = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Viewing network").font(.headline)
            Picker("Connection", selection: network) {
                Text("Automatic").tag("automatic")
                ForEach(model.networks, id: \.interface) { item in Text(item.label).tag(item.interface) }
                Text("This Mac only").tag("lo0")
                if network.wrappedValue != "automatic" && network.wrappedValue != "lo0" && !model.networks.contains(where: { $0.interface == network.wrappedValue }) {
                    Text("\(network.wrappedValue) · Unavailable").tag(network.wrappedValue)
                }
            }.accessibilityLabel("Viewing network")
            Text("Changing this stops sharing. Your local monitor continues. Wi-Fi join-code details are in Invite.")
                .font(.caption).foregroundStyle(.secondary)
            if network.wrappedValue != model.networkChoice {
                Text("Not applied. This draft is kept when you close Sharing.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Apply Viewing Network") {
                if model.state.sharing { confirmChange = true } else { apply() }
            }.disabled(model.busy || network.wrappedValue == model.networkChoice)
                .confirmationDialog("Change viewing network and stop sharing?", isPresented: $confirmChange, titleVisibility: .visible) {
                    Button("Stop Sharing and Change Network", role: .destructive, action: apply)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Current viewers lose access. Start sharing again to invite them on the new network. Local monitoring continues.")
                }
        }
    }
    private func apply() { model.changeViewingNetwork(network.wrappedValue) }
}

/// The text column is hidden from accessibility because the native switch already owns its label and hint.
struct SharingSwitch: View {
    let title: String
    var detail = ""
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(enabled ? .primary : .secondary).fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(enabled ? .secondary : .tertiary) }
            }.frame(maxWidth: .infinity, alignment: .leading).accessibilityHidden(true)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).fixedSize()
                .accessibilityLabel(title).accessibilityHint(detail)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
