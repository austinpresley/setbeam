import SwiftUI
import AppKit
import SetbeamCore

struct MainView: View {
    @ObservedObject var model: SessionModel
    @State private var popover: MonitorPopover?
    @State private var sharingExpanded = false
    @State private var lastSharingSection = SharingSection.invite
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var windowPresentation = MainWindowPresentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum MonitorPopover { case source, sound }
    private var inlineSharing: Bool { model.sharingSection != nil && !model.sharingInWindow }
    private var showingSourceRecovery: Bool { model.setup != nil && !model.localReady }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                MonitorCommandBar(model: model)
                VStack(alignment: .leading, spacing: 0) {
                    GeometryReader { geometry in
                        picture.frame(width: geometry.size.width, height: geometry.size.height)
                            .onAppear { if !inlineSharing { windowPresentation.monitorWidth = geometry.size.width } }
                            .onChange(of: geometry.size) { _, size in if !inlineSharing { windowPresentation.monitorWidth = size.width } }
                    }
                }.background(MonitorStyle.stage).environment(\.colorScheme, .dark)
                feedback
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if inlineSharing {
                Divider()
                SharingPanel(model: model).frame(width: SharingPanelLayout.width)
            }
        }.frame(maxHeight: .infinity)
        .frame(minWidth: inlineSharing ? 640 + SharingPanelLayout.extraWidth : 640,
            idealWidth: inlineSharing ? 900 + SharingPanelLayout.extraWidth : 900, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowPersistence(presentation: windowPresentation, model: model))
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
                Toggle(isOn: Binding(get: { model.sharingSection != nil }, set: { shown in
                    if shown { model.showSharing(lastSharingSection) } else { model.closeSharing() }
                })) {
                    Label("Sharing", systemImage: "sidebar.trailing")
                }.toggleStyle(.button)
                    .help(model.sharingSection == nil ? "Show Sharing panel" : "Hide Sharing panel")
                    .accessibilityLabel(model.sharingSection == nil ? "Show Sharing panel" : "Hide Sharing panel")
            }
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .connection: ConnectionView(model: model)
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

    private var sourceButton: some View {
        Button { togglePopover(.source) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Image(systemName: model.setup?.kind == .sample ? "play.rectangle" : model.setup == nil ? "rectangle.on.rectangle" : SourceCategory.initial(for: model.setup).symbol)
                    Text(model.sourceLabel)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.lineLimit(1).frame(minWidth: 120, idealWidth: 200, maxWidth: 320, alignment: .leading)
                .padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).help("\(model.title)\n\(model.sourceLabel)\nChoose a source or open its details")
            .accessibilityLabel("Source and session. \(model.title). \(model.sourceLabel)")
            .popover(isPresented: presentation(.source), arrowEdge: .bottom) {
                MonitorSourcePopover(model: model, show: showSheet)
            }
    }

    private var picture: some View {
        ZStack {
            if showingSourceRecovery {
                SourceRecoveryView(model: model)
            } else if model.setup != nil {
                PlayerView(player: model.localPlayer, placeholder: model.recoveryTitle,
                    physicalStep: !model.busy && !model.connectingToPicture && !model.state.sourceAvailable && model.setup?.kind != .sample,
                    connectionStage: model.connectionStage, inputKind: model.setup?.kind ?? .sample, stageTitle: model.connectionStageTitle,
                    lastPicture: model.lastFrameAt == nil ? nil : model.frameAgeLabel,
                    pointers: model.showsPointers ? model.pointerPresence : nil)
            } else {
                MonitorStyle.stage
                VStack(spacing: 13) {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
                    Text("Your picture starts here").font(.title3.weight(.medium))
                    Text("Connect a computer display or camera.").font(.callout).foregroundStyle(.secondary)
                    Button("Choose a source") { model.openSources() }.buttonStyle(.borderedProminent).padding(.top, 3)
                }.padding(20)
            }
        }.background(MonitorStyle.stage)
            .overlay(alignment: .topLeading) {
                if model.setup?.kind == .sample {
                    Text("Sample media").font(.caption).foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4)).padding(12)
                }
            }
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
        init(presentation: MainWindowPresentation, model: SessionModel) { self.presentation = presentation; self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !configured else { return }; configured = true
            presentation.window = window
            model?.monitorWindow = window
            DispatchQueue.main.async { [weak self] in self?.screenChanged() }
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: window)
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            let name = CommandLine.arguments.contains("--integration-demo") ? "SetbeamIntegrationMain" : "SetbeamMain"
            _ = window.setFrameUsingName(name)
            window.setFrameAutosaveName(name)
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        }
        @objc private func screenChanged() {
            model?.sharingCanDock = presentation.canEmbedSharing && model?.sheet == nil
        }
        deinit { NotificationCenter.default.removeObserver(self) }
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
    @State private var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage: image).resizable().interpolation(.none).scaledToFit() } else { ProgressView() } }
            .frame(width: size - 32, height: size - 32).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 10))
            .task(id: payload) { image = QRCode.image(payload) }
            .accessibilityLabel("QR code. Use Copy Link for an accessible viewing link.")
    }
}
