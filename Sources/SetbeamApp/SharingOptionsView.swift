import SwiftUI
import SetbeamCore

/// The LIVE menu: Hold and Stop first, then who can join and point, then viewer quality.
/// Network and local address are set once in Settings and only summarized here.
struct AudienceControlsView: View {
    @ObservedObject var model: SessionModel
    var dismiss: () -> Void = {}

    private var sharing: AudiencePresentation { model.audiencePresentation }
    private var draft: Binding<SharingOptionsDraft> {
        Binding(get: { model.sharingDraft ?? SharingOptionsDraft(address: model.localAddressLabel, network: model.networkChoice, quality: model.audienceQuality, frameRate: model.audienceFrameRate) },
                set: { model.sharingDraft = $0 })
    }
    private var outputChanged: Bool { draft.wrappedValue.quality != model.audienceQuality || draft.wrappedValue.frameRate != model.audienceFrameRate }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.state.sharing || model.canStopSharing || model.stoppingSharing { commands }
            if sharing.needsAttention || sharing.isChanging {
                Label(sharing.visibleOutputDetail(pictureConfirmed: model.audiencePreviewPlaying, hasAudio: model.audienceHasAudio),
                      systemImage: sharing.symbol).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            tiles
            output
            footer
        }.padding(12).frame(width: 300)
            .onAppear { model.prepareSharingDraft() }
    }

    private var commands: some View {
        HStack(spacing: 8) {
            if model.state.sharing {
                let resume = sharing.primaryTarget == .resume
                bigButton(sharing.primaryTitle, symbol: sharing.primarySymbol,
                          tint: resume ? SetbeamChrome.greenText : SetbeamChrome.amberText,
                          fill: resume ? SetbeamChrome.green : SetbeamChrome.amber, help: sharing.primaryHelp) {
                    model.performAudienceAction(); dismiss()
                }.disabled(!sharing.primaryEnabled)
                if sharing.phase == .failedResume {
                    bigButton("Hold", symbol: "pause.fill", tint: SetbeamChrome.amberText, fill: SetbeamChrome.amber,
                              help: "Keep viewers on Hold") { model.setAudienceHold(true); dismiss() }
                        .disabled(model.busy)
                }
            }
            bigButton("Stop", symbol: "stop.circle", tint: SetbeamChrome.red, fill: SetbeamChrome.red,
                      help: "Stop Sharing. End viewer access. Your local monitor continues.") { model.stopSharing(); dismiss() }
                .disabled(!model.canStopSharing).accessibilityLabel("Stop Sharing")
        }
    }

    private func bigButton(_ title: String, symbol: String, tint: Color, fill: Color, help: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(fill.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(ChromeButtonStyle()).help(help).accessibilityHint(help)
    }

    private var tiles: some View {
        HStack(spacing: 8) {
            AudienceToggleTile(title: "Ask first", symbol: "hand.raised", tint: SetbeamChrome.amber, onTint: SetbeamChrome.onAmber,
                               hint: approvalDetail, isOn: Binding(get: { model.viewerApproval }, set: { model.setViewerApproval($0) }))
                .disabled(model.busy || model.applyingViewerApproval)
            AudienceToggleTile(title: "Pointers", symbol: "cursorarrow", tint: SetbeamChrome.blue, hint: "Let admitted viewers point at the picture.",
                               isOn: Binding(get: { model.sharedPointers }, set: { model.setSharedPointers($0) }))
            AudienceToggleTile(title: "On my Mac", symbol: "eye", tint: SetbeamChrome.blue,
                               hint: "Show viewer pointers on the local monitor and floating preview.",
                               isOn: Binding(get: { model.pointersOnThisMac }, set: { model.setPointersOnThisMac($0) }))
                .disabled(!model.sharedPointers)
            if model.setup?.kind == .macScreen {
                AudienceToggleTile(title: "On display", symbol: "display", tint: SetbeamChrome.blue,
                                   hint: "Draw viewer pointers on the shared display without capturing them or taking clicks.",
                                   isOn: Binding(get: { model.pointersOnSourceDisplay }, set: { model.setPointersOnSourceDisplay($0) }))
                    .disabled(!model.canShowPointersOnSourceDisplay)
            }
        }
    }

    private var approvalDetail: String {
        if model.applyingViewerApproval { return "Applying the approval setting…" }
        if let host = model.shortAddressHost {
            return "Viewers enter a name and wait for you to admit them, including anyone who types \(host)."
        }
        return "Viewers enter a name and wait for you to admit them."
    }

    private let quickFrameRates = [VideoFrameRate.source, .fps24, .fps25, .fps30]
    private let slowFrameRates = [VideoFrameRate.fps1, .fps5, .fps10, .fps15]

    private var output: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach([AudienceQuality.light, .balanced, .best], id: \.self) { quality in
                    segment(selected: draft.wrappedValue.quality == quality, title: quality.title, height: 40) {
                        draft.wrappedValue.quality = quality
                    } content: {
                        VStack(spacing: 2) {
                            QualityBars(level: quality.kilobits == 12_000 ? 3 : quality.kilobits == 6_000 ? 2 : 1)
                            Text("\(quality.kilobits / 1000) Mbps").font(.system(size: 9.5, weight: .medium))
                        }
                    }
                }
                frameRateMenu
            }.padding(2).background(SetbeamChrome.segment, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .contain).accessibilityLabel("Viewer picture quality")
            if outputChanged {
                HStack(spacing: 8) {
                    if model.state.sharing {
                        Text("Viewers will reconnect.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Apply Output") {
                        let value = draft.wrappedValue
                        model.setVideoSettings(quality: value.quality, frameRate: value.frameRate, screenRate: model.screenFrameRate)
                    }.disabled(model.busy).controlSize(.small).accessibilityLabel("Apply Viewer Output")
                }
            }
        }
    }

    /// Frame rate is infrequent, so it stays one click deeper.
    private var frameRateMenu: some View {
        let selectedRate = draft.wrappedValue.frameRate
        return Menu {
            ForEach(quickFrameRates + slowFrameRates, id: \.self) { rate in
                Button { draft.wrappedValue.frameRate = rate } label: {
                    let title = rate == .source ? "Match source" : rate.title
                    if selectedRate == rate { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            Group {
                if selectedRate == .source { Image(systemName: "ellipsis") }
                else { Text("\(selectedRate.rawValue)").font(.caption.weight(.semibold)).monospacedDigit() }
            }.frame(width: 30, height: 40)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .background(selectedRate == .source ? .clear : SetbeamChrome.raised, in: RoundedRectangle(cornerRadius: 8))
            .help("Viewer frame rate · \(selectedRate == .source ? "Match source" : selectedRate.title)")
            .accessibilityLabel("Viewer frame rate").accessibilityValue(selectedRate.title)
    }

    private func segment<Content: View>(selected: Bool, title: String, height: CGFloat, action: @escaping () -> Void,
                                       @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, minHeight: height)
                .foregroundStyle(selected ? .primary : .secondary)
                .background(selected ? SetbeamChrome.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(ChromeButtonStyle()).help(title).accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var footer: some View {
        Button { dismiss(); model.showViewingNetwork() } label: {
            HStack(spacing: 6) {
                chip(model.viewerNetworkLabel, symbol: model.canInviteOtherDevices ? "wifi" : "lock")
                if model.localAddressEnabled && model.canInviteOtherDevices {
                    chip(LocalAddressName.host(model.localAddress.activeLabel ?? model.localAddressLabel), symbol: "globe", mono: true,
                         attention: model.localAddressStatus.attention)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(ChromeButtonStyle()).help("Network settings")
            .accessibilityLabel("Network settings, \(model.viewerNetworkLabel)")
    }

    private func chip(_ title: String, symbol: String, mono: Bool = false, attention: Bool = false) -> some View {
        Label(title, systemImage: attention ? "exclamationmark.triangle" : symbol)
            .font(mono ? .system(.caption, design: .monospaced) : .caption).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(attention ? SetbeamChrome.amberText : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A Control Center-style switch. The tile is one accessible toggle with its own hint.
struct AudienceToggleTile: View {
    let title: String
    let symbol: String
    let tint: Color
    var onTint: Color = .white
    let hint: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isOn ? onTint : .secondary)
                    .frame(width: 32, height: 32)
                    .background(isOn ? tint : Color.primary.opacity(0.08), in: Circle())
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                    .foregroundStyle(enabled ? .primary : .secondary)
            }.frame(maxWidth: .infinity, minHeight: 72)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(ChromeButtonStyle())
            .help(hint)
            .accessibilityLabel(title).accessibilityHint(hint)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
    }
}

/// Settings ▸ Network: where viewers connect and the readable local address. Set once.
struct NetworkSettingsView: View {
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Network").font(.title2.weight(.semibold))
                section("Viewing network", symbol: "wifi", tint: SetbeamChrome.admit) {
                    ViewerNetworkEditor(model: model, showsTitle: false)
                }
                section("Local address", symbol: "globe", tint: .gray) { address }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear { model.prepareSharingDraft() }
    }

    private func section<Content: View>(_ title: String, symbol: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                OptionsIcon(symbol: symbol, tint: tint)
                Text(title).font(.headline)
            }
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private var address: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Offer a local address", isOn: Binding(get: { model.localAddressEnabled },
                    set: { model.setLocalAddress(enabled: $0, label: model.localAddressLabel) }))
                .toggleStyle(.switch).tint(SetbeamChrome.green)
                .disabled(!model.canInviteOtherDevices)
                .help(model.localAddressStatus.text)
            if model.canInviteOtherDevices {
                if model.localAddressEnabled {
                    HStack(spacing: 4) {
                        TextField("Local address name", text: draft.address).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Local address name").onSubmit(applyAddress)
                        Text(".local").foregroundStyle(.secondary)
                    }.frame(maxWidth: 320)
                    if let localProblem { Text(localProblem.message).font(.caption).foregroundStyle(.orange) }
                    if addressChanged {
                        HStack {
                            Button("Apply Address", action: applyAddress).disabled(localProblem != nil)
                            if model.state.sharing {
                                Text("Viewers using the previous name need the new link.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Label(model.localAddressStatus.text.unbrokenHyphens, systemImage: model.localAddressStatus.attention ? "exclamationmark.triangle" : "link")
                        .font(.caption).foregroundStyle(model.localAddressStatus.attention ? .orange : .secondary)
                }
                SharingSwitch(title: "Let viewers ask from the short address", detail: shortAddressDetail,
                    isOn: Binding(get: { model.viewerApproval && model.localAddressEnabled && model.shortAddressEnabled }, set: { model.setShortAddress(enabled: $0) }))
                    .disabled(!model.viewerApproval || !model.localAddressEnabled)
                if model.shortAddressEnabled && model.viewerApproval && model.localAddressEnabled {
                    Label(model.shortAddressStatus.text, systemImage: model.shortAddressStatus.attention ? "exclamationmark.triangle" : "keyboard")
                        .font(.caption).foregroundStyle(model.shortAddressStatus.attention ? .orange : .secondary)
                }
                Text("The full viewing link keeps its private code. QR codes use the IP address for devices that cannot open .local names.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Address joining is unavailable on This Mac only. Choose a viewing network above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var shortAddressDetail: String {
        let saved = model.shortAddressEnabled ? " Your saved choice is kept." : ""
        if !model.viewerApproval { return "Inactive. Requires Ask first." + saved }
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
            Text("Changing this stops sharing. Your local monitor continues. Wi-Fi join-code details are in People.")
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
