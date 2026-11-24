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
        VStack(alignment: .leading, spacing: 12) {
            switchRow("Ask first", symbol: "hand.raised", tint: SetbeamChrome.amber, hint: approvalDetail,
                      value: Binding(get: { model.viewerApproval }, set: { model.setViewerApproval($0) }))
                .disabled(model.busy || model.applyingViewerApproval)
            switchRow("Pointers", symbol: "cursorarrow", tint: SetbeamChrome.blue, hint: "Let admitted viewers point at the picture.",
                      value: Binding(get: { model.sharedPointers }, set: { model.setSharedPointers($0) }))
            switchRow("On this Mac", symbol: "eye", hint: "Show viewer pointers on the local monitor and floating preview.",
                      value: Binding(get: { model.pointersOnThisMac }, set: { model.setPointersOnThisMac($0) }))
                .disabled(!model.sharedPointers).padding(.leading, 36)
            if model.setup?.kind == .macScreen {
                switchRow("On the shared display", symbol: "display", hint: "Draw on the selected display without capturing the pointers or taking clicks.",
                          value: Binding(get: { model.pointersOnSourceDisplay }, set: { model.setPointersOnSourceDisplay($0) }))
                    .disabled(!model.canShowPointersOnSourceDisplay).padding(.leading, 36)
            }
            Divider()
            output
            Divider()
            SharingOptionsDisclosure(title: "Viewing network", summary: networkSummary, symbol: "wifi",
                tint: SetbeamChrome.admit, attention: draft.wrappedValue.network != model.networkChoice, isExpanded: $networkExpanded) {
                ViewerNetworkEditor(model: model, showsTitle: false)
            }.id("viewing-network")
            localAddressRow
            if addressExpanded { address.padding(.leading, 4) }
        }.controlSize(.small)
            .onAppear {
                model.prepareSharingDraft()
                addressExpanded = addressChanged
                networkExpanded = model.sharingOptionsNetworkRequested || draft.wrappedValue.network != model.networkChoice
            }
            .onChange(of: model.sharingOptionsTarget) { _, _ in networkExpanded = true }
    }

    private let quickFrameRates = [VideoFrameRate.source, .fps24, .fps25, .fps30]
    private let slowFrameRates = [VideoFrameRate.fps1, .fps5, .fps10, .fps15]

    private var output: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach([AudienceQuality.light, .balanced, .best], id: \.self) { quality in
                    segment(selected: draft.wrappedValue.quality == quality, title: quality.title, height: 44) {
                        draft.wrappedValue.quality = quality
                    } content: {
                        VStack(spacing: 3) {
                            QualityBars(level: quality.kilobits == 12_000 ? 3 : quality.kilobits == 6_000 ? 2 : 1)
                            Text("\(quality.kilobits / 1000) Mbps").font(.caption2)
                        }
                    }
                }
            }.padding(2).background(SetbeamChrome.segment, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain).accessibilityLabel("Viewer picture quality")
            HStack(spacing: 2) {
                ForEach(quickFrameRates, id: \.self) { rate in
                    segment(selected: draft.wrappedValue.frameRate == rate, title: rate.title, height: 28) {
                        draft.wrappedValue.frameRate = rate
                    } content: {
                        Text(rate == .source ? "Auto" : "\(rate.rawValue)").font(.callout)
                    }
                }
                let selectedRate = draft.wrappedValue.frameRate
                let slowSelected = slowFrameRates.contains(selectedRate)
                Menu {
                    ForEach(slowFrameRates, id: \.self) { rate in
                        Button { draft.wrappedValue.frameRate = rate } label: {
                            if selectedRate == rate { Label(rate.title, systemImage: "checkmark") } else { Text(rate.title) }
                        }
                    }
                } label: {
                    Group {
                        if slowSelected { Text("\(selectedRate.rawValue)") }
                        else { Image(systemName: "ellipsis") }
                    }.frame(width: 28, height: 28)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .background(slowSelected ? SetbeamChrome.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .help("More frame rates").accessibilityLabel("More viewer frame rates")
                    .accessibilityValue(slowSelected ? selectedRate.title : "")
            }.padding(2).background(SetbeamChrome.segment, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain).accessibilityLabel("Viewer frame rate")
            if outputChanged {
                HStack(spacing: 8) {
                    if model.state.sharing {
                        Text("Viewers will reconnect.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Apply Output") {
                        let value = draft.wrappedValue
                        model.setVideoSettings(quality: value.quality, frameRate: value.frameRate, screenRate: model.screenFrameRate)
                    }.disabled(model.busy).accessibilityLabel("Apply Viewer Output")
                }
            }
        }
    }

    private func segment<Content: View>(selected: Bool, title: String, height: CGFloat, action: @escaping () -> Void,
                                       @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, minHeight: height)
                .foregroundStyle(selected ? .primary : .secondary)
                .background(selected ? SetbeamChrome.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(ChromeButtonStyle()).help(title).accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var localAddressRow: some View {
        HStack(spacing: 8) {
            Button { addressExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    OptionsIcon(symbol: "globe", tint: .gray)
                    Text(LocalAddressName.host(model.localAddressLabel)).font(.system(.callout, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    if addressChanged || model.localAddressStatus.attention {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(SetbeamChrome.amberText)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(ChromeButtonStyle()).help("Local address settings")
                .accessibilityLabel("Local address settings, \(LocalAddressName.host(model.localAddressLabel))")
                .accessibilityValue(addressExpanded ? "Expanded" : "Collapsed")
            Toggle("Offer a local address", isOn: Binding(get: { model.localAddressEnabled },
                    set: { model.setLocalAddress(enabled: $0, label: model.localAddressLabel) }))
                .labelsHidden().toggleStyle(.switch).tint(SetbeamChrome.green)
                .disabled(!model.canInviteOtherDevices)
                .help(model.localAddressStatus.text)
        }
    }

    private func switchRow(_ title: String, symbol: String, tint: Color? = nil, hint: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            OptionsIcon(symbol: symbol, tint: tint)
            SharingSwitch(title: title, hint: hint, isOn: value)
        }.tint(SetbeamChrome.green)
    }

    private var address: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.canInviteOtherDevices {
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
        if model.networkChoice == "automatic" {
            let current = model.viewerNetworkLabel
            return current == "This Mac only" ? "Automatic" : current
        }
        if model.networkChoice == "lo0" { return "This Mac only" }
        return model.networks.first(where: { $0.interface == model.networkChoice })?.name ?? "Unavailable"
    }
    private var approvalDetail: String {
        if model.applyingViewerApproval { return "Applying the approval setting…" }
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
    let symbol: String
    let tint: Color
    var attention = false
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    OptionsIcon(symbol: symbol, tint: tint)
                    Text(summary).font(.callout.weight(.medium)).lineLimit(1).help(summary)
                    Spacer(minLength: 8)
                    if attention { Image(systemName: "exclamationmark.circle").foregroundStyle(SetbeamChrome.amberText) }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(ChromeButtonStyle()).accessibilityLabel("\(title), \(summary)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .help(isExpanded ? "Hide \(title.lowercased()) settings" : "Show \(title.lowercased()) settings")
            if isExpanded { content() }
        }
    }
}

private struct OptionsIcon: View {
    let symbol: String
    var tint: Color?

    var body: some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint == SetbeamChrome.amber ? SetbeamChrome.onAmber : tint == nil ? .secondary : .white)
            .frame(width: 28, height: 28)
            .background(tint ?? .clear, in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}

private struct QualityBars: View {
    let level: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .opacity(bar <= level ? 1 : 0.25)
                    .frame(width: 3, height: CGFloat(4 + bar * 4))
            }
        }.accessibilityHidden(true)
    }
}
