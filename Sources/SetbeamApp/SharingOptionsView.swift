import SwiftUI
import SetbeamCore

struct SharingOptionsView: View {
    @ObservedObject var model: SessionModel
    @State private var addressExpanded = false
    @State private var networkExpanded = false

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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Joining & pointers").font(.headline)
                    Spacer(minLength: 8)
                    Text("Applies immediately").font(.caption).foregroundStyle(.secondary)
                }
                SharingSwitch(title: "Ask before viewers join", detail: "Viewers wait for your Admit.", hint: approvalDetail,
                    isOn: Binding(get: { model.viewerApproval }, set: { model.setViewerApproval($0) }))
                ViewerOptions(model: model, compact: true)
            }
            Divider()
            output
            Divider()
            SharingOptionsDisclosure(title: "Local address", summary: !model.canInviteOtherDevices ? "This Mac only" : model.localAddressEnabled ? LocalAddressName.host(model.localAddressLabel) : "Off",
                attention: addressChanged || model.localAddressStatus.attention, isExpanded: $addressExpanded) {
                address
            }
            Divider()
            SharingOptionsDisclosure(title: "Viewing network", summary: networkSummary,
                attention: draft.wrappedValue.network != model.networkChoice, isExpanded: $networkExpanded) {
                ViewerNetworkEditor(model: model, showsTitle: false)
            }.id("viewing-network")
        }.controlSize(.small)
            .onAppear {
                model.prepareSharingDraft()
                addressExpanded = addressChanged
                networkExpanded = model.sharingOptionsNetworkRequested || draft.wrappedValue.network != model.networkChoice
            }
            .onChange(of: model.sharingOptionsTarget) { _, _ in networkExpanded = true }
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Viewer output").font(.headline)
            LabeledContent("Picture quality") {
                Picker("Picture quality", selection: draft.quality) {
                    ForEach(AudienceQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().accessibilityLabel("Viewer picture quality")
            }
            LabeledContent("Frame rate") {
                Picker("Frame rate", selection: draft.frameRate) {
                    ForEach(VideoFrameRate.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().accessibilityLabel("Viewer frame rate")
            }
            Label("Applying reconnects viewers. Local monitoring continues.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(outputChanged ? "Unapplied changes" : "No unapplied changes").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Apply Output") {
                    let value = draft.wrappedValue
                    model.setVideoSettings(quality: value.quality, frameRate: value.frameRate, screenRate: model.screenFrameRate)
                }.disabled(model.busy || !outputChanged).accessibilityLabel("Apply Viewer Output")
            }
        }
    }

    private var address: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.canInviteOtherDevices {
                Text("Switches apply immediately. Apply Address saves a changed name.").font(.caption).foregroundStyle(.secondary)
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
                        Text("Unapplied name. Your draft is kept when you close Sharing.").font(.caption).foregroundStyle(.secondary)
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
                    .disabled(!model.viewerApproval || !model.localAddressEnabled)
                if model.shortAddressEnabled && model.viewerApproval && model.localAddressEnabled {
                    Label(model.shortAddressStatus.text, systemImage: model.shortAddressStatus.attention ? "exclamationmark.triangle" : "keyboard")
                        .font(.caption).foregroundStyle(model.shortAddressStatus.attention ? .orange : .secondary)
                }
            } else {
                Text("Address joining is unavailable on This Mac only. Choose a viewing network below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var networkSummary: String {
        if draft.wrappedValue.network != model.networkChoice { return "Unapplied changes" }
        if model.networkChoice == "automatic" { return "Automatic" }
        if model.networkChoice == "lo0" { return "This Mac only" }
        return model.networks.first(where: { $0.interface == model.networkChoice })?.name ?? "Unavailable"
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
    var showsTitle = true
    @State private var confirmChange = false
    private var network: Binding<String> {
        Binding(get: { model.sharingDraft?.network ?? model.networkChoice }, set: { model.prepareSharingDraft(); model.sharingDraft?.network = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle { Text("Viewing network").font(.headline) }
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
    var hint: String?
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(enabled ? .primary : .secondary).fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(enabled ? .secondary : .tertiary) }
            }.frame(maxWidth: .infinity, alignment: .leading).accessibilityHidden(true)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).fixedSize()
                .accessibilityLabel(title).accessibilityHint(hint ?? detail).help(hint ?? detail)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The current value stays visible while infrequent connection settings are collapsed.
private struct SharingOptionsDisclosure<Content: View>: View {
    let title: String
    let summary: String
    var attention = false
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if attention { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(summary)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(title), \(summary)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .help(isExpanded ? "Hide \(title.lowercased()) settings" : "Show \(title.lowercased()) settings")
            if isExpanded { content() }
        }
    }
}
