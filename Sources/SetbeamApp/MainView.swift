import SwiftUI
import AppKit
import SetbeamCore

struct MainView: View {
    @ObservedObject var model: SessionModel
    @State private var popover: MonitorPopover?

    private enum MonitorPopover { case source, sound, sharing, invite }
    private var outgoingNeedsAttention: Bool {
        model.outgoingNeedsAttention
    }
    private var sharingTitle: String {
        model.sharingTitle
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let width = min(geometry.size.width, geometry.size.height * 16 / 9)
                picture
                    .frame(width: width, height: width * 9 / 16)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }.padding(.horizontal, 16).padding(.top, 8)
            feedback
            audienceBar
        }
        .frame(minWidth: 640, idealWidth: 900, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowPersistence())
        .toolbar {
            ToolbarItem(placement: .navigation) { sourceButton }
            ToolbarItem(placement: .principal) { Spacer() }
            ToolbarItemGroup(placement: .automatic) {
                Button { togglePopover(.sound) } label: {
                    Label("Sound on this Mac", systemImage: model.localMuted ? "speaker.slash" : "speaker.wave.2")
                }.help("Sound on this Mac").popover(isPresented: presentation(.sound), arrowEdge: .bottom) {
                    MonitorSoundPopover(model: model)
                }
                Button { model.togglePiP() } label: {
                    Label(model.pipVisible ? "Hide floating preview" : "Show floating preview", systemImage: model.pipVisible ? "pip.exit" : "pip.enter")
                }.disabled(model.preview == nil)
                    .help(model.pipVisible ? "Hide floating preview" : "Show floating preview")
                settingsMenu
            }
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .connection: ConnectionView(model: model)
            case .advanced: AdvancedView(model: model)
            case .incoming: IncomingSetupView(model: model)
            case .join: JoinCodesView(model: model)
            case .viewingWiFi: ViewingWiFiView(model: model)
            case .viewers: ViewerStatusView(model: model)
            case .setupCheck: SetupCheckView(model: model)
            case .rename: SessionNameView(model: model)
            case .about: AboutView(model: model)
            }
        }
        .onChange(of: model.sheet) { _, sheet in if sheet != nil { popover = nil } }
        .onChange(of: model.state.sharing) { _, sharing in
            if !sharing && popover == .invite { popover = nil }
        }
        .onAppear { model.launch() }
    }

    private var sourceButton: some View {
        Button { togglePopover(.source) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                HStack(spacing: 5) {
                    Text(model.sourceLabel)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.lineLimit(1).frame(minWidth: 120, idealWidth: 200, maxWidth: 320, alignment: .leading)
                .padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).help("Source and session")
            .accessibilityLabel("Source and session. \(model.title). \(model.sourceLabel)")
            .popover(isPresented: presentation(.source), arrowEdge: .bottom) {
                MonitorSourcePopover(model: model, show: showSheet)
            }
    }

    private var settingsMenu: some View {
        Menu {
            Button("Test my setup…", systemImage: "checkmark.circle") { showSheet(.setupCheck) }
            Button("Viewing network…", systemImage: "wifi") { model.openAdvanced(section: .network) }
            if model.setup?.kind == .capture {
                Button("Audio routing…", systemImage: "waveform") { model.openAdvanced(section: .connection) }
            }
            Divider()
            Button("Save frame", systemImage: "photo") { model.saveFrame() }.disabled(!model.localReady)
            Button("Diagnostics…", systemImage: "info.circle") { model.openAdvanced(section: .diagnostics) }
            Button("Advanced…") { model.openAdvanced() }
            Divider()
            Button("About Setbeam") { showSheet(.about) }
        } label: { Image(systemName: "gearshape").accessibilityLabel("Settings and actions") }
        .help("Settings and actions").accessibilityLabel("Settings and actions")
    }

    private var picture: some View {
        ZStack {
            if model.setup != nil {
                PlayerView(player: model.localPlayer, placeholder: model.recoveryTitle,
                    physicalStep: !model.busy && !model.connectingToPicture && !model.state.sourceAvailable && model.setup?.kind != .sample,
                    connectionStage: model.connectionStage, inputKind: model.setup?.kind ?? .sample, stageTitle: model.connectionStageTitle,
                    lastPicture: model.lastFrameAt == nil ? nil : model.frameAgeLabel)
            } else {
                Color(nsColor: .underPageBackgroundColor)
                VStack(spacing: 13) {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
                    Text("Your picture starts here").font(.title3.weight(.medium))
                    Text("Connect a computer display or camera.").font(.callout).foregroundStyle(.secondary)
                    Button("Choose a source") { model.openSources() }.buttonStyle(.borderedProminent).padding(.top, 3)
                }.padding(20)
            }
        }.background(.black).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.setup != nil && !model.localReady && !model.preparingPicture { recovery }
            if let message = model.error { issue(message) { model.error = nil } }
            if model.networkChanged {
                issue(model.state.sharing ? "The viewing address changed. Invite viewers with the current code. Sharing and Hold are preserved." : "The viewing network changed. Your monitor continues. Start sharing to invite viewers again.") { model.networkChanged = false }
            }
            if outgoingNeedsAttention && model.localReady {
                Label(model.state.holding ? "Restoring the holding picture. Source picture and sound stay hidden." : "The outgoing picture is reconnecting. Your monitor continues.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !model.localReady, let previous = model.previousSourceName {
                Button("Return to previous source: \(previous)") { model.returnToPreviousSource() }
                    .buttonStyle(.link).font(.caption).disabled(model.busy)
            }
        }.padding(.horizontal, 16).padding(.top, 8)
    }

    private var audienceBar: some View {
        HStack(spacing: 12) {
            Button { togglePopover(.sharing) } label: {
                HStack(spacing: 8) {
                    if !model.state.sharing { Image(systemName: "lock").foregroundStyle(.secondary) }
                    else if outgoingNeedsAttention { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                    else { Circle().fill(model.state.holding ? Color.orange : Color.green).frame(width: 6, height: 6) }
                    Text(sharingTitle)
                }.font(.caption).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .foregroundStyle(model.state.holding || outgoingNeedsAttention ? Color.orange : Color.primary)
                .help("Sharing status and outgoing picture")
                .accessibilityLabel("\(sharingTitle). Sharing status and outgoing picture")
                .popover(isPresented: presentation(.sharing), arrowEdge: .top) {
                    MonitorSharingPopover(model: model, show: showSheet)
                }
            if model.state.sharing && !model.state.holding {
                Button { togglePopover(.sharing) } label: {
                    Label("\(model.verifiedViewers)", systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("\(model.verifiedViewers) viewers playing")
                    .accessibilityLabel("\(model.verifiedViewers) viewers playing. Show sharing status")
            }
            if model.state.holding && model.localReady {
                Text("Your monitor continues").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if model.busy || model.outgoingIsChanging { ProgressView().controlSize(.mini).accessibilityLabel("Updating session") }
            if model.state.sharing {
                HStack(spacing: 10) {
                    Button { togglePopover(.invite) } label: { Image(systemName: "qrcode").frame(width: 24, height: 22) }
                        .help("Invite viewers").accessibilityLabel("Invite viewers")
                        .popover(isPresented: presentation(.invite), arrowEdge: .top) {
                            MonitorInvitePopover(model: model, show: showSheet)
                        }
                    if model.state.holding { holdButton.tint(.orange).buttonStyle(.borderedProminent) }
                    else { holdButton.buttonStyle(.bordered) }
                    Button { model.stopSharing() } label: { Image(systemName: "stop.fill").frame(width: 24, height: 22) }
                        .disabled(model.busy).help("Stop sharing").accessibilityLabel("Stop sharing")
                }.buttonStyle(.bordered).controlSize(.regular)
            } else {
                Button("Start sharing") { model.startSharing() }
                    .buttonStyle(.borderedProminent).disabled(!model.canShare).keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 64)
    }

    private var holdButton: some View {
        Button { model.toggleHold() } label: {
            Image(systemName: model.state.holding ? "play.fill" : "pause.fill").frame(width: 24, height: 22)
        }.disabled(model.busy || model.state.holding && !model.localReady)
            .help(model.state.holding ? "Resume sharing" : "Hold audience")
            .accessibilityLabel(model.state.holding ? "Resume sharing" : "Hold audience")
    }

    private var recovery: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cable.connector").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.recoveryDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if model.permissionDenied { Button("Open Privacy Settings") { model.openPrivacySettings() } }
                    else if model.setup?.kind == .incoming { Button("Accsoon setup") { showSheet(.incoming) } }
                    else if model.setup?.kind == .network || model.setup?.kind == .accsoon { Button("Open Wi-Fi Settings") { model.openWiFiSettings() } }
                    Button("Retry now") { model.retry() }.disabled(model.busy)
                    if let saved = model.provenSetup, saved.id != model.setup?.id { Button("Use last working setup") { model.restore(saved) } }
                }.buttonStyle(.link).font(.caption)
            }
        }.padding(.vertical, 4)
    }

    private func issue(_ message: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }.padding(10).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func presentation(_ item: MonitorPopover) -> Binding<Bool> {
        Binding(get: { popover == item }, set: { visible in
            if visible { popover = item } else if popover == item { popover = nil }
        })
    }
    private func togglePopover(_ item: MonitorPopover) { popover = popover == item ? nil : item }
    private func showSheet(_ sheet: AppSheet) { popover = nil; model.sheet = sheet }
}

private struct WindowPersistence: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { MainWindowAnchor() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class MainWindowAnchor: NSView {
        private var configured = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !configured else { return }; configured = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            let name = CommandLine.arguments.contains("--integration-demo") ? "SetbeamIntegrationMain" : "SetbeamMain"
            _ = window.setFrameUsingName(name)
            window.setFrameAutosaveName(name)
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        }
    }
}

struct QRView: View {
    let payload: String
    let size: CGFloat
    @State private var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage: image).resizable().interpolation(.none).scaledToFit() } else { ProgressView() } }
            .frame(width: size - 32, height: size - 32).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 10))
            .task(id: payload) { image = QRCode.image(payload) }
            .accessibilityLabel("QR code. Use Copy Link for an accessible viewing link.")
    }
}
