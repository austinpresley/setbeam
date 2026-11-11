import AppKit
import SwiftUI
import SetbeamCore

struct SharingPanel: View {
    @ObservedObject var model: SessionModel
    var detached = false
    var body: some View {
        VStack(spacing: 0) {
            if detached { MonitorCommandBar(model: model); Divider() }
            VStack(alignment: .leading, spacing: 12) {
                if !detached { HStack {
                    Text("Sharing").font(.headline)
                    Spacer()
                    Button { model.showSharingInWindow() } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain).help("Open Sharing in a separate window").accessibilityLabel("Open Sharing in a separate window")
                    Button { model.closeSharing() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Close Sharing panel").accessibilityLabel("Close Sharing panel")
                } }
                Picker("Sharing section", selection: Binding(get: { model.sharingSection ?? .invite }, set: { model.showSharing($0) })) {
                    ForEach(SharingSection.allCases) { section in Text(section == .chat && model.chatUnreadCount > 0 ? "Chat (\(min(99, model.chatUnreadCount)))" : section.rawValue).tag(section) }
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Sharing section")
                if detached, let error = model.error {
                    Label { Text(error).foregroundStyle(.primary) }
                        icon: { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }.font(.caption)
                }
            }.padding(20)
            Divider()
            if model.sharingSection == .chat {
                SessionChatView(model: model).frame(maxHeight: .infinity).layoutPriority(1)
            }
            else {
            ScrollViewReader { scroll in
                ScrollView {
                    Group {
                        switch model.sharingSection ?? .invite {
                        case .invite: SharingInviteView(model: model)
                        case .viewers: SharingViewersView(model: model)
                        case .options: SharingOptionsView(model: model)
                        case .chat: EmptyView()
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).id("sharing-top")
                }
                .onChange(of: model.sharingSection) { _, _ in scroll.scrollTo("sharing-top", anchor: .top) }
                .onChange(of: model.sharingOptionsTarget) { _, _ in scroll.scrollTo("viewing-network", anchor: .top) }
            }
            }
        }.frame(minWidth: SharingPanelLayout.width, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .accessibilityElement(children: .contain).accessibilityLabel("Sharing")
            .accessibilityIdentifier("sharingPanel")
            .onAppear {
                if !detached {
                    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                        userInfo: [.announcement: "Sharing. \(model.sharingSection?.rawValue ?? "Invite")", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
            }
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

struct SharingViewersView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !model.pendingViewers.isEmpty {
                viewerGroup("Asking to join · \(model.pendingViewers.count)", viewers: model.pendingViewers)
                Text("Names and colors are chosen by viewers and are not verified.").font(.caption).foregroundStyle(.secondary)
                Divider()
            }
            if model.admittedViewers.isEmpty {
                Label(model.state.sharing ? "No viewers yet" : "Sharing is off", systemImage: "person.2").font(.headline)
                Text(model.state.sharing ? "Invite viewers with the link or QR code. Fresh playback appears here." : "Your monitor stays private. Start sharing when you are ready to invite viewers.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Invite Viewers") { model.showSharing(.invite) }.buttonStyle(.link)
            } else {
                viewerGroup("Joined · \(model.admittedViewers.count)", viewers: model.viewersForDetails.filter { $0.admission == .admitted })
                if model.pendingViewers.isEmpty {
                    Text("Each row is a browser session. Names and colors are chosen by viewers and are not verified.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func viewerGroup(_ title: String, viewers: [ViewerActivity]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.headline)
                Spacer(minLength: 8)
                if viewers.first?.admission == .admitted {
                    Text("\(model.verifiedViewers) playing").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(viewers) { viewer in
                ViewerActivityRow(viewer: viewer, canRemove: model.viewerApproval && viewer.admission == .admitted,
                    stackedAdmissionActions: true,
                    audiencePresentation: model.audiencePresentation,
                    shortAddressHost: model.shortAddressHost,
                    admit: { model.admitViewer(viewer) }, decline: { model.declineViewer(viewer) }, remove: { model.removeViewer(viewer) })
                    .padding(viewer.admission == .pending ? 12 : 0)
                    .background {
                        if viewer.admission == .pending { RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)) }
                    }
            }
        }
    }
}

struct SharingInviteView: View {
    @ObservedObject var model: SessionModel
    @State private var editingWiFi = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !model.canInviteOtherDevices {
                ViewingNetworkRequiredView(model: model)
            } else {
                HStack {
                    Text("Join the feed").font(.headline)
                    Spacer()
                    Button("Enlarge Codes…") { model.showJoinCodes() }
                        .disabled(model.protectsSourceDraft || !model.state.sharing && model.wifiSSID.isEmpty)
                        .help(model.protectsSourceDraft ? "Save or cancel Source Details to enlarge codes" : "Show larger Wi-Fi and viewing QR codes")
                }
                InvitationCodesView(model: model, codeSize: 128, editingWiFi: $editingWiFi)
                if model.state.sharing {
                    InvitationLinkActions(model: model)
                    if model.localAddressEnabled { InvitationAddressView(model: model) }
                    if model.wifiSSID.isEmpty {
                        Text(model.viewingInstructions).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("The viewing code appears when you start sharing.").font(.callout).foregroundStyle(.secondary)
                }
            }
            if model.wifiSSID.isEmpty || !model.canInviteOtherDevices {
                DisclosureGroup(model.viewingWiFiDraft != nil ? "Wi-Fi Draft…" : model.wifiSSID.isEmpty ? "Add Viewing Wi-Fi…" : "Edit Viewing Wi-Fi…", isExpanded: $editingWiFi) {
                    ViewingWiFiEditor(model: model) { editingWiFi = false }.padding(.top, 12)
                }
            }

        }.onAppear { editingWiFi = model.viewingWiFiDraft != nil }
    }
}

/// Both presentations use the same QR payloads and active-link gate.
struct InvitationCodesView: View {
    @ObservedObject var model: SessionModel
    let codeSize: CGFloat
    var presentation = false
    var vertical = false
    var editingWiFi: Binding<Bool>?
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
            VStack(alignment: .leading, spacing: 20) {
                if !model.wifiSSID.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("1. Join Wi-Fi").font(.headline)
                            Spacer()
                            if let editingWiFi {
                                Button("Edit…") { editingWiFi.wrappedValue.toggle() }.font(.caption).help("Edit viewing Wi-Fi join details")
                            }
                        }
                        HStack(spacing: 12) {
                            wifiCode
                            Text(model.wifiSSID).font(.callout).lineLimit(4).help(model.wifiSSID)
                        }
                        if let editingWiFi, editingWiFi.wrappedValue {
                            ViewingWiFiEditor(model: model) { editingWiFi.wrappedValue = false }.padding(.top, 8)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.wifiSSID.isEmpty ? "Watch the feed" : "2. Watch the feed").font(.headline)
                    HStack(spacing: 12) {
                        feedCode
                        Text(model.state.sharing ? (model.viewerApproval ? "Scan and ask to join." : "Scan to join the feed.") : "Appears when you share.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    @ViewBuilder private var wifiCode: some View {
        if model.viewingWiFiPasswordAvailable {
            code(QRView(payload: QRCode.wifi(ssid: model.wifiSSID, password: model.wifiPassword), size: codeSize),
                 label: "Wi-Fi join QR code for \(model.wifiSSID)")
        } else {
            Text("Password unavailable. Re-enter viewing Wi-Fi details in Invite.").font(.caption).foregroundStyle(.secondary)
                .frame(width: codeSize, height: codeSize)
        }
    }
    @ViewBuilder private var feedCode: some View {
        if model.state.sharing, let url = model.viewerURL {
            code(QRView(payload: url.absoluteString, size: codeSize), label: "Viewing QR code")
        } else {
            Image(systemName: "lock").foregroundStyle(.secondary).frame(width: codeSize, height: codeSize)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Sharing is off")
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

struct InvitationLinkActions: View {
    @ObservedObject var model: SessionModel
    @State private var showingFallback = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.copyLink() } label: {
                Label(model.copiedLink ? "Link Copied" : "Copy Viewing Link", systemImage: "document.on.document")
                    .frame(maxWidth: .infinity)
            }.disabled(model.viewerURL == nil).help(model.copyLinkHelp)
            if model.localViewerURL != nil {
                DisclosureGroup("IP address fallback", isExpanded: $showingFallback) {
                    Button(model.copiedIPLink ? "IP Address Link Copied" : "Copy IP Address Link") { model.copyIPLink() }
                        .buttonStyle(.link).font(.caption).help("Use the IP address if a viewer cannot open .local names")
                        .padding(.top, 8)
                }.font(.caption)
            }
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
                Button(wifi.allowed ? "Refresh" : "Allow Wi-Fi Names…") { wifi.allowed ? wifi.scan() : wifi.allowNames() }
                    .disabled(wifi.scanning || wifi.allowed && (model.state.sharing || model.state.monitoring && model.setup?.kind.isMacCapture != true && model.setup?.kind != .sample && model.setup?.kind != .capture))
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
