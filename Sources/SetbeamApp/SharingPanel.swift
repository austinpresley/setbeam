import AppKit
import SwiftUI
import SetbeamCore

struct SharingPanel: View {
    @ObservedObject var model: SessionModel
    var detached = false
    @AccessibilityFocusState private var focusedTab: SharingSection?
    var body: some View {
        VStack(spacing: 0) {
            if detached {
                HStack { Spacer(); SharingTally(model: model) }.padding(12).background(SetbeamChrome.toolbar)
                Divider()
            }
            tabs
            Divider()
            if detached, let error = model.error {
                Label(error, systemImage: "exclamationmark.circle").font(.caption)
                    .padding(8).foregroundStyle(SetbeamChrome.amberText)
            }
            if model.sharingSection == .chat {
                SessionChatView(model: model).frame(maxHeight: .infinity).layoutPriority(1)
            }
            else {
            ScrollViewReader { scroll in
                ScrollView {
                    Group {
                        switch model.sharingSection ?? .viewers {
                        case .viewers: SharingPeopleView(model: model) { focusedTab = .viewers }
                        case .chat: EmptyView()
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).id("sharing-top")
                }
                .onChange(of: model.sharingSection) { _, _ in scroll.scrollTo("sharing-top", anchor: .top) }
            }
            }
        }.frame(minWidth: SharingPanelLayout.width, maxWidth: .infinity, maxHeight: .infinity)
            .background(SetbeamChrome.panel)
            .accessibilityElement(children: .contain).accessibilityLabel("Sharing")
            .accessibilityIdentifier("sharingPanel")
            .task(id: model.sharingFocusRequest) {
                guard detached == model.sharingInWindow else { return }
                focusedTab = model.sharingSection ?? .viewers
            }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(SharingSection.allCases) { section in
                    let badge = section == .viewers ? model.pendingViewers.count : section == .chat ? model.chatUnreadCount : 0
                    let selected = section == (model.sharingSection ?? .viewers)
                    Button { model.showSharing(section) } label: {
                        Image(systemName: section.symbol).font(.system(size: 16))
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .foregroundStyle(selected ? .primary : .secondary)
                            .background(selected ? SetbeamChrome.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .shadow(color: selected ? .black.opacity(0.13) : .clear, radius: 1, y: 1)
                            .contentShape(Rectangle())
                            .overlay(alignment: .topTrailing) {
                                if badge > 0 {
                                    ChromeBadge(count: badge, color: section == .viewers ? SetbeamChrome.amber : SetbeamChrome.red,
                                                foreground: section == .viewers ? SetbeamChrome.onAmber : .white)
                                        .padding(.trailing, 2)
                                }
                            }
                    }.buttonStyle(ChromeButtonStyle())
                        .help(section.rawValue).accessibilityLabel(section.rawValue)
                        .accessibilityValue(badge == 0 ? "" : "\(badge) \(section == .viewers ? "waiting" : "unread")")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityFocused($focusedTab, equals: section)
                }
            }.padding(2).background(SetbeamChrome.segment, in: RoundedRectangle(cornerRadius: 8))
            if !detached {
                ChromeIconButton("Open Sharing in a separate window", symbol: "arrow.up.right.square", size: 28) { model.showSharingInWindow() }
                ChromeIconButton("Close Sharing panel", symbol: "xmark", size: 28) { model.closeSharing() }
            }
        }.padding(.horizontal, 12).padding(.vertical, 12)
    }

}

struct SharingWindowView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        SharingPanel(model: model, detached: true)
            .frame(minWidth: 320, idealWidth: 360, minHeight: 400, idealHeight: 640)
            .background(SharingWindowLifecycle(model: model).frame(width: 0, height: 0))
            .toolbar {
                ToolbarItem { Button { model.dockSharing() } label: { Label("Show Sharing beside the monitor", systemImage: "rectangle.righthalf.inset.filled") }
                    .help("Show Sharing beside the monitor").disabled(!model.sharingCanDock) }
            }
    }
}

/// One home for bringing people in and seeing who is there. The codes are large while nobody
/// has joined and shrink to a card once requests or viewers appear.
struct SharingPeopleView: View {
    @ObservedObject var model: SessionModel
    var returnAccessibilityFocus: () -> Void = {}

    private var nobodyYet: Bool { model.admittedViewers.isEmpty && model.pendingViewers.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if nobodyYet {
                SharingInviteView(model: model)
            } else {
                CompactInvitationCard(model: model)
            }
            if model.state.sharing && model.canInviteOtherDevices && !(model.setupCheck.passed && !nobodyYet) {
                Divider()
                ReadinessStrip(model: model)
            }
            if !nobodyYet {
                SharingViewersView(model: model, returnAccessibilityFocus: returnAccessibilityFocus)
            }
        }
    }
}

/// The watch code stays one click away while the list below holds requests and viewers.
struct CompactInvitationCard: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        HStack(spacing: 12) {
            Button { model.showJoinCodes() } label: {
                Group {
                    if let url = model.viewingInvitation?.ipURL {
                        QRView(payload: url.absoluteString, size: 52, inset: 4)
                    } else {
                        Image(systemName: "qrcode").font(.system(size: 26)).foregroundStyle(.secondary)
                            .frame(width: 52, height: 52)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.buttonStyle(.plain).disabled(model.protectsSourceDraft || (model.viewingInvitation == nil && model.wifiSSID.isEmpty))
                .help("Enlarge codes").accessibilityLabel("Enlarge viewing QR code")
            VStack(alignment: .leading, spacing: 4) {
                if !model.wifiSSID.isEmpty {
                    Label(model.wifiSSID, systemImage: "wifi").lineLimit(1).help(model.wifiSSID)
                }
                if !model.canInviteOtherDevices {
                    Button { model.showViewingNetwork() } label: { Label("This Mac only", systemImage: "lock") }
                        .buttonStyle(.link).help("Choose a viewing network in Settings")
                } else {
                    Label(model.viewingInvitation == nil ? "Waiting" : "Watch", systemImage: "play.rectangle")
                        .foregroundStyle(.secondary).lineLimit(1).help(model.viewingInvitation == nil ? model.viewingCodeStatus : "Watch the feed")
                }
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            ChromeIconButton("Enlarge codes", symbol: "arrow.up.left.and.arrow.down.right", size: 28) { model.showJoinCodes() }
                .disabled(model.protectsSourceDraft || (model.viewingInvitation == nil && model.wifiSSID.isEmpty))
                .foregroundStyle(.secondary)
            ChromeIconButton(model.copiedLink ? "Link copied" : "Copy link", symbol: model.copiedLink ? "checkmark" : "doc.on.doc", size: 28,
                             hint: model.copiedLink ? "Link copied" : model.copyLinkHelp) { model.copyLink() }
                .disabled(model.viewingInvitation == nil).foregroundStyle(.secondary)
        }.padding(10)
            .background(SetbeamChrome.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(SetbeamChrome.line, lineWidth: 1).allowsHitTesting(false) }
            .accessibilityElement(children: .contain).accessibilityLabel("Invitation")
    }
}

/// Replaces a separate setup test. Each step reads observed state: the outgoing picture,
/// the outgoing audio track, the viewing invitation and another device playing this output.
struct ReadinessStrip: View {
    @ObservedObject var model: SessionModel

    private struct Step: Identifiable {
        let id: String
        let symbol: String
        let label: String
        let done: Bool
        var neutral = false
        var waiting = false
        var help: String
    }

    private var steps: [Step] {
        let check = model.setupCheck
        let picture = check.picture && model.audiencePreviewPlaying
        let network = model.wifiSSID.isEmpty ? model.viewerNetworkLabel : model.wifiSSID
        return [
            Step(id: "picture", symbol: "play.rectangle", label: "Picture", done: picture,
                 help: picture ? "Viewers receive a confirmed picture" : "Waiting for the outgoing picture"),
            Step(id: "sound", symbol: check.outgoingAudio ? "speaker.wave.2" : "speaker.slash",
                 label: check.outgoingAudio ? "Sound" : "No sound", done: check.outgoingAudio, neutral: !check.outgoingAudio,
                 help: check.outgoingAudio ? "Viewers receive sound" : "This feed sends no sound to viewers"),
            Step(id: "network", symbol: "wifi", label: network, done: check.viewingAddress,
                 help: check.viewingAddress ? "Viewers on \(network) can open the link" : "Waiting for the viewing network"),
            Step(id: "device", symbol: "iphone", label: check.otherDevicePlaying ? "Playing" : "Scan",
                 done: check.otherDevicePlaying, waiting: !check.otherDevicePlaying,
                 help: check.otherDevicePlaying ? "Another device is playing this output" : "Scan Watch with a phone to test"),
        ]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 {
                    Rectangle().fill(SetbeamChrome.line).frame(height: 1.5).frame(maxWidth: 16).padding(.top, 19)
                        .accessibilityHidden(true)
                }
                stepView(step)
            }
        }.frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain).accessibilityLabel("Sharing readiness")
            .onChange(of: model.setupCheck.passed) { _, passed in
                if passed { AccessibilityNotification.Announcement("Another device is playing. Setup checked.").post() }
            }
    }

    private func stepView(_ step: Step) -> some View {
        let tint: Color = step.done ? SetbeamChrome.greenText : step.waiting ? SetbeamChrome.blueText : .secondary
        return VStack(spacing: 6) {
            Image(systemName: step.symbol).font(.system(size: 16))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background((step.done ? SetbeamChrome.green : step.waiting ? SetbeamChrome.blue : Color.primary).opacity(step.done ? 0.16 : 0.07), in: Circle())
                .overlay { if step.waiting { Circle().strokeBorder(SetbeamChrome.blue, lineWidth: 1.5) } }
                .overlay(alignment: .bottomTrailing) {
                    if step.done {
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                            .frame(width: 16, height: 16).background(SetbeamChrome.green, in: Circle())
                            .background(SetbeamChrome.panel, in: Circle().inset(by: -2)).offset(x: 3, y: 3)
                    }
                }
            Text(step.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }.frame(width: 62)
            .help(step.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(step.label)
            .accessibilityValue(step.neutral ? step.help : step.done ? "Ready" : step.help)
    }
}

struct SharingViewersView: View {
    @ObservedObject var model: SessionModel
    var returnAccessibilityFocus: () -> Void = {}
    @State private var expandedViewer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.pendingViewers.isEmpty {
                HStack {
                    count(model.pendingViewers.count, symbol: "hand.raised", name: "waiting to join", tint: SetbeamChrome.amberText)
                    Spacer()
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                        .help("Names and colors are chosen by viewers. Each request is a browser session.")
                        .accessibilityLabel("Names and colors are chosen by viewers and are not verified.")
                }
                ForEach(model.pendingViewers) { viewer in ViewerRequestRow(model: model, viewer: viewer, returnAccessibilityFocus: returnAccessibilityFocus) }
                Divider()
            }
            if !model.admittedViewers.isEmpty {
                HStack(spacing: 16) {
                    count(model.admittedViewers.count, symbol: "person.2", name: "joined", tint: .primary)
                    count(model.admittedViewers.filter { $0.playing && $0.health != .struggling }.count,
                          symbol: "play.fill", name: "playing without reported problems", tint: SetbeamChrome.greenText)
                    if !model.strugglingViewers.isEmpty {
                        count(model.strugglingViewers.count, symbol: "cellularbars", name: "struggling", variableValue: 0.25, tint: SetbeamChrome.amberText)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(model.admittedViewers) { viewer in
                        ViewerActivityRow(model: model, viewer: viewer, showingDetails: expandedViewer == viewer.id,
                                          returnAccessibilityFocus: returnAccessibilityFocus) {
                            expandedViewer = expandedViewer == viewer.id ? nil : viewer.id
                        }
                    }
                }.padding(.horizontal, -8)
            }
        }.onChange(of: model.viewingLink) { _, _ in expandedViewer = nil }
    }

    private func count(_ count: Int, symbol: String, name: String, variableValue: Double? = nil, tint: Color) -> some View {
        Label { Text("\(count)") } icon: { Image(systemName: symbol, variableValue: variableValue) }
            .font(.callout.weight(.semibold)).monospacedDigit()
            .foregroundStyle(tint).help("\(count) \(name)").accessibilityLabel("\(count) \(name)")
    }
}

struct SharingInviteView: View {
    @ObservedObject var model: SessionModel
    @State private var editingWiFi = false
    @State private var printProblem: String?
    @State private var addressExpanded = false

    var body: some View {
        VStack(spacing: 20) {
            Button { model.present(.rename) } label: {
                HStack(spacing: 8) {
                    Text(model.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.protectsSourceDraft)
                .help("Rename session · \(model.title)").accessibilityLabel("Rename session, \(model.title)")
            if model.canInviteOtherDevices {
                InvitationCodesView(model: model, codeSize: 112)
                actions
                if !model.state.sharing {
                    Text("The viewing code appears when you go live.").font(.caption).foregroundStyle(.secondary)
                } else if model.wifiSSID.isEmpty && model.viewingInvitation != nil {
                    Text(model.viewingInstructions).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if model.state.sharing && model.viewingInvitation == nil {
                    Button("Choose Viewing Network…") { model.showViewingNetwork() }.buttonStyle(.link)
                }
                if model.state.sharing && model.localAddressEnabled { localAddress }
            } else {
                ViewingNetworkRequiredView(model: model)
                Button("Edit Viewing Wi-Fi…") { editingWiFi.toggle() }.buttonStyle(.link)
            }
            if let printProblem { Text(printProblem).font(.caption).foregroundStyle(SetbeamChrome.amberText) }
            if editingWiFi { ViewingWiFiEditor(model: model) { editingWiFi = false } }
        }.frame(maxWidth: .infinity)
            .padding(.top, 8)
            .onAppear { editingWiFi = model.viewingWiFiDraft != nil }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            inviteButton(model.copiedLink ? "Link copied" : "Copy link", symbol: model.copiedLink ? "checkmark" : "doc.on.doc",
                         hint: model.copiedLink ? "Link copied" : model.copyLinkHelp) { model.copyLink() }
                .disabled(model.viewingInvitation == nil)
            inviteButton("Enlarge codes", symbol: "arrow.up.left.and.arrow.down.right") { model.showJoinCodes() }
                .disabled(model.protectsSourceDraft || !canShowCodes)
            inviteButton("Print codes", symbol: "printer") { printCodes() }
                .disabled(!JoinCodeExporter.canExport(model: model))
            inviteButton("Edit viewing Wi-Fi", symbol: "wifi", selected: editingWiFi) { editingWiFi.toggle() }
        }
    }

    private var canShowCodes: Bool { model.viewingInvitation != nil || !model.wifiSSID.isEmpty }

    private func inviteButton(_ title: String, symbol: String, selected: Bool = false, hint: String? = nil,
                              action: @escaping () -> Void) -> some View {
        ChromeIconButton(title, symbol: symbol, size: 52, height: 40, iconSize: 18, selected: selected, hint: hint, action: action)
            .background(SetbeamChrome.raised, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(SetbeamChrome.line, lineWidth: 1).allowsHitTesting(false) }
    }

    private func printCodes() {
        do {
            let snapshot = try JoinCodeExporter.snapshot(model: model)
            printProblem = nil
            try JoinCodeExporter.print(snapshot, model: model)
        } catch { printProblem = error.localizedDescription }
    }

    private var localAddress: some View {
        let status = model.localAddressStatus
        let activeHost = model.localViewerURL?.host
        let displayHost = activeHost ?? LocalAddressName.host(model.localAddressLabel)
        let ready = activeHost != nil
        let tint: Color = status.attention ? SetbeamChrome.amberText : ready ? SetbeamChrome.greenText : .secondary
        return VStack(alignment: .leading, spacing: 8) {
            Button { addressExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    Text(displayHost).font(.system(.callout, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: status.attention ? "exclamationmark.triangle" : ready ? "checkmark" : "ellipsis")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(tint.opacity(0.13), in: Capsule())
                }.padding(.horizontal, 12).frame(minHeight: 32)
                    .background(SetbeamChrome.raised, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(SetbeamChrome.line, lineWidth: 1) }
                    .contentShape(Rectangle())
            }.buttonStyle(ChromeButtonStyle()).help(status.text)
                .accessibilityLabel("Local address, \(displayHost)")
                .accessibilityValue(addressExpanded ? "Expanded" : "Collapsed")
            if addressExpanded || status.attention || model.shortAddressEnabled && model.shortAddressStatus.attention {
                InvitationAddressView(model: model)
                if model.localViewerURL != nil {
                    Button(model.copiedIPLink ? "IP address link copied" : "Copy IP address link") { model.copyIPLink() }
                        .buttonStyle(.link).font(.caption).help("Use when a viewer cannot open .local names")
                }
            }
        }.padding(.top, 12)
    }
}

/// Both presentations use the same QR payloads and active-link gate.
struct InvitationCodesView: View {
    @ObservedObject var model: SessionModel
    let codeSize: CGFloat
    var presentation = false
    var vertical = false
    var body: some View {
        if presentation {
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 24)) : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            layout {
                if !model.wifiSSID.isEmpty {
                    VStack(spacing: 12) {
                        Text("1. Join Wi-Fi").font(.headline)
                        wifiCode
                        Text(model.wifiSSID).font(.headline).lineLimit(2).help(model.wifiSSID)
                    }
                }
                VStack(spacing: 12) {
                    Text(model.wifiSSID.isEmpty ? "Scan to Watch" : "2. Watch the Feed").font(.headline)
                    feedCode
                    Text(model.title).font(.headline).lineLimit(2).help(model.title)
                }
            }.frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .top, spacing: 8) {
                if !model.wifiSSID.isEmpty {
                    VStack(spacing: 8) {
                        wifiCode
                        Label(model.wifiSSID, systemImage: "wifi").lineLimit(1).help(model.wifiSSID)
                            .accessibilityLabel("First, join \(model.wifiSSID)")
                    }.frame(width: codeSize)
                    Image(systemName: "arrow.right").font(.system(size: 16))
                        .foregroundStyle(.tertiary).padding(.top, 48).accessibilityHidden(true)
                }
                VStack(spacing: 8) {
                    feedCode
                    Label("Watch", systemImage: "play.rectangle")
                        .accessibilityLabel(model.wifiSSID.isEmpty ? "Watch the feed" : "Then watch the feed")
                }.frame(width: codeSize)
            }.font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
    @ViewBuilder private var wifiCode: some View {
        if model.viewingWiFiPasswordAvailable {
            code(QRView(payload: QRCode.wifi(ssid: model.wifiSSID, password: model.wifiPassword), size: codeSize, inset: presentation ? 16 : 8),
                 label: "Wi-Fi join QR code for \(model.wifiSSID)")
        } else {
            Text("Password unavailable. Re-enter viewing Wi-Fi details in Invite.").font(.caption).foregroundStyle(.secondary)
                .frame(width: codeSize, height: codeSize)
        }
    }
    @ViewBuilder private var feedCode: some View {
        if let url = model.viewingInvitation?.ipURL {
            code(QRView(payload: url.absoluteString, size: codeSize, inset: presentation ? 16 : 8), label: "Viewing QR code")
        } else {
            Text(model.viewingCodeStatus).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(6).frame(width: codeSize, height: codeSize)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    @ViewBuilder private func code<Content: View>(_ content: Content, label: String) -> some View {
        if presentation { content.accessibilityLabel(label) }
        else {
            Button { model.showJoinCodes() } label: { content }
                .buttonStyle(.plain).accessibilityLabel("Enlarge \(label)")
                .help(model.protectsSourceDraft ? "Save or cancel Source Details to enlarge codes" : "Click to enlarge the QR codes").disabled(model.protectsSourceDraft)
        }
    }
}

struct ViewingWiFiEditor: View {
    @ObservedObject var model: SessionModel
    var saved: () -> Void
    @State private var failed = false
    @StateObject private var wifi = ViewingWiFiBrowser()
    private var draft: Binding<ViewingWiFiDraft> {
        Binding(get: { model.viewingWiFiDraft ?? .init(ssid: model.wifiSSID, password: model.wifiPassword,
            openNetwork: !model.wifiSSID.isEmpty && model.wifiPassword.isEmpty && model.viewingWiFiPasswordAvailable) },
                set: { model.viewingWiFiDraft = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu("Choose Wi-Fi") {
                    if wifi.networks.isEmpty { Text("No cached Wi-Fi names") }
                    ForEach(wifi.networks) { network in
                        Button(network.name + (network.current ? " · Connected" : "") + (network.supportsJoinCode ? "" : " · Join manually")) {
                            draft.wrappedValue = .init(ssid: network.name, password: "", openNetwork: network.open)
                        }.disabled(!network.supportsJoinCode)
                    }
                }
                Button(wifi.allowed ? "Refresh" : "Allow Wi-Fi Names…") {
                    if wifi.allowed { model.scanViewingWiFi(wifi) }
                    else { wifi.allowNames() }
                }.disabled(wifi.allowed && !model.canScanViewingWiFi)
            }
            Text(wifi.message).font(.caption).foregroundStyle(.secondary)
            TextField("Wi-Fi name", text: draft.ssid).textFieldStyle(.roundedBorder).accessibilityLabel("Wi-Fi name")
            SecureField("Wi-Fi password", text: draft.password).textFieldStyle(.roundedBorder).accessibilityLabel("Wi-Fi password")
                .disabled(draft.wrappedValue.openNetwork)
            Toggle("Open network, no password", isOn: draft.openNetwork).toggleStyle(.checkbox)
            Text(!draft.wrappedValue.openNetwork && draft.wrappedValue.password.isEmpty ? "This network needs a password before you can save its join code." : ViewingWiFiBrowser.passwordFormat(draft.wrappedValue.openNetwork ? "" : draft.wrappedValue.password))
                .font(.caption).foregroundStyle(.secondary)
            Text("To test the password, save these details and scan the Wi-Fi code with a phone. A saved name or current Mac connection does not test the typed password. Scanning for new names is available while network video is idle.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Creates a join code for viewers without changing this Mac's Wi-Fi. Choose Open network only if it has no password.")
                .font(.caption).foregroundStyle(.secondary)
            if draft.wrappedValue.ssid.utf8.count > 32 { Text("Use a Wi-Fi name of 32 bytes or fewer.").font(.caption).foregroundStyle(.orange) }
            if failed { Text("The Wi-Fi details could not be saved. Your draft is kept.").font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { model.viewingWiFiDraft = nil; saved() }
                Spacer()
                Button("Save Wi-Fi") {
                    let value = draft.wrappedValue
                    if model.saveViewingSettings(network: model.networkChoice, ssid: value.ssid, password: value.openNetwork ? "" : value.password) {
                        model.viewingWiFiDraft = nil; saved()
                    } else { failed = true }
                }.disabled(!draft.wrappedValue.canSave)
            }
        }.onAppear { wifi.loadCached() }
    }
}

struct JoinCodesView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Join the Feed").font(.title2.weight(.semibold))
            if !model.canInviteOtherDevices { ViewingNetworkRequiredView(model: model) }
            else if model.state.sharing || !model.wifiSSID.isEmpty { InvitationCodesView(model: model, codeSize: codeSize, presentation: true) }
            else { Label("Sharing is off. Your local monitor continues.", systemImage: "lock") }
            HStack { Spacer(); Button("Done") { model.sheet = nil }.keyboardShortcut(.defaultAction) }
            Button("Open in Separate Window") { model.sheet = nil; model.showJoinCodeWindow() }
        }.padding(24).frame(width: width).onExitCommand { model.sheet = nil }
    }
    private var width: CGFloat {
        let available = model.monitorWindow?.screen?.visibleFrame.width ?? NSScreen.main?.visibleFrame.width ?? 1024
        return min(model.wifiSSID.isEmpty ? 480 : 768, floor((available - 64) / 4) * 4)
    }
    private var codeSize: CGFloat { min(320, floor((width - (model.wifiSSID.isEmpty ? 48 : 72)) / (model.wifiSSID.isEmpty ? 4 : 8)) * 4) }
}

struct ViewingNetworkRequiredView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Viewing is limited to this Mac", systemImage: "lock").font(.headline)
            Text("Choose a network to invite phones and other computers. Your local monitor continues.").font(.callout).foregroundStyle(.secondary)
            Button("Choose Viewing Network…") { model.showViewingNetwork() }
        }
    }
}
