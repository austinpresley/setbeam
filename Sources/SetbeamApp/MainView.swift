import SwiftUI
import AppKit
import SetbeamCore

struct MainView: View {
    @ObservedObject var model: SessionModel
    @State private var popover: MonitorPopover?
    @State private var sharingExpanded = false
    @State private var pictureHovered = false
    @State private var lastSharingSection = SharingSection.invite
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var windowPresentation = MainWindowPresentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum MonitorPopover { case source, sound }
    private var inlineSharing: Bool { model.sharingSection != nil && !model.sharingInWindow }
    private var showingSourceRecovery: Bool { model.setup != nil && !model.localReady }

    var body: some View {
        VStack(spacing: 0) {
            toolbar.zIndex(1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    GeometryReader { geometry in
                        picture.frame(width: geometry.size.width, height: geometry.size.height)
                            .onAppear { if !inlineSharing { windowPresentation.monitorWidth = geometry.size.width } }
                            .onChange(of: geometry.size) { _, size in if !inlineSharing { windowPresentation.monitorWidth = size.width } }
                    }.background(MonitorStyle.stage, ignoresSafeAreaEdges: []).environment(\.colorScheme, .dark)
                    feedback
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if inlineSharing {
                    Divider()
                    SharingPanel(model: model).frame(width: SharingPanelLayout.width)
                }
            }.frame(maxHeight: .infinity)
        }
        .frame(minWidth: inlineSharing ? 640 + SharingPanelLayout.extraWidth : 640,
            idealWidth: inlineSharing ? 900 + SharingPanelLayout.extraWidth : 900, minHeight: 420)
        .background(SetbeamChrome.toolbar)
        .allowsHitTesting(model.sheet != .connection)
        .accessibilityHidden(model.sheet == .connection)
        .disabled(model.sheet == .connection)
        .overlay(alignment: .top) {
            if model.sheet == .connection { sourceChooser }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowPersistence(presentation: windowPresentation, model: model))
        .sheet(item: nativeSheet) { sheet in
            switch sheet {
            case .connection: EmptyView()
            case .sourceDetails: SourceDetailsView(model: model).id(model.setup?.id)
            case .networkSource: NetworkSourceView(model: model)
            case .incoming: IncomingSetupView(model: model)
            case .join: JoinCodesView(model: model)
            case .setupCheck: SetupCheckView(model: model)
            case .rename: SessionNameView(model: model)
            case .about: AboutView(model: model)
            case .permissions: PermissionsView(model: model)
            }
        }
        .onChange(of: model.sheet) { _, sheet in
            if sheet != nil { popover = nil }
            model.sharingCanDock = windowPresentation.canEmbedSharing && sheet == nil
        }
        .onChange(of: model.sharingSection) { _, section in
            if let section { lastSharingSection = section }
            updateSharingPresentation()
        }
        .onChange(of: model.sharingFocusRequest) { _, _ in updateSharingPresentation() }
        .onChange(of: model.sharingInWindow) { _, _ in updateSharingPresentation() }
        .onAppear {
            model.launch(); updateSharingPresentation()
        }
    }

    private var nativeSheet: Binding<AppSheet?> {
        Binding(get: { model.sheet == .connection ? nil : model.sheet }, set: { model.sheet = $0 })
    }

    private var sourceChooser: some View {
        GeometryReader { geometry in
            let top: CGFloat = geometry.size.height < 540 ? 64 : 84
            ZStack(alignment: .top) {
                Color.black.opacity(0.35).accessibilityHidden(true)
                ConnectionView(model: model,
                               width: min(780, geometry.size.width - 32),
                               availableHeight: max(200, geometry.size.height - top - 104))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.40), radius: 24, y: 12)
                    .padding(.top, top)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            sourceButton.layoutPriority(1)
            Spacer(minLength: 8)
            if model.state.sharing {
                ToolbarPeople(model: model)
                ChromeIconButton("Chat", symbol: "bubble.left", badge: model.chatUnreadCount,
                                 hint: model.chatUnreadCount == 0 ? "Show chat" : "\(model.chatUnreadCount) unread chat messages") {
                    model.showSharing(.chat)
                }.foregroundStyle(.secondary)
                Divider().frame(height: 16).padding(.horizontal, 4)
            }
            ChromeIconButton("Sound on this Mac", symbol: model.localMuted ? "speaker.slash" : "speaker.wave.2") {
                togglePopover(.sound)
            }.disabled(model.preview == nil).foregroundStyle(.secondary)
                .popover(isPresented: presentation(.sound), arrowEdge: .bottom) { MonitorSoundPopover(model: model) }
            ChromeIconButton(model.pipVisible ? "Hide floating preview" : "Show floating preview",
                             symbol: model.pipVisible ? "pip.exit" : "pip.enter") { model.togglePiP() }
                .disabled(model.preview == nil).foregroundStyle(.secondary)
            ChromeIconButton(model.sharingSection == nil ? "Show Sharing panel" : "Hide Sharing panel",
                             symbol: "sidebar.trailing", selected: model.sharingSection != nil) {
                if model.sharingSection == nil { model.showSharing(lastSharingSection) } else { model.closeSharing() }
            }.foregroundStyle(.secondary)
            SharingTally(model: model).padding(.leading, 8)
        }.padding(.leading, 96).padding(.trailing, 12)
            .frame(height: 52).background(SetbeamChrome.toolbar)
            .overlay(alignment: .bottom) { SetbeamChrome.line.frame(height: 1) }
    }

    private var sourceButton: some View {
        Button {
            if model.setup == nil { model.openSources() } else { togglePopover(.source) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.setup?.kind == .sample ? "play.rectangle" : model.setup == nil ? "rectangle.on.rectangle" : SourceCategory.initial(for: model.setup).symbol)
                Text(model.setup == nil ? "Choose source" : model.sourceLabel).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.font(.system(size: 13, weight: model.setup == nil ? .medium : .semibold))
                .foregroundStyle(model.setup == nil ? .secondary : .primary)
                .padding(.horizontal, 8).frame(height: 28)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(ChromeButtonStyle()).help(model.setup == nil ? "Choose a source" : "\(model.sourceLabel) · Source and session settings")
            .accessibilityLabel(model.setup == nil ? "Choose source" : "Source and session. \(model.sourceLabel)")
            .popover(isPresented: presentation(.source), arrowEdge: .bottom) {
                MonitorSourcePopover(model: model, show: showSheet)
            }
    }

    private var picture: some View {
        let sharing = model.audiencePresentation
        return ZStack {
            MonitorStyle.stage
            if showingSourceRecovery {
                SourceRecoveryView(model: model)
            } else if model.setup != nil {
                PlayerView(player: model.localPlayer, placeholder: model.recoveryTitle,
                    physicalStep: !model.busy && !model.connectingToPicture && !model.state.sourceAvailable && model.setup?.kind != .sample,
                    connectionStage: model.connectionStage, inputKind: model.setup?.kind ?? .sample, stageTitle: model.connectionStageTitle,
                    lastPicture: model.lastFrameAt == nil ? nil : model.frameAgeLabel,
                    pointers: model.showsPointers ? model.pointerPresence : nil)
                    .saturation(sharing.confirmedHold ? 0.55 : 1)
                if sharing.confirmedHold { Color.black.opacity(0.36).allowsHitTesting(false).accessibilityHidden(true) }
                if sharing.confirmedHold || sharing.phase == .sharing {
                    pictureAction(sharing)
                        .opacity(sharing.confirmedHold || pictureHovered ? 1 : 0)
                        .allowsHitTesting(sharing.confirmedHold || pictureHovered)
                        .accessibilityHidden(!sharing.confirmedHold && !pictureHovered)
                }
            } else {
                SourceStartView(model: model)
            }
        }.onHover { pictureHovered = $0 }
            .overlay(alignment: .topLeading) {
                if model.setup?.kind == .sample {
                    Label("SAMPLE", systemImage: "play.rectangle").font(.system(size: 10, weight: .bold)).tracking(0.7)
                        .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5)).padding(12)
                        .accessibilityLabel("Sample media")
                }
            }
    }

    private func pictureAction(_ sharing: AudiencePresentation) -> some View {
        Button { model.performAudienceAction() } label: {
            Image(systemName: sharing.primarySymbol).font(.system(size: 29, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(.black.opacity(0.53), in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1) }
                .contentShape(Circle())
        }.buttonStyle(.plain).disabled(!sharing.primaryEnabled)
            .accessibilityLabel(sharing.primaryTitle).accessibilityHint(sharing.primaryHelp)
            .help("\(sharing.primaryTitle) · \(sharing.primaryHelp)")
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !showingSourceRecovery, let message = model.error {
                issue(message) { model.error = nil }
                if model.permissionDenied {
                    HStack(spacing: 12) {
                        Button("Open Privacy Settings") { model.openPrivacySettings() }
                        Button("Retry Now") { model.retry() }.disabled(model.busy)
                    }.buttonStyle(.link).font(.caption)
                }
            }
            if model.networkChanged {
                issue(model.state.sharing ? "The viewing address changed. Invite viewers with the current code. Sharing and Hold are preserved." : "The viewing network changed. Your monitor continues. Start sharing to invite viewers again.") { model.networkChanged = false }
            }
        }.padding(.horizontal, 20).padding(.vertical, hasFeedback ? 8 : 0)
    }
    private var hasFeedback: Bool {
        !showingSourceRecovery && model.error != nil || model.networkChanged
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
    private func showSheet(_ sheet: AppSheet) { popover = nil; model.present(sheet) }
    private func updateSharingPresentation() {
        popover = nil
        model.sharingCanDock = windowPresentation.canEmbedSharing && model.sheet == nil
        let destination = SharingDestination.resolve(section: model.sharingSection, preferWindow: model.sharingInWindow,
            hasSheet: model.sheet != nil, screenWidth: windowPresentation.screenWidth)
        switch destination {
        case .hidden:
            if sharingExpanded { windowPresentation.resizeForSharing(showing: false, animate: !reduceMotion) }
            sharingExpanded = false
            model.sharingInWindow = false
            dismissWindow(id: "sharing")
        case .window:
            model.sharingInWindow = true
            if sharingExpanded { windowPresentation.resizeForSharing(showing: false, animate: !reduceMotion) }
            sharingExpanded = false
            openWindow(id: "sharing")
        case .inline:
            if !sharingExpanded {
                windowPresentation.resizeForSharing(showing: true, animate: !reduceMotion)
                sharingExpanded = true
            }
            dismissWindow(id: "sharing")
        }
    }

}

private struct WindowPersistence: NSViewRepresentable {
    let presentation: MainWindowPresentation
    let model: SessionModel
    func makeNSView(context: Context) -> NSView { MainWindowAnchor(presentation: presentation, model: model) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class MainWindowAnchor: NSView {
        private let presentation: MainWindowPresentation
        private var configured = false
        private weak var model: SessionModel?
        private var escapeMonitor: Any?
        init(presentation: MainWindowPresentation, model: SessionModel) { self.presentation = presentation; self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !configured else { return }; configured = true
            presentation.window = window
            model?.monitorWindow = window
            DispatchQueue.main.async { [weak self] in self?.screenChanged() }
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: window)
            let toolbar = NSToolbar(identifier: "SetbeamWindowChrome")
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
                guard event.keyCode == 53, let window, NSApp.keyWindow === window,
                      let model = self?.model, model.sheet == .connection else { return event }
                model.sheet = nil
                return nil
            }
            let name = CommandLine.arguments.contains("--integration-demo") ? "SetbeamIntegrationMain" : "SetbeamMain"
            _ = window.setFrameUsingName(name)
            window.setFrameAutosaveName(name)
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        }
        @objc private func screenChanged() {
            model?.sharingCanDock = presentation.canEmbedSharing && model?.sheet == nil
        }
        deinit {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            NotificationCenter.default.removeObserver(self)
        }
    }
}

private final class MainWindowPresentation: ObservableObject {
    weak var window: NSWindow?
    private var addedWidth: CGFloat = 0
    var monitorWidth: CGFloat = 0

    var screenWidth: CGFloat { window?.screen?.visibleFrame.width ?? NSScreen.main?.visibleFrame.width ?? 0 }
    var canEmbedSharing: Bool { SharingPanelLayout.fits(on: screenWidth) }

    func resizeForSharing(showing: Bool, animate: Bool) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        var frame = window.frame
        if showing {
            let screen = window.screen?.visibleFrame ?? frame
            let required = monitorWidth > 0 ? monitorWidth + SharingPanelLayout.extraWidth : frame.width + SharingPanelLayout.extraWidth
            let width = min(max(frame.width, required), screen.width)
            addedWidth = max(0, width - frame.width)
            frame.size.width = width
            frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - width))
        } else {
            frame.size.width = max(640, frame.width - addedWidth)
            addedWidth = 0
        }
        // Apply after SwiftUI updates the content's minimum width for the new layout.
        DispatchQueue.main.async { [weak window] in window?.setFrame(frame, display: true, animate: animate) }
    }
}

struct QRView: View {
    let payload: String
    let size: CGFloat
    var inset: CGFloat = 16
    @State private var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage: image).resizable().interpolation(.none).scaledToFit() } else { ProgressView() } }
            .frame(width: size - 2 * inset, height: size - 2 * inset).padding(inset).background(.white, in: RoundedRectangle(cornerRadius: 10))
            .task(id: payload) { image = QRCode.image(payload) }
            .accessibilityLabel("QR code. Use Copy Link for an accessible viewing link.")
    }
}
