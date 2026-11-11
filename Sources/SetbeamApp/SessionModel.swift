import Foundation
import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import IOKit.pwr_mgt
import SetbeamCore

enum AppSheet: String, Identifiable { case connection, sourceDetails, networkSource, incoming, join, setupCheck, rename, about, permissions; var id: String { rawValue } }

@MainActor final class SessionModel: ObservableObject {
    @Published var title: String { didSet { if !integration { defaults.set(title, forKey: "sessionTitle") }; publishGatewayState() } }
    @Published private(set) var state: SessionState
    @Published var source: VideoSource = .sample
    @Published var setup: SourceSetup?
    @Published var provenSetup: SourceSetup?
    @Published var preview: PlaybackDescriptor?
    /// The IP address link. Join codes always use it, and it remains the fallback for every invitation.
    @Published var viewerURL: URL?
    /// Whether to publish a readable `.local` name for the viewing address while sharing.
    @Published private(set) var localAddressEnabled: Bool
    /// The operator's chosen label. The effective name can differ after a conflict.
    @Published private(set) var localAddressLabel: String
    @Published private(set) var localAddress: LocalAddressState = .stopped
    private let localAddressPublisher = LocalAddressPublisher()
    /// Whether viewers may type the local address by itself and ask to join. Off by default, and only
    /// in effect while sharing with viewer approval and an active local address.
    @Published private(set) var shortAddressEnabled: Bool
    @Published private(set) var shortAddress: ShortAddressListener.State = .stopped
    private let shortAddressListener = ShortAddressListener()
    /// Changes with each viewing link, so a request from an earlier link can never be admitted into this one.
    private(set) var viewingLink = 0
    /// Requests to join, announced once each with a card that keeps this Mac's other apps in front.
    let joinRequests = JoinRequestCenter()
    @Published var viewers: [ViewerActivity] = [] { didSet { observeJoinRequests() } }
    @Published var busy = false
    @Published private(set) var stoppingSharing = false
    @Published private var preparingConnection = false
    @Published var error: String? {
        didSet { if let error, error != oldValue { SessionLog.shared.record("operator.message", ["message": error]) } }
    }
    @Published var localMuted = true {
        didSet { localPlayer.muted = localMuted }
    }
    let localPlayer = NativePreview()
    let audiencePlayer = NativePreview(audioEnabled: false, width: 384, frameRate: 8)
    @Published var audiencePreviewPlaying = false
    @Published private var outgoingTransition = OutgoingTransition()
    @Published private(set) var audienceControl = AudienceControlState()
    @Published var sourceHasAudio = false
    @Published var audienceHasAudio = false
    @Published var expectsAudio = false
    @Published var testSoundConfirmed = false
    let sourceBrowser: SourceBrowser
    @Published var pipVisible = false
    @Published var sheet: AppSheet?
    @Published var sourceDetailsDirty = false
    var protectsSourceDraft: Bool { sheet == .sourceDetails && sourceDetailsDirty }
    @Published var sharingSection: SharingSection?
    private var lastSharingSection = SharingSection.invite
    @Published var sharingInWindow = false
    @Published private(set) var sharingFocusRequest = 0
    @Published var sharingCanDock = true
    weak var monitorWindow: NSWindow?
    var openMonitor: (() -> Void)?
    func reopenMonitor() {
        openMonitor?()
        monitorWindow?.deminiaturize(nil)
        monitorWindow?.makeKeyAndOrderFront(nil)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    weak var sharingWindow: NSWindow?
    @Published var settingsSection: SettingsSection = .permissions
    @Published var sharingDraft: SharingOptionsDraft?
    @Published var viewingWiFiDraft: ViewingWiFiDraft?
    @Published private(set) var chatMessages: [ChatMessage] = []
    @Published private(set) var chatImages: [Int: NSImage] = [:]
    @Published private(set) var chatCapturing = false
    @Published private var chatReadThrough = 0
    var chatUnreadCount: Int { chatMessages.filter { !$0.operatorMessage && $0.id > chatReadThrough }.count }
    func markChatRead() { let id = chatMessages.last?.id ?? 0; if chatReadThrough != id { chatReadThrough = id } }
    @Published var chatText = ""
    @Published var chatReplyTo: Int?
    @Published private(set) var chatAttachment: Data?
    @Published var chatProblem: String?
    @Published var chatOperatorName = "DigiTech" { didSet { if !integration { defaults.set(chatOperatorName, forKey: "chatOperatorName") } } }
    @Published var chatOperatorColor = PointerColor.orange { didSet { if !integration { defaults.set(chatOperatorColor.rawValue, forKey: "chatOperatorColor") } } }
    private var chatAttachmentRevision: Int?
    private var chatAttachmentLink: Int?
    private var chatCaptureGeneration = UUID()
    @Published private(set) var sharingOptionsTarget = 0
    @Published private(set) var sharingOptionsNetworkRequested = false
    private var loadedWiFiSSID: String?
    @Published var networks: [NetworkAddress]
    @Published var viewerAddress: String
    @Published var networkChoice: String
    @Published var wifiSSID: String
    @Published var wifiPassword = ""
    @Published private(set) var viewingWiFiPasswordAvailable = true
    @Published var screenDisplays: [MacDisplay] = []
    /// Observed for a selected window only. Never used to choose a different window.
    @Published private(set) var windowPresence: MacWindowPresence?
    @Published private(set) var windowTitle: String?
    private var windowReturn = WindowReturnRetry()
    /// Isolated QA sessions can list only their generated fixture windows, keeping private desktop content out of captures.
    let windowListBundle: String?
    @Published var captureDevices: [CaptureHardware] = []
    @Published var wirelessDevices: [AccsoonDevice] = []
    @Published var wirelessDiscoveryProblem: String?
    @Published var nativePreviewPlaying = false
    @Published var setupConfirmed = false
    @Published var copiedLink = false
    @Published var copiedIPLink = false
    @Published var lastFrameAt: Date?
    private var pendingScreenPermission: (setup: SourceSetup, remember: Bool)?
    private var screenPermissionDenied = false
    @Published var permissionDenied = false
    @Published var networkChanged = false
    @Published var diagnosticCopied = false
    @Published var incomingServer = ""
    @Published var incomingStreamKey = ""
    @Published private(set) var audienceQuality: AudienceQuality
    @Published private(set) var audienceFrameRate: VideoFrameRate
    @Published private(set) var screenFrameRate: VideoFrameRate
    @Published private(set) var transmitterRejoin: Bool
    /// Viewers ask to join and play only after the operator admits them.
    @Published private(set) var viewerApproval: Bool
    /// Admitted viewers may opt in to point at the picture with a name and color.
    @Published private(set) var sharedPointers: Bool
    /// Whether this Mac's main and floating monitors draw viewers' pointers. A separate operator view
    /// choice from letting viewers point; it is never saved and starts off for each sharing session.
    @Published private(set) var pointersOnThisMac = false
    @Published private(set) var pointersOnSourceDisplay = false
    private let sourceDisplayPointers = SourceDisplayPointers()
    private var pointerDisplayIdentity: String?
    private var displayObserver: NSObjectProtocol?
    /// Native pointer overlay state. Observed only by the overlays, not by whole windows.
    let pointerPresence = PointerPresenceModel()
    private var accessSync: Task<Void, Never>?
    private var accessSyncAgain = false
    @Published var transmitterWiFiPassword = ""
    @Published private(set) var transmitterOpenNetwork = false
    @Published var rejoinProblem: String?
    private(set) var savedNetworkURL = ""
    private var nativePreviewProblem: String?
    private let defaults: UserDefaults
    private let integration: Bool
    private let store: ProvenSetupStore
    private let runtime = MediaRuntime(paths: AppAssets.runtimePaths)
    private let gateway = ViewerGateway(assets: AppAssets.viewerAssets)
    private var currentRuntime: RuntimeSnapshot?
    private var gatewayPort: UInt16?
    private var viewerInterface: String
    private var viewerNetworkNeedsUpdate = false
    private var pollTask: Task<Void, Never>?
    private var runtimeUpdates: Task<Void, Never>?
    private var launched = false, shuttingDown = false
    private var readiness = SetupReadiness()
    private var activeNetworkURL: String?
    private var previousSource: (setup: SourceSetup, address: String?, remember: Bool)?
    @Published private(set) var rememberSetup = true
    @Published private(set) var rememberFailed = false
    private var connectedAt = Date.distantPast
    private var lastRuntimeProblem = ""
    private let sharingPower = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep, reason: "Setbeam feed sharing")
    private let displayPower = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: "Setbeam live monitoring")
    private var loggedViewers = (opened: 0, playing: 0)
    private let transmitterWiFi = TransmitterWiFi()
    private var rejoinPolicy = TransmitterRejoinPolicy()
    private var rejoinInFlight = false
    private var rejoinAttempt: (permit: RejoinPermit, ssid: String)?
    private var observers: [NSObjectProtocol] = []
    private lazy var floating = FloatingPreviewWindow(model: self)
    private let joinCodeWindow = JoinCodeWindow()
    func showJoinCodeWindow() { loadViewingWiFi(); joinCodeWindow.show(model: self) }

    init(initialState: SessionState = SessionState(), preferences: UserDefaults? = nil) {
        state = initialState
        integration = CommandLine.arguments.contains("--integration-demo")
        let args = CommandLine.arguments
        if args.contains("--preferences-suite"), let index = args.firstIndex(of: "--pyro-h-fixture-port"), index + 1 < args.count,
           let port = UInt16(args[index + 1]), port > 0 {
            sourceBrowser = SourceBrowser(pyroHNetworks: { [.init(interface: "lo0", address: "127.0.0.1", router: "127.0.0.1")] }, pyroHPorts: [port])
        } else { sourceBrowser = SourceBrowser() }
        windowListBundle = args.contains("--preferences-suite") ? args.firstIndex(of: "--window-fixture-bundle").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } : nil
        if let preferences { defaults = preferences }
        else if let index = args.firstIndex(of: "--preferences-suite"), index + 1 < args.count {
            defaults = UserDefaults(suiteName: args[index + 1])!
        } else { defaults = .standard }
        store = ProvenSetupStore(defaults: defaults)
        title = defaults.string(forKey: "sessionTitle") ?? "My feed"
        chatOperatorName = defaults.string(forKey: "chatOperatorName") ?? "DigiTech"
        chatOperatorColor = defaults.string(forKey: "chatOperatorColor").flatMap(PointerColor.init(rawValue:)) ?? .orange
        settingsSection = SettingsSection(rawValue: defaults.string(forKey: "settingsSection") ?? "") ?? .permissions
        let available = NetworkAddress.available()
        networks = available
        let choice = integration ? "lo0" : defaults.string(forKey: "viewerInterface") ?? "automatic"
        networkChoice = choice
        let selected = choice == "automatic" ? NetworkAddress.preferred(in: available) : available.first { $0.interface == choice }
        viewerInterface = integration ? "lo0" : selected?.interface ?? "lo0"
        viewerAddress = integration ? "127.0.0.1" : selected?.address ?? "127.0.0.1"
        wifiSSID = defaults.string(forKey: "wifiSSID") ?? ""
        provenSetup = integration ? nil : store.setup
        localMuted = integration ? true : defaults.object(forKey: "localMuted") as? Bool ?? true
        audienceQuality = defaults.string(forKey: "audienceQuality").flatMap(AudienceQuality.init(rawValue:)) ?? .best
        audienceFrameRate = VideoFrameRate(rawValue: defaults.integer(forKey: "audienceFrameRate")) ?? .source
        screenFrameRate = VideoFrameRate(rawValue: defaults.integer(forKey: "screenFrameRate")) ?? .source
        transmitterRejoin = integration ? false : defaults.bool(forKey: "transmitterWiFiRejoin")
        viewerApproval = integration ? false : defaults.bool(forKey: "viewerApproval")
        sharedPointers = integration ? false : defaults.bool(forKey: "sharedPointers")
        localAddressEnabled = defaults.object(forKey: "localAddressEnabled") as? Bool ?? true
        localAddressLabel = defaults.string(forKey: "localAddressName").flatMap { try? LocalAddressName.validated($0).get() } ?? LocalAddressName.defaultLabel
        shortAddressEnabled = defaults.bool(forKey: "shortAddressEnabled")
        localAddressPublisher.onChange = { [weak self] state in
            // Deliver in order; the publisher reports each change once on its own queue.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.localAddressChanged(state) } }
        }
        shortAddressListener.onChange = { [weak self] state in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.shortAddressChanged(state) } }
        }
        joinRequests.model = self
        audienceControl.observe(state)
    }

    var sourceLabel: String {
        // The same window can change its title; follow it rather than showing a stale document name.
        if setup?.kind == .macWindow, let app = setup?.deviceName, let windowTitle { return MacWindow.sourceName(application: app, title: windowTitle) }
        return setup?.name ?? "Choose a source"
    }
    var hardwareLabel: String { setup?.deviceName ?? (setup?.kind == .sample ? "Sample video and test tone" : setup?.kind == .network ? "Network video" : "No input selected") }
    var viewerNetworkLabel: String { networks.first(where: { $0.address == viewerAddress })?.name ?? "This Mac only" }
    var canInviteOtherDevices: Bool { viewerAddress != "127.0.0.1" }
    var viewingInstructions: String {
        if viewerAddress == "127.0.0.1" { return "This viewing link works on this Mac only." }
        if !wifiSSID.isEmpty { return "Join \(wifiSSID), then scan to watch." }
        if networks.first(where: { $0.address == viewerAddress })?.wireless == false {
            return "Join the Wi-Fi on this Mac's Ethernet network, then scan."
        }
        if setup?.kind == .accsoon, let ssid = setup?.sourceWiFi, !ssid.isEmpty { return "Join \(ssid), then scan to watch." }
        return "Join the same Wi-Fi as this Mac, then scan to watch."
    }
    var localReady: Bool { state.sourceAvailable && nativePreviewPlaying }
    var floatingPresentation: FloatingPreviewState {
        FloatingPreviewState(session: state, control: audienceControl, localReady: localReady, busy: busy,
                             starting: outgoingTransition.activeChange() == .startSharing, viewers: viewers)
    }
    private var outgoingReady: Bool { state.audienceAvailable && (state.holding || state.sourceAvailable) }
    var audiencePresentation: AudiencePresentation {
        AudiencePresentation(session: state, control: audienceControl, change: outgoingTransition.activeChange(),
                             localReady: localReady, busy: busy, stopping: stoppingSharing)
    }
    var outgoingIsChanging: Bool { state.sharing && audiencePresentation.isChanging }
    var outgoingNeedsAttention: Bool { state.sharing && audiencePresentation.needsAttention }
    var sharingTitle: String { audiencePresentation.title }
    func performAudienceAction() {
        guard audiencePresentation.primaryEnabled, let target = audiencePresentation.primaryTarget else { return }
        setAudienceHold(target.holding)
    }
    var connectionStage: ConnectionStage? {
        guard setup != nil, !localReady, !permissionDenied, preparingConnection || state.monitoring else { return nil }
        return preparingConnection ? .preparingMonitor : currentRuntime?.connectionStage ?? .preparingMonitor
    }
    var connectionStageTitle: String? {
        guard let connectionStage else { return nil }
        if connectionStage == .connectingTransmitter,
           let device = wirelessDevices.first(where: { $0.id == setup?.wirelessUID }), !device.videoAvailable {
            return "Waiting for source video"
        }
        if setup?.kind == .macWindow, let windowPresence, windowPresence != .visible {
            return windowPresence == .closed ? "The selected window closed" : "Waiting for the selected window"
        }
        return connectionStage.title
    }
    var preparingPicture: Bool { connectionStage != nil && (preparingConnection || connectingToPicture) }
    var connectingToPicture: Bool {
        if setup?.kind == .accsoon, let device = wirelessDevices.first(where: { $0.id == setup?.wirelessUID }), !device.videoAvailable { return false }
        return state.monitoring && !localReady && !permissionDenied && error == nil && Date().timeIntervalSince(connectedAt) < 10
    }
    var setupRemembered: Bool { setupConfirmed && provenSetup?.id == setup?.id }
    var previousSourceName: String? {
        guard let previousSource, (try? previousSource.setup.source(address: previousSource.address)) != source else { return nil }
        return previousSource.setup.name
    }
    var verifiedViewers: Int { admittedViewers.filter(\.playing).count }
    var pendingViewers: [ViewerActivity] { viewers.filter { $0.admission == .pending } }
    var admittedViewers: [ViewerActivity] { viewers.filter { $0.admission == .admitted } }
    var pointingViewers: Int { viewers.filter(\.pointing).count }
    var strugglingViewers: [ViewerActivity] {
        guard state.sharing, !state.holding else { return [] }
        return viewers.filter { $0.health == .struggling }
    }
    var viewersForDetails: [ViewerActivity] {
        let first = Set((pendingViewers + strugglingViewers).map(\.id))
        return pendingViewers + strugglingViewers + viewers.filter { !first.contains($0.id) }
    }
    var openedViewers: Int { admittedViewers.count }
    var otherDeviceViewers: Int { viewers.filter { $0.playing && !$0.onThisMac }.count }
    private var appliedReaders: Set<ViewerReader> = []
    /// The approval choice MediaMTX has accepted. A failed change retries, so the shared credential
    /// never stays usable while the gateway is asking viewers to wait.
    private var appliedApproval = false
    /// Pointers describe the live shared picture, so they appear only while it is being shared,
    /// and on this Mac only after the operator chooses to see them.
    var showsPointers: Bool { sharedPointers && pointersOnThisMac && state.sharing && !state.holding }
    func setPointersOnThisMac(_ visible: Bool) {
        guard visible != pointersOnThisMac else { return }
        pointersOnThisMac = visible
        SessionLog.shared.record("viewers.pointersOnThisMac", ["visible": visible])
    }
    var canShowPointersOnSourceDisplay: Bool {
        guard sharedPointers, state.sharing, setup?.kind == .macScreen, let id = setup?.videoID,
              let screen = SourceDisplayPointers.screen(for: id), let size = localPlayer.picture?.size,
              size.width > 0, size.height > 0 else { return false }
        return abs((size.width / size.height) / (screen.frame.width / screen.frame.height) - 1) < 0.005
    }
    func setPointersOnSourceDisplay(_ visible: Bool) {
        pointersOnSourceDisplay = visible && canShowPointersOnSourceDisplay
        updateSourceDisplayPointers()
    }
    private func updateSourceDisplayPointers() {
        let identity = setup?.kind == .macScreen ? setup?.videoID : nil
        if pointerDisplayIdentity != identity { pointersOnSourceDisplay = false; pointerDisplayIdentity = identity }
        if !state.sharing || !sharedPointers { pointersOnSourceDisplay = false }
        sourceDisplayPointers.update(display: identity,
            visible: pointersOnSourceDisplay && canShowPointersOnSourceDisplay && state.audience == .live && audienceControl.pending == nil && !stoppingSharing && !shuttingDown, presence: pointerPresence)
    }

    func setViewerApproval(_ enabled: Bool) {
        guard enabled != viewerApproval else { return }
        viewerApproval = enabled
        if !integration { defaults.set(enabled, forKey: "viewerApproval") }
        SessionLog.shared.record("viewers.approval", ["enabled": enabled])
        gateway.setAccess(approval: enabled, pointers: sharedPointers)
        updateShortAddress()
        viewers = gateway.viewers
        syncViewerAccess()
    }
    func setSharedPointers(_ enabled: Bool) {
        guard enabled != sharedPointers else { return }
        sharedPointers = enabled
        if !integration { defaults.set(enabled, forKey: "sharedPointers") }
        SessionLog.shared.record("viewers.pointers", ["enabled": enabled])
        gateway.setAccess(approval: viewerApproval, pointers: enabled)
        if !enabled { pointerPresence.clear() }
        updateSourceDisplayPointers()
        viewers = gateway.viewers
    }
    func admitViewer(_ viewer: ViewerActivity) {
        guard gateway.approve(number: viewer.number) else { return }
        SessionLog.shared.record("viewer.admit", ["number": viewer.number, "shortAddress": viewer.shortAddress])
        viewers = gateway.viewers; syncViewerAccess()
    }
    func declineViewer(_ viewer: ViewerActivity) {
        guard gateway.decline(number: viewer.number) else { return }
        SessionLog.shared.record("viewer.decline", ["number": viewer.number, "shortAddress": viewer.shortAddress])
        viewers = gateway.viewers
    }
    /// Acts on a request card only if that exact request is still waiting on the current link.
    /// A card from an earlier link, a request already decided elsewhere, or one that lapsed does nothing.
    @discardableResult func answer(_ request: JoinRequest, admit: Bool) -> Bool {
        guard state.sharing, viewerApproval else { return false }
        viewers = gateway.viewers
        guard let viewer = request.current(in: viewers, link: viewingLink) else { return false }
        if admit { admitViewer(viewer) } else { declineViewer(viewer) }
        return true
    }
    private func observeJoinRequests() {
        joinRequests.observe(link: viewingLink, active: state.sharing && viewerApproval, viewers: viewers)
    }
    /// Ends this session's playback and presence immediately; other viewers continue.
    func removeViewer(_ viewer: ViewerActivity) {
        guard gateway.remove(number: viewer.number) else { return }
        SessionLog.shared.record("viewer.remove", ["number": viewer.number])
        viewers = gateway.viewers; syncViewerAccess()
    }
    /// The floating card must not remove a session from an earlier viewing link.
    func removeViewer(_ reference: JoinRequest) {
        guard state.sharing, viewerApproval else { return }
        viewers = gateway.viewers
        guard let current = reference.current(in: viewers, link: viewingLink, admission: .admitted) else { return }
        removeViewer(current)
    }
    /// Applies the gateway's admitted readers to the media server, one change at a time. A page
    /// receives its own credential only after the server has accepted it.
    private func syncViewerAccess() {
        guard accessSync == nil else { accessSyncAgain = true; return }
        accessSync = Task { [weak self] in
            while let self, !self.shuttingDown {
                self.accessSyncAgain = false
                let approval = self.viewerApproval, readers = self.gateway.desiredReaders
                do {
                    try await self.runtime.setViewerAccess(approval: approval, readers: readers)
                    self.appliedReaders = readers; self.appliedApproval = approval
                    self.gateway.confirm(readers: readers)
                    if self.state.monitoring { self.apply(await self.runtime.snapshot()); self.publishGatewayState() }
                } catch {
                    self.lastRuntimeProblem = Redaction.text(error.localizedDescription)
                    self.error = "A viewer access change did not finish. Setbeam will retry."
                }
                guard self.accessSyncAgain else { break }
            }
            self?.accessSync = nil
        }
    }
    var setupCheck: SetupCheck {
        SetupCheck(picture: localReady, viewingAddress: state.sharing && gateway.isRunning && canInviteOtherDevices,
            otherDevicePlaying: otherDeviceViewers > 0, expectsAudio: expectsAudio,
            outgoingAudio: state.audience == .live && audienceHasAudio, soundConfirmed: testSoundConfirmed)
    }
    var incomingAudioLabel: String { !state.sourceAvailable ? "Input audio: waiting" : sourceHasAudio ? "Input audio: track received" : "Input audio: no track" }
    var audienceAudioLabel: String {
        if !state.sharing { return "Audience audio: off" }
        if audiencePresentation.confirmedHold { return "Audience audio: silenced by Hold" }
        if audiencePresentation.phase != .sharing { return "Audience audio: not confirmed" }
        if state.audience != .live { return "Audience audio: reconnecting" }
        return audienceHasAudio ? "Audience audio: included" : "Audience audio: no track"
    }
    var canShare: Bool { localReady && !busy }
    var restoreFloating: Bool { !integration && defaults.bool(forKey: "floatingVisible") }
    var audienceLabel: String {
        guard state.sharing else { return "Only you can see this" }
        return sharingTitle
    }
    var statusLabel: String {
        if preparingConnection { return "Connecting" }
        if setup == nil { return "Choose a source" }
        if connectingToPicture { return "Connecting" }
        if setup?.kind == .accsoon, let device = wirelessDevices.first(where: { $0.id == setup?.wirelessUID }), !device.videoAvailable { return "Waiting for a source" }
        if !localReady { return "Reconnecting" }
        if state.sharing { return sharingTitle }
        return "Private preview"
    }
    var recoveryTitle: String {
        if permissionDenied { return "Allow access to your selected input" }
        guard let setup else { return "Your picture starts here" }
        if connectingToPicture { return "Connecting to \(setup.name)" }
        if setup.kind == .capture && !captureDevices.contains(where: { $0.id == setup.videoID && !$0.audio }) { return "Connect \(setup.deviceName ?? setup.name)" }
        if setup.kind == .accsoon {
            if let device = wirelessDevices.first(where: { $0.id == setup.wirelessUID }), !device.videoAvailable { return "Connect a picture to your transmitter" }
            return "Reconnecting to \(setup.name)"
        }
        if setup.kind == .macWindow, !state.sourceAvailable, let windowPresence, windowPresence != .visible {
            return windowPresence == .closed ? "The selected window closed" : "Waiting for the selected window"
        }
        if state.sourceAvailable && !nativePreviewPlaying { return "Restoring your preview" }
        return setup.kind == .network || setup.kind == .incoming ? "Waiting for \(setup.name)" : "Waiting for a picture"
    }
    /// The floating monitor keeps useful recovery guidance without displaying a source title.
    var floatingRecoveryTitle: String {
        if permissionDenied { return recoveryTitle }
        if connectingToPicture { return connectionStageTitle ?? "Connecting to source" }
        if state.sourceAvailable && !nativePreviewPlaying { return recoveryTitle }
        switch setup?.kind {
        case .capture:
            if !captureDevices.contains(where: { $0.id == setup?.videoID && !$0.audio }) { return "Connect the selected capture device" }
            return recoveryTitle
        case .accsoon:
            if let device = wirelessDevices.first(where: { $0.id == setup?.wirelessUID }), !device.videoAvailable { return "Connect a picture to your transmitter" }
            return "Reconnecting to the selected transmitter"
        case .network: return "Waiting for the selected stream"
        case .incoming: return "Waiting for incoming video"
        default: return recoveryTitle
        }
    }
    var recoveryDetail: String {
        if permissionDenied { return "Enable Setbeam in Privacy & Security, then retry. Access is only needed for the input you chose." }
        if connectingToPicture { return "Opening the selected source on this Mac." }
        guard let setup else { return "Connect a receiver, camera, or computer output. You can also try a clearly labeled sample." }
        if setup.kind == .macWindow {
            if windowPresence == .closed { return "Setbeam never switches to another window or the whole display. Choose the window again in Choose a source." }
            return "Show \(setup.deviceName ?? "the application")'s window on this Mac. A minimized, hidden, or closed window pauses the picture; Setbeam resumes only that same window. This source has no sound."
        }
        if setup.kind == .macScreen { return "Reconnect the selected display. Setbeam keeps trying that same display. This source has no sound; Setbeam windows are excluded." }
        if setup.kind == .capture { return "Connect the selected device to this Mac. If it is connected, check the HDMI or SDI cable and turn on the source. Setbeam keeps trying this same input." }
        if setup.kind == .network {
            if setup.networkProfile == .pyroH {
                return "Turn on the Pyro H and its computer or camera output. Rejoin the transmitter's Wi-Fi and close HollyView or other direct viewers. Setbeam keeps retrying the selected stream. Choose Enter Stream Address if its address has changed."
            }
            return setup.sourceWiFi.isEmpty ? "Turn on the source and check that this Mac is on its network. Your picture will return here automatically." : "Turn on the source and join \(setup.sourceWiFi) in Wi-Fi Settings. Your picture will return here automatically."
        }
        if setup.kind == .incoming { return "In Accsoon SEE, open the CineView Master 4K picture and start Push Stream using Setbeam's setup details. Setbeam confirms the picture here when it arrives." }
        if setup.kind == .accsoon {
            if let wirelessDiscoveryProblem { return wirelessDiscoveryProblem }
            if let device = wirelessDevices.first(where: { $0.id == setup.wirelessUID }), !device.videoAvailable {
                return "The transmitter is connected. Wake the computer or camera feeding its HDMI or SDI input, or check that cable. Your picture will appear here when the source returns."
            }
            return "Turn on the transmitter and its camera or computer output. Join \(setup.sourceWiFi.isEmpty ? "the transmitter's Wi-Fi" : setup.sourceWiFi). Setbeam will restore this same unit automatically."
        }
        return "Setbeam is restoring the selected picture. Sharing stays under your control."
    }
    var frameAgeLabel: String {
        guard let lastFrameAt else { return "Waiting for the first picture" }
        return "Last picture \(max(1, Int(Date().timeIntervalSince(lastFrameAt)))) seconds ago"
    }

    func launch() {
        guard !launched else { return }; launched = true
        let args = CommandLine.arguments
        let logDirectory = args.firstIndex(of: "--log-directory").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        SessionLog.shared.configure(directory: logDirectory ?? SessionLog.defaultDirectory)
        let info = Bundle.main.infoDictionary
        SessionLog.shared.record("app.launch", ["version": info?["CFBundleShortVersionString"] as? String ?? "development",
            "build": info?["CFBundleVersion"] as? String ?? "development", "integration": integration])
        localPlayer.muted = localMuted
        localPlayer.onPlaybackState = nativePlaybackState
        audiencePlayer.onPlaybackState = { [weak self] playing, _ in self?.audiencePreviewPlaying = playing }
        localPlayer.onSoundUnavailable = { [weak self] message in self?.localMuted = true; self?.error = message }
        gateway.setAccess(approval: viewerApproval, pointers: sharedPointers)
        // Keep gateway order on the main queue; Hold, Stop, and revisions arrive as an empty list.
        gateway.onPointers = { [weak presence = pointerPresence] pointers in
            DispatchQueue.main.async { presence?.show(pointers) }
        }
        syncViewerAccess()
        runtimeUpdates = Task { [weak self, runtime] in
            for await snapshot in await runtime.updates() {
                guard !Task.isCancelled, let self, !self.shuttingDown else { return }
                self.apply(snapshot)
                self.localPlayer.checkHealth(sourceAvailable: snapshot.sourceAvailable)
                self.audiencePlayer.checkHealth(sourceAvailable: snapshot.session.sharing && snapshot.audienceAvailable)
                self.publishGatewayState()
                self.confirmSetupIfReady()
            }
        }
        refreshCaptureDevices()
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setPointersOnSourceDisplay(false) }
        }
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setPointersOnSourceDisplay(false) }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshCaptureDevices(); self?.localPlayer.retry(); self?.audiencePlayer.retry() }
        })
        if integration { connect(SourceSetup(kind: .sample, name: "Sample feed"), remember: false) }
        else if let saved = provenSetup { restore(saved) }
        else if showsPermissionsAtLaunch { defaults.set(true, forKey: "permissionsIntroduced"); sheet = .permissions }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, !self.shuttingDown else { return }
                tick += 1
                self.observeSelectedWindow()
                self.refreshChat()
                self.updateSourceDisplayPointers()
                self.updateDisplayWake()
                self.rejoinTransmitterIfNeeded()
                if tick % 3 == 0 && !self.busy {
                    self.refreshCaptureDevices(); await self.refreshNetworks()
                    if self.sheet == .connection || self.setup?.kind == .accsoon { await self.refreshWireless() }
                }
                guard self.state.monitoring, !self.busy else { self.writeExperienceState(); continue }
                self.viewers = self.gateway.viewers
                if self.gateway.desiredReaders != self.appliedReaders || self.viewerApproval != self.appliedApproval { self.syncViewerAccess() }
                self.recordViewerChanges()
                self.confirmSetupIfReady()
                self.writeExperienceState()
            }
        }
    }
    func apply(_ snapshot: RuntimeSnapshot) {
        if currentRuntime?.audienceRevision != snapshot.audienceRevision || snapshot.session.audience != .live { clearChatAttachment() }
        currentRuntime = snapshot; preview = snapshot.session.monitoring ? snapshot.preview : nil
        sourceHasAudio = snapshot.sourceHasAudio; audienceHasAudio = snapshot.audienceHasAudio
        state = snapshot.session
        audienceControl.observe(snapshot.session)
        lastRuntimeProblem = snapshot.message ?? ""
        outgoingTransition.observeReady(outgoingReady)
        if let frame = snapshot.lastFrameAt { lastFrameAt = frame }
        updateSourceDisplayPointers()
    }
    /// Follows the selected window's presence and title. A briefly hidden window resumes on its running
    /// capture; if the picture has not returned three seconds after the window did, retry without waiting
    /// for the runtime's backoff. The retry still requires that exact window.
    private func observeSelectedWindow() {
        guard setup?.kind == .macWindow, let identity = setup?.window else { windowPresence = nil; windowTitle = nil; windowReturn = WindowReturnRetry(); return }
        let status = MacWindowLocator.status(of: identity)
        let retry = windowReturn.observe(status.presence, previous: windowPresence, lastFrameAt: lastFrameAt)
        windowPresence = status.presence
        if let title = status.title { windowTitle = title }
        if retry, state.monitoring, !busy, !permissionDenied {
            SessionLog.shared.record("window.returned")
            Task { await runtime.retrySource() }
        }
    }
    func connectWindow(_ window: MacWindow) {
        var candidate = SourceSetup(kind: .macWindow, name: window.sourceName, deviceName: window.applicationName)
        candidate.window = window.identity
        connect(candidate)
    }
    @discardableResult func present(_ next: AppSheet, prepare: () -> Void = {}) -> Bool {
        if sheet == next { monitorWindow?.makeKeyAndOrderFront(nil); return true }
        guard !protectsSourceDraft else { monitorWindow?.makeKeyAndOrderFront(nil); return false }
        prepare()
        sheet = next
        monitorWindow?.makeKeyAndOrderFront(nil)
        return true
    }
    func showJoinCodes() { present(.join) { loadViewingWiFi() } }
    func openSources() {
        guard present(.connection) else { return }
        refreshCaptureDevices(); Task { await refreshWireless() }
    }
    /// The source kinds chosen in Permissions, so reopening it explains the same access.
    var permissionUses: PermissionUses {
        get {
            let saved = defaults.dictionary(forKey: "permissionUses") as? [String: Bool] ?? [:]
            return PermissionUses(screen: saved["screen"] ?? false, camera: saved["camera"] ?? false,
                                  transmitter: saved["transmitter"] ?? false, sharing: saved["sharing"] ?? true)
        }
        set {
            guard !integration else { return }
            defaults.set(["screen": newValue.screen, "camera": newValue.camera, "transmitter": newValue.transmitter, "sharing": newValue.sharing], forKey: "permissionUses")
        }
    }
    /// First run explains access before any source asks for it. A Mac with a working setup has already been through it.
    var showsPermissionsAtLaunch: Bool { !integration && provenSetup == nil && !defaults.bool(forKey: "permissionsIntroduced") }
    func refreshWireless() async {
        do { wirelessDevices = try await runtime.discoverWireless(); wirelessDiscoveryProblem = nil }
        catch { wirelessDiscoveryProblem = error.localizedDescription }
    }
    func stopWirelessScan() {
        guard setup?.kind != .accsoon else { return }
        Task { await runtime.stopWirelessDiscovery() }
    }
    func connectWireless(_ device: AccsoonDevice) {
        var candidate = SourceSetup(kind: .accsoon, name: "CineView Master 4K", deviceName: device.name, sourceWiFi: device.wifiName)
        candidate.wirelessUID = device.id; connect(candidate)
    }
    var canDiscoverPyroH: Bool { !(state.monitoring && setup?.kind == .network) }
    func connectPyroH(_ device: PyroHSource) {
        var candidate = device.setup
        if device.network.interface == "lo0" { candidate.name = "Pyro H test stream" }
        connect(candidate, address: device.address)
    }
    func openSourceDetails() {
        present(.sourceDetails) {
            refreshCaptureDevices()
            if !integration, setup?.kind == .accsoon, let ssid = setup?.sourceWiFi, !ssid.isEmpty {
                transmitterWiFiPassword = SecureSettings.read("source-wifi-\(ssid)") ?? ""
                transmitterOpenNetwork = defaults.bool(forKey: "sourceWiFiOpen-\(ssid)")
            }
        }
    }
    func openNetworkSource() {
        present(.networkSource) {
            savedNetworkURL = Self.networkSourcePrefill(kind: setup?.kind, activeAddress: activeNetworkURL)
                ?? provenSetup.flatMap { $0.kind == .network ? SecureSettings.read($0.credentialAccount) : nil } ?? ""
        }
    }
    nonisolated static func networkSourcePrefill(kind: InputKind?, activeAddress: String?) -> String? {
        kind == .network ? activeAddress : nil
    }
    func showSharing(_ section: SharingSection) {
        if sheet != nil || monitorWindow?.isVisible == false { sharingInWindow = true }
        if section == .invite { loadViewingWiFi() }
        if section == .options { prepareSharingDraft(); sharingOptionsNetworkRequested = false }
        lastSharingSection = section
        sharingSection = section
        sharingFocusRequest &+= 1
        if sharingInWindow { sharingWindow?.makeKeyAndOrderFront(nil) }
    }
    func showSharingStatus() { showSharing(sharingSection ?? lastSharingSection) }
    func showViewingNetwork() { showSharing(.options); sharingOptionsNetworkRequested = true; sharingOptionsTarget &+= 1 }
    func prepareSharingDraft() {
        if sharingDraft == nil { sharingDraft = SharingOptionsDraft(address: localAddressLabel, network: networkChoice, quality: audienceQuality, frameRate: audienceFrameRate) }
    }
    func selectSettings(_ section: SettingsSection) {
        settingsSection = section
        if !integration { defaults.set(section.rawValue, forKey: "settingsSection") }
    }
    func closeSharing() { sharingSection = nil; sharingInWindow = false }
    func showSharingInWindow() { sharingInWindow = true; sharingFocusRequest &+= 1; sharingWindow?.makeKeyAndOrderFront(nil) }
    func dockSharing() { guard sharingCanDock else { return }; sharingInWindow = false; sharingFocusRequest &+= 1 }
    func restore(_ saved: SourceSetup) {
        // A window identity lasts only as long as its owner process. Restore that exact window or ask.
        if saved.kind == .macWindow, (saved.window.map { MacWindowLocator.status(of: $0).presence } ?? .closed) == .closed {
            error = "The saved window is no longer open. Choose a window again in Choose a source."
            if !state.monitoring { setup = saved; windowPresence = .closed }
            return
        }
        let address = saved.kind == .network || saved.kind == .incoming ? SecureSettings.read(saved.credentialAccount) : nil
        if (saved.kind == .network || saved.kind == .incoming) && address == nil {
            error = "The saved address is unavailable. Reconnect this source using Enter Stream Address."
            if !state.monitoring { setup = saved }
            return
        }
        connect(saved, address: address)
    }
    func connect(_ candidate: SourceSetup, address: String? = nil, remember: Bool = true) {
        guard !busy, !shuttingDown else { return }
        let chosen: VideoSource
        do { chosen = try candidate.source(address: address).validated() }
        catch { self.error = error.localizedDescription; return }
        busy = true; error = nil; permissionDenied = false; screenPermissionDenied = false; pendingScreenPermission = nil; sheet = nil
        let discovery = sourceBrowser.stop()
        rejoinAttempt?.permit.revoke()
        Task {
            await discovery?.value
            guard !shuttingDown else { busy = false; return }
            if candidate.kind.isMacCapture && !MacScreenCapture.requestPermission() {
                pendingScreenPermission = (candidate, remember)
                screenPermissionDenied = true; permissionDenied = true; error = "Allow Setbeam in Screen Recording, then retry."
                busy = false; setup = state.monitoring ? setup : candidate; return
            }
            if candidate.kind == .capture {
                let videoAllowed = await Self.requestPermission(.video)
                let audioAllowed = candidate.audioID == nil ? true : await Self.requestPermission(.audio)
                guard videoAllowed && audioAllowed else { permissionDenied = true; error = "Allow access to the selected video or sound input in Privacy & Security, then retry."; busy = false; setup = state.monitoring ? setup : candidate; return }
            }
            guard !shuttingDown else { return }
            let changingSource = state.monitoring
            let originalSelection = (setup: setup, source: source, address: activeNetworkURL, remember: rememberSetup, confirmed: setupConfirmed)
            if localReady, let setup {
                previousSource = (setup, activeNetworkURL, rememberSetup)
            }
            if state.sharing {
                outgoingTransition.begin(.hold)
                audienceControl.begin(.hold)
                gateway.setChatFramePermission(false); clearChatAttachment(); updateSourceDisplayPointers()
            }
            preparingConnection = true
            defer { preparingConnection = false }
            localPlayer.stop(); audiencePlayer.stop(); audiencePreviewPlaying = false
            if !changingSource {
                gateway.stop(); gatewayPort = nil; viewerURL = nil; viewers = []; sharingPower.hold(false)
                retireLocalAddress()
                currentRuntime = nil
            }
            preview = nil; nativePreviewPlaying = false; sourceHasAudio = false; audienceHasAudio = false; testSoundConfirmed = false
            readiness = SetupReadiness(); setupConfirmed = false; lastFrameAt = nil; connectedAt = Date()
            rememberFailed = false
            setup = candidate; activeNetworkURL = address; rememberSetup = remember
            windowPresence = nil; windowTitle = nil
            source = chosen
            do {
                let inputAddress = candidate.kind == .incoming ? networks.first(where: \.wireless)?.address ?? "127.0.0.1" : nil
                let snapshot: RuntimeSnapshot
                if changingSource { snapshot = try await runtime.replaceSource(chosen, inputAddress: inputAddress) }
                else {
                    await runtime.setVideoSettings(quality: audienceQuality, frameRate: audienceFrameRate, screenFrameRate: screenFrameRate)
                    snapshot = try await runtime.prepare(source: chosen, viewerAddress: viewerAddress, inputAddress: inputAddress)
                }
                guard !shuttingDown else { return }
                apply(snapshot)
                if state.sharing { audienceControl.complete(snapshot.session) }
                publishGatewayState()
                if let destination = await runtime.incomingDestination() { incomingServer = destination.server; incomingStreamKey = destination.streamKey }
                let localURL = await runtime.localRTSP()
                let audienceURL = state.sharing ? await runtime.localRTSP("live") : nil
                guard !shuttingDown else { busy = false; return }
                try localPlayer.start(url: localURL)
                if let audienceURL { try audiencePlayer.start(url: audienceURL) }
                if restoreFloating { floating.show() }
                busy = false
                if candidate.kind == .incoming && candidate.confirmedAt == nil { present(.incoming) }
                if integration && !changingSource { await startSharingNow(); writeIntegrationSession() }
            } catch {
                guard !shuttingDown else { busy = false; return }
                localPlayer.stop(); busy = false
                if !changingSource { await runtime.shutdown(); apply(await runtime.snapshot()) }
                else {
                    let actual = await runtime.snapshot()
                    if actual.source != chosen {
                        setup = originalSelection.setup; source = originalSelection.source
                        activeNetworkURL = originalSelection.address; rememberSetup = originalSelection.remember
                        setupConfirmed = originalSelection.confirmed
                    }
                    apply(actual)
                    if actual.session.sharing {
                        if actual.session.holding && actual.session.audienceAvailable { audienceControl.complete(actual.session) }
                        else { audienceControl.fail(.hold, session: actual.session); outgoingTransition.reset() }
                    }
                    if actual.session.monitoring {
                        let localURL = await runtime.localRTSP()
                        guard !shuttingDown else { return }
                        try? localPlayer.start(url: localURL)
                    }
                }
                self.error = state.sharing
                    ? (audiencePresentation.confirmedHold ? "The new input could not start. Viewers remain on Hold. Retry or return to the previous source."
                       : "The new input could not start and holding output is not confirmed. Retry Hold or stop sharing.")
                    : "The connection could not start. Retry, or return to the previous source."
                lastRuntimeProblem = Redaction.text(error.localizedDescription)
                if !state.monitoring { preview = nil }
                if state.sharing {
                    let audienceURL = await runtime.localRTSP("live")
                    guard !shuttingDown else { return }
                    try? audiencePlayer.start(url: audienceURL)
                }
                publishGatewayState()
            }
        }
    }
    func returnToPreviousSource() {
        guard !protectsSourceDraft else { monitorWindow?.makeKeyAndOrderFront(nil); return }
        guard !busy, let previousSource else { return }
        connect(previousSource.setup, address: previousSource.address, remember: previousSource.remember)
    }
    private static func requestPermission(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }
    private func confirmSetupIfReady() {
        guard !setupConfirmed, !rememberFailed, readiness.observe(sourceFresh: state.sourceAvailable, previewFresh: nativePreviewPlaying), let setup else { return }
        guard rememberSetup, !integration else { setupConfirmed = true; return }
        do {
            if setup.kind == .network || setup.kind == .incoming, let activeNetworkURL { try SecureSettings.store(activeNetworkURL, account: setup.credentialAccount) }
            try store.confirm(setup); provenSetup = store.setup; setupConfirmed = true
        } catch { rememberFailed = true; self.error = "Your picture is working, but Setbeam could not remember this connection. Retry saving in Source Details." }
    }
    func retry() {
        guard !busy else { return }; error = nil
        if let pending = pendingScreenPermission {
            connect(pending.setup, remember: pending.remember)
            return
        }
        if state.monitoring && !permissionDenied {
            busy = true
            connectedAt = Date()
            Task {
                await runtime.retrySource()
                guard !shuttingDown else { return }
                localPlayer.retry(); apply(await runtime.snapshot()); busy = false
            }
            return
        }
        permissionDenied = false
        if let setup { connect(setup, address: activeNetworkURL ?? SecureSettings.read(setup.credentialAccount), remember: rememberSetup) }
        else { openSources() }
    }
    func forgetSetup() {
        let current = provenSetup.map { $0.id == setup?.id } ?? false
        if let provenSetup { SecureSettings.remove(provenSetup.credentialAccount) }
        store.forget(); provenSetup = nil
        if current { rememberSetup = false }
    }
    func prepareAccsoon() {
        let saved = provenSetup?.kind == .incoming ? provenSetup : nil
        let candidate = saved ?? SourceSetup(kind: .incoming, name: "CineView Master 4K", deviceName: "Accsoon CineView Master 4K")
        let key = saved.flatMap { SecureSettings.read($0.credentialAccount) } ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        connect(candidate, address: key)
    }
    func rememberSourceWiFi(_ value: String) {
        guard var setup else { return }; setup.sourceWiFi = value; self.setup = setup
        setupConfirmed = false; readiness = SetupReadiness()
    }
    func renameSource(_ name: String, remember: Bool) {
        guard var setup else { return }
        if !name.isEmpty && setup.kind != .sample { setup.name = name; self.setup = setup }
        if !remember && provenSetup?.id == setup.id { forgetSetup() }
        rememberSetup = remember; setupConfirmed = false; readiness = SetupReadiness()
        rememberFailed = false
    }
    func startSharing() { guard !busy else { return }; Task { await startSharingNow() } }
    private func startSharingNow() async {
        guard !shuttingDown, state.monitoring, !state.sharing, (localReady || integration) else { return }
        // Viewers may come to depend on this Mac's Wi-Fi; a pending rejoin must not switch it.
        rejoinAttempt?.permit.revoke()
        busy = true; error = nil
        outgoingTransition.begin(.startSharing)
        do {
            await refreshNetworks()
            guard !shuttingDown else { busy = false; return }
            apply(try await runtime.startSharing())
            appliedReaders = []; viewingLink += 1
            guard !shuttingDown else { busy = false; return }
            outgoingTransition.observeReady(outgoingReady)
            publishGatewayState()
            if gatewayPort == nil { gatewayPort = try await gateway.start(address: viewerAddress) }
            guard !shuttingDown else { busy = false; return }
            if let port = gatewayPort, let snapshot = currentRuntime { viewerURL = URL(string: "http://\(viewerAddress):\(port)/s/\(snapshot.guestToken)/") }
            updateLocalAddress()
            observeJoinRequests()
            let audienceURL = await runtime.localRTSP("live")
            guard !shuttingDown else { busy = false; return }
            try audiencePlayer.start(url: audienceURL)
            networkChanged = false; sharingPower.hold(true)
        } catch {
            guard !shuttingDown else { busy = false; return }
            gateway.stop(); gatewayPort = nil; viewerURL = nil; retireLocalAddress(); await runtime.stopSharing(); apply(await runtime.snapshot()); outgoingTransition.reset(); audiencePlayer.stop(); self.error = "Sharing could not start. Check the viewing network and try again."; lastRuntimeProblem = Redaction.text(error.localizedDescription)
        }
        busy = false; writeIntegrationSession()
    }
    func toggleHold() { performAudienceAction() }
    func setAudienceHold(_ value: Bool) {
        guard state.sharing, !busy else { return }; busy = true
        guard value || localReady else { busy = false; error = "Wait for a fresh local picture before resuming sharing."; return }
        audienceControl.begin(AudienceTarget(holding: value))
        gateway.setChatFramePermission(false); clearChatAttachment()
        updateSourceDisplayPointers()
        outgoingTransition.begin(value ? .hold : .resume)
        testSoundConfirmed = false
        writeExperienceState()
        Task {
            do {
                try await runtime.setHold(value)
                let snapshot = await runtime.snapshot()
                let audienceURL = await runtime.localRTSP("live")
                guard !shuttingDown else { busy = false; return }
                apply(snapshot)
                audienceControl.complete(snapshot.session)
                audiencePlayer.stop(); audiencePreviewPlaying = false
                try? audiencePlayer.start(url: audienceURL)
            }
            catch {
                guard !shuttingDown else { busy = false; return }
                apply(await runtime.snapshot()); audienceControl.fail(AudienceTarget(holding: value), session: state); outgoingTransition.reset(); self.error = value ? "Hold did not finish. Retry Hold or stop sharing." : "Resume did not finish. Retry Resume, Hold, or stop sharing."; lastRuntimeProblem = Redaction.text(error.localizedDescription)
            }
            publishGatewayState()
            busy = false; writeExperienceState()
        }
    }
    func stopSharing() {
        guard !busy else { return }; busy = true; stoppingSharing = true
        gateway.setChatFramePermission(false); clearChatAttachment()
        updateSourceDisplayPointers()
        Task { await endSharing(); stoppingSharing = false; busy = false }
    }
    private func endSharing() async {
        sharingPower.hold(false)
        // The name and short address end with the viewing link. Stop rotates the link, so old links stay expired.
        retireLocalAddress()
        outgoingTransition.reset()
        audiencePlayer.stop(); audiencePreviewPlaying = false; audienceHasAudio = false; testSoundConfirmed = false
        await runtime.stopSharing()
        appliedReaders = []; pointerPresence.clear(); pointersOnThisMac = false
        apply(await runtime.snapshot()); publishGatewayState()
        viewers = gateway.viewers
    }
    private func publishGatewayState() {
        guard let snapshot = currentRuntime else { return }
        gateway.update(ViewerSession(token: snapshot.guestToken, title: title, sample: source == .sample, state: state.audience,
            playback: snapshot.audience, revision: snapshot.audienceRevision, wifiSSID: wifiSSID))
        gateway.setChatFramePermission(canCaptureChatFrame)
    }
    var canCaptureChatFrame: Bool { state.audience == .live && outgoingReady && audiencePreviewPlaying && audienceControl.pending == nil && !busy && !shuttingDown }
    func refreshChat() {
        let messages = state.sharing ? gateway.chatMessages : []
        if messages != chatMessages {
            let imageIDs = Set(messages.filter(\.hasFrame).map(\.id))
            chatImages = chatImages.filter { imageIDs.contains($0.key) }
            for id in imageIDs where chatImages[id] == nil { if let data = gateway.chatFrame(id: id), let image = NSImage(data: data) { chatImages[id] = image } }
            chatMessages = messages
            if let id = chatReplyTo, !messages.contains(where: { $0.id == id }) { chatReplyTo = nil }
        }
        if sharingSection == .chat, NSApp.isActive, (sharingInWindow ? sharingWindow : monitorWindow)?.isKeyWindow == true { markChatRead() }
        if !state.sharing { chatText = ""; chatReplyTo = nil; chatReadThrough = 0; clearChatAttachment() }
    }
    func chatFrame(id: Int) -> Data? { gateway.chatFrame(id: id) }
    func clearChatAttachment() { chatCaptureGeneration = UUID(); chatCapturing = false; chatAttachment = nil; chatAttachmentRevision = nil; chatAttachmentLink = nil }
    func captureChatFrame() {
        guard !chatCapturing, canCaptureChatFrame, let picture = audiencePlayer.picture, let snapshot = currentRuntime else { return }
        let generation = UUID(), link = viewingLink, revision = snapshot.audienceRevision
        chatCaptureGeneration = generation; chatCapturing = true
        Task {
            let data = await Task.detached(priority: .userInitiated) { ChatFrameEncoder.encode(picture) }.value
            guard chatCaptureGeneration == generation else { return }
            chatCapturing = false
            guard link == viewingLink, currentRuntime?.audienceRevision == revision, canCaptureChatFrame else { return }
            guard let data else { chatProblem = "The outgoing frame could not be prepared. Try another frame."; return }
            chatAttachment = data; chatAttachmentRevision = revision; chatAttachmentLink = link; chatProblem = nil
        }
    }
    func sendChat() {
        guard state.sharing, let snapshot = currentRuntime else { return }
        do {
            if chatAttachment != nil, chatAttachmentLink != viewingLink || chatAttachmentRevision != snapshot.audienceRevision || !canCaptureChatFrame { clearChatAttachment(); throw SetbeamError.unavailable("The feed changed. Capture a new frame before sending.") }
            try gateway.postChat(text: chatText, replyTo: chatReplyTo, frame: chatAttachment, revision: snapshot.audienceRevision,
                                 token: snapshot.guestToken, name: chatOperatorName, color: chatOperatorColor, requestID: UUID().uuidString)
            chatText = ""; chatReplyTo = nil; clearChatAttachment(); chatProblem = nil; refreshChat()
        } catch { chatProblem = error.localizedDescription }
    }
    func likeChat(_ message: ChatMessage) {
        guard let snapshot = currentRuntime else { return }
        do { try gateway.likeChat(id: message.id, liked: !message.liked, token: snapshot.guestToken); chatProblem = nil; refreshChat() }
        catch { chatProblem = error.localizedDescription }
    }
    func reactChat(_ message: ChatMessage, reaction: ChatReaction) {
        guard let snapshot = currentRuntime else { return }
        let selected = message.reactions.contains { $0.reaction == reaction && $0.selected }
        do { try gateway.reactChat(id: message.id, reaction: selected ? nil : reaction, token: snapshot.guestToken); chatProblem = nil; refreshChat() }
        catch { chatProblem = error.localizedDescription }
    }
    func removeChat(_ message: ChatMessage) {
        guard let snapshot = currentRuntime else { return }
        gateway.removeChat(id: message.id, token: snapshot.guestToken); refreshChat()
    }
    func refreshNetworks() async {
        guard !shuttingDown else { return }
        let available = NetworkAddress.available(); networks = available
        if setup?.kind == .incoming, state.monitoring {
            try? await runtime.updateInputAddress(available.first(where: \.wireless)?.address ?? "127.0.0.1")
            if let destination = await runtime.incomingDestination() { incomingServer = destination.server; incomingStreamKey = destination.streamKey }
        }
        let selected: NetworkAddress?
        if state.sharing {
            selected = NetworkAddress.restoring(NetworkAddress(interface: viewerInterface, address: viewerAddress), in: available)
        } else {
            selected = networkChoice == "automatic" ? NetworkAddress.preferred(in: available) : available.first { $0.interface == networkChoice }
        }
        let address = selected?.address ?? "127.0.0.1"
        viewerInterface = selected?.interface ?? "lo0"
        guard address != viewerAddress || viewerNetworkNeedsUpdate else { return }
        viewerNetworkNeedsUpdate = true
        SessionLog.shared.record("network.viewing", ["interface": viewerInterface, "sharing": state.sharing])
        viewerAddress = address
        do {
            try await runtime.updateViewerAddress(address)
            guard !shuttingDown else { return }
            if state.monitoring { apply(await runtime.snapshot()) }
            if state.sharing, let port = gatewayPort, let snapshot = currentRuntime {
                // Preserve audience intent, Hold, credential, and port through network recovery.
                publishGatewayState()
                viewerURL = URL(string: "http://\(address):\(port)/s/\(snapshot.guestToken)/")
                networkChanged = true
                updateLocalAddress()
                guard !shuttingDown else { return }
                _ = try await gateway.start(address: address, port: port)
            } else { gateway.stop(); gatewayPort = nil; viewerURL = nil; viewers = []; retireLocalAddress() }
            viewerNetworkNeedsUpdate = false
        }
        catch { lastRuntimeProblem = Redaction.text(error.localizedDescription) }
    }
    @discardableResult func saveViewingSettings(network: String, ssid: String, password: String) -> Bool {
        let secret = ssid.isEmpty ? "" : password
        if !integration && !ssid.isEmpty {
            do { if secret.isEmpty { SecureSettings.remove("viewing-wifi-\(ssid)") } else { try SecureSettings.store(secret, account: "viewing-wifi-\(ssid)") } }
            catch { self.error = "The viewing Wi-Fi password could not be saved."; return false }
        }
        wifiSSID = ssid; wifiPassword = secret; loadedWiFiSSID = ssid
        viewingWiFiPasswordAvailable = true
        if error == "The viewing Wi-Fi password could not be saved." { error = nil }
        if !integration { defaults.set(ssid, forKey: "wifiSSID"); defaults.set(!secret.isEmpty, forKey: "viewingWiFiProtected-\(ssid)") }
        publishGatewayState()
        changeViewingNetwork(network)
        return true
    }
    func changeViewingNetwork(_ network: String) {
        guard network != networkChoice else { return }
        networkChoice = network
        if !integration { defaults.set(network, forKey: "viewerInterface") }
        Task { if state.sharing { await endSharing(); networkChanged = true }; await refreshNetworks() }
    }
    func setAudienceQuality(_ quality: AudienceQuality) {
        setVideoSettings(quality: quality, frameRate: audienceFrameRate, screenRate: screenFrameRate)
    }
    func setVideoSettings(quality: AudienceQuality, frameRate: VideoFrameRate, screenRate: VideoFrameRate) {
        guard quality != audienceQuality || frameRate != audienceFrameRate || screenRate != screenFrameRate else { return }
        audienceQuality = quality; audienceFrameRate = frameRate; screenFrameRate = screenRate
        if !integration {
            defaults.set(quality.rawValue, forKey: "audienceQuality")
            defaults.set(frameRate.rawValue, forKey: "audienceFrameRate")
            defaults.set(screenRate.rawValue, forKey: "screenFrameRate")
        }
        Task { await runtime.setVideoSettings(quality: quality, frameRate: frameRate, screenFrameRate: screenRate) }
    }
    /// Opt-in. Joining another Wi-Fi network is never automatic unless the operator enables it here.
    @discardableResult func setTransmitterRejoin(_ enabled: Bool, password: String, openNetwork: Bool = false) -> Bool {
        guard let ssid = setup?.sourceWiFi, !ssid.isEmpty else { return false }
        guard !enabled || !password.isEmpty || openNetwork else {
            rejoinProblem = "Enter the transmitter's Wi-Fi password or choose an open network before enabling automatic rejoin."
            return false
        }
        if !password.isEmpty || openNetwork {
            do { if openNetwork { SecureSettings.remove("source-wifi-\(ssid)") } else { try SecureSettings.store(password, account: "source-wifi-\(ssid)") } }
            catch { rejoinProblem = "The transmitter Wi-Fi password could not be saved."; return false }
            transmitterWiFiPassword = openNetwork ? "" : password
        }
        transmitterRejoin = enabled; transmitterOpenNetwork = openNetwork
        rejoinPolicy = TransmitterRejoinPolicy(); rejoinProblem = nil; rejoinAttempt?.permit.revoke()
        if !integration { defaults.set(enabled, forKey: "transmitterWiFiRejoin"); defaults.set(openNetwork, forKey: "sourceWiFiOpen-\(ssid)") }
        if enabled { transmitterWiFi.requestLocation() }
        if enabled && transmitterWiFi.locationDenied { rejoinProblem = TransmitterWiFiResult.needsLocation.message }
        SessionLog.shared.record("wifi.rejoin.setting", ["enabled": enabled])
        return true
    }
    private func rejoinTransmitterIfNeeded() {
        // Sharing over Wi-Fi depends on the current network; switching it would end viewing.
        let sharingOverWiFi = state.sharing && viewerInterface == transmitterWiFi.interfaceName
        if let attempt = rejoinAttempt, !transmitterRejoin || shuttingDown || sharingOverWiFi || localReady
            || setup?.kind != .accsoon || setup?.sourceWiFi != attempt.ssid { attempt.permit.revoke() }
        guard let setup, setup.kind == .accsoon, !setup.sourceWiFi.isEmpty, !shuttingDown else { return }
        let visible = wirelessDevices.contains { $0.id == setup.wirelessUID }
        guard rejoinPolicy.observe(enabled: transmitterRejoin, transmitterVisible: visible, pictureLive: localReady,
                                   blocked: busy || rejoinInFlight || sharingOverWiFi, now: Date()) else { return }
        let ssid = setup.sourceWiFi
        guard transmitterWiFi.locationAllowed else {
            rejoinProblem = TransmitterWiFiResult.needsLocation.message
            SessionLog.shared.record("wifi.rejoin.result", ["network": ssid, "result": TransmitterWiFiResult.needsLocation.logValue])
            return
        }
        rejoinInFlight = true
        let permit = RejoinPermit(); rejoinAttempt = (permit, ssid)
        SessionLog.shared.record("wifi.rejoin.attempt", ["network": ssid])
        let password = SecureSettings.read("source-wifi-\(ssid)")
        Task {
            let result = await TransmitterWiFi.join(ssid: ssid, password: password, permit: permit)
            rejoinInFlight = false; rejoinAttempt = nil; rejoinProblem = result.message
            SessionLog.shared.record("wifi.rejoin.result", ["network": ssid, "result": result.logValue])
        }
    }
    func togglePiP() { pipVisible ? floating.close() : floating.show() }
    func focusFloatingPreview() { floating.focusForKeyboard() }
    func toggleLocalSound() {
        localMuted.toggle()
        if !integration { defaults.set(localMuted, forKey: "localMuted") }
    }
    func floatingVisibilityChanged(_ visible: Bool) {
        pipVisible = visible
        updateDisplayWake()
        if !integration && !shuttingDown { defaults.set(visible, forKey: "floatingVisible") }
    }
    /// Copies the local-address link when that name is active, otherwise the IP address link.
    func copyLink() {
        guard let url = invitationURL else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
        copiedLink = true; Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copiedLink = false }
    }
    func copyIPLink() {
        guard let viewerURL else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(viewerURL.absoluteString, forType: .string)
        copiedIPLink = true; Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copiedIPLink = false }
    }
    /// The same link at the active `.local` name. The private path and port are unchanged.
    var localViewerURL: URL? {
        guard state.sharing, let label = localAddress.activeLabel, let viewerURL,
              var parts = URLComponents(url: viewerURL, resolvingAgainstBaseURL: false) else { return nil }
        parts.host = LocalAddressName.host(label)
        return parts.url
    }
    var invitationURL: URL? { localViewerURL ?? viewerURL }
    var copyLinkHelp: String {
        guard let host = localViewerURL?.host else { return "Copy the viewing link. \(viewingInstructions)" }
        return "Copy the \(host) viewing link. Join codes use the IP address."
    }
    func setLocalAddress(enabled: Bool, label: String) {
        guard case .success(let valid) = LocalAddressName.validated(label) else { return }
        guard enabled != localAddressEnabled || valid != localAddressLabel else { return }
        localAddressEnabled = enabled; localAddressLabel = valid
        if !integration { defaults.set(enabled, forKey: "localAddressEnabled"); defaults.set(valid, forKey: "localAddressName") }
        SessionLog.shared.record("local.address.setting", ["enabled": enabled])
        updateLocalAddress()
    }
    /// Publishes only while sharing on a network viewers can join, on that viewing interface and address.
    private func updateLocalAddress() {
        defer { updateShortAddress() }
        guard !shuttingDown, state.sharing, gatewayPort != nil, localAddressEnabled, canInviteOtherDevices, viewerInterface != "lo0" else {
            localAddressPublisher.stop(); return
        }
        localAddressPublisher.publish(label: localAddressLabel, scope: .interface(viewerInterface), address: viewerAddress)
    }
    /// Removes the name and stops answering the short address at once. Every caller also ends or rotates
    /// the viewing link, which retires the short-address path, so waiting pages see sharing end, not a refusal.
    private func retireLocalAddress() {
        localAddressPublisher.stop(); shortAddressListener.stop()
    }
    func setShortAddress(enabled: Bool) {
        guard enabled != shortAddressEnabled else { return }
        shortAddressEnabled = enabled
        if !integration { defaults.set(enabled, forKey: "shortAddressEnabled") }
        SessionLog.shared.record("short.address.setting", ["enabled": enabled])
        updateShortAddress()
        viewers = gateway.viewers
    }
    /// Viewers may ask from the short address only while the operator allows it, approval is on, and the
    /// local address is offered for a shared link on a network others can join.
    var shortAddressOpen: Bool {
        shortAddressEnabled && viewerApproval && localAddressEnabled && state.sharing && gatewayPort != nil
            && canInviteOtherDevices && viewerInterface != "lo0" && !shuttingDown
    }
    /// The gateway accepts new short-address requests while it is open. Port 80 answers only once the
    /// name is active, and only connections to the viewing address.
    private func updateShortAddress() {
        let open = shortAddressOpen
        gateway.setShortAddress(open: open)
        guard open, let label = localAddress.activeLabel, let port = gatewayPort, let path = gateway.shortAddressPath else {
            shortAddressListener.stop(); return
        }
        shortAddressListener.serve(.init(address: viewerAddress, hosts: [LocalAddressName.host(label)], port: port, path: path))
    }
    func shortAddressChanged(_ value: ShortAddressListener.State) {
        shortAddress = value
        let detail: [String: Any]
        switch value {
        case .stopped: detail = ["state": "stopped"]
        case .starting: detail = ["state": "starting"]
        case .active: detail = ["state": "active"]
        case .unavailable(let problem): detail = ["state": "unavailable", "problem": problem.rawValue]
        }
        SessionLog.shared.record("short.address", detail)
    }
    /// The typed name that opens the short address now, if any.
    var shortAddressHost: String? {
        guard shortAddressOpen, shortAddress == .active, let label = localAddress.activeLabel else { return nil }
        return LocalAddressName.host(label)
    }
    /// What typing the name does now, in the operator's words. Shown in Settings and invitations.
    var shortAddressStatus: (text: String, attention: Bool) {
        let host = LocalAddressName.host(localAddress.activeLabel ?? localAddressLabel)
        if !shortAddressEnabled { return ("Off. Viewers need the whole link or QR code.", false) }
        if !localAddressEnabled { return ("Turn on Offer a local address to use this.", true) }
        if !viewerApproval { return ("Turn on Ask before viewers join. Until then, typing \(host) doesn't open anything.", true) }
        if !canInviteOtherDevices || viewerInterface == "lo0" { return ("Choose a viewing network to use \(host).", false) }
        if !state.sharing || gatewayPort == nil { return ("Viewers can type \(host) and ask to join while you share.", false) }
        guard localAddress.activeLabel != nil else { return ("Waiting for the local address. Send the link or QR code for now.", false) }
        switch shortAddress {
        case .active: return ("Viewers on this network can type \(host) and ask to join.", false)
        case .stopped, .starting: return ("Starting \(host)…", false)
        case .unavailable(.inUse): return ("Another app is using this Mac's web port (80), so typing \(host) doesn't reach Setbeam. Send the link or QR code. Setbeam keeps trying.", true)
        case .unavailable(.denied): return ("macOS didn't let Setbeam answer on port 80, so typing \(host) doesn't reach Setbeam. Send the link or QR code. Setbeam keeps trying.", true)
        case .unavailable(.unavailable): return ("Typing \(host) isn't available right now. Send the link or QR code. Setbeam keeps trying.", true)
        }
    }
    func localAddressChanged(_ value: LocalAddressState) {
        localAddress = value
        updateShortAddress()
        let detail: [String: Any]
        switch value {
        case .stopped: detail = ["state": "stopped"]
        case .checking(let label): detail = ["state": "checking", "renamed": label != localAddressLabel]
        case .active(let label): detail = ["state": "active", "renamed": label != localAddressLabel]
        case .unavailable(let problem): detail = ["state": "unavailable", "problem": String(describing: problem)]
        }
        SessionLog.shared.record("local.address", detail)
        writeIntegrationSession()
    }
    /// What viewers can use, in the operator's words. Shown in Settings and invitations.
    var localAddressStatus: (text: String, attention: Bool) {
        let requested = LocalAddressName.host(localAddressLabel)
        if !localAddressEnabled { return ("Off. Invitations use the IP address.", false) }
        if !canInviteOtherDevices { return ("Choose a viewing network to use \(requested).", false) }
        switch localAddress {
        case .stopped where state.sharing: return ("Starting \(requested)…", false)
        case .stopped: return ("Viewers can use \(requested) while you share.", false)
        case .checking(let label): return ("Checking \(LocalAddressName.host(label)) on this network…", false)
        case .active(let label) where label == localAddressLabel: return ("Viewers on this network can open \(requested).", false)
        case .active(let label): return ("\(requested) is in use on this network, so viewers use \(LocalAddressName.host(label)).", true)
        case .unavailable(.inUse): return ("\(requested) and its numbered alternatives are in use. Invitations use the IP address.", true)
        case .unavailable(.interface): return ("The viewing network isn't ready for \(requested). Invitations use the IP address.", true)
        case .unavailable(.service): return ("\(requested) isn't available right now. Invitations use the IP address while Setbeam retries.", true)
        }
    }
    func loadViewingWiFi() {
        guard loadedWiFiSSID != wifiSSID || !viewingWiFiPasswordAvailable else { return }
        if !integration && !wifiSSID.isEmpty {
            switch SecureSettings.readOutcome("viewing-wifi-\(wifiSSID)") {
            case .value(let value): wifiPassword = value; viewingWiFiPasswordAvailable = true
            case .missing:
                wifiPassword = ""
                viewingWiFiPasswordAvailable = defaults.object(forKey: "viewingWiFiProtected-\(wifiSSID)") != nil && !defaults.bool(forKey: "viewingWiFiProtected-\(wifiSSID)")
            case .unavailable: wifiPassword = ""; viewingWiFiPasswordAvailable = false
            }
        } else { viewingWiFiPasswordAvailable = true }
        loadedWiFiSSID = wifiSSID
    }
    func openWiFiSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!) }
    func openPrivacySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(screenPermissionDenied || setup?.kind.isMacCapture == true ? "ScreenCapture" : "Camera")")!) }
    func saveFrame() {
        guard localReady else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(title.isEmpty ? "Setbeam" : title)-frame.jpg"; panel.allowedContentTypes = [.jpeg]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { do { try await runtime.saveFrame(to: destination) } catch { self.error = "The frame could not be saved. Wait for the picture and try again." } }
    }
    func refreshCaptureDevices() { captureDevices = CaptureDiscovery.devices(); screenDisplays = MacDisplay.connected() }
    func revealSessionLog() {
        guard let file = SessionLog.shared.currentFile else { return }
        if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        else { NSWorkspace.shared.open(file.deletingLastPathComponent()) }
    }
    func diagnostics() {
        Task {
            var data = await runtime.diagnosticStatus()
            data["nativePreviewPlaying"] = nativePreviewPlaying; data["nativePreviewProblem"] = nativePreviewProblem.map(Redaction.text) ?? ""
            data["lastRuntimeProblem"] = Redaction.text(lastRuntimeProblem); data["setupConfirmed"] = setupConfirmed
            data["connectionStage"] = connectionStage?.rawValue ?? ""
            data["localAddress"] = localAddressStatus.text
            data["shortAddress"] = shortAddressStatus.text
            guard let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]), let text = String(data: encoded, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); diagnosticCopied = true
        }
    }
    func nativePlaybackState(_ playing: Bool, _ problem: String?) {
        if nativePreviewPlaying != playing {
            nativePreviewPlaying = playing
            SessionLog.shared.record(playing ? "preview.playing" : "preview.stopped", ["problem": problem ?? ""])
            updateDisplayWake()
        }
        nativePreviewProblem = problem
    }
    /// A visible live picture keeps the display awake; a missing picture or hidden monitor lets it sleep.
    private func updateDisplayWake() {
        let previewVisible = pipVisible || (monitorWindow.map {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        } ?? false)
        let wanted = !shuttingDown && localReady && previewVisible
        if displayPower.hold(wanted) { SessionLog.shared.record(wanted ? "display.awake.on" : "display.awake.off") }
    }
    private func recordViewerChanges() {
        let current = (opened: openedViewers, playing: verifiedViewers)
        guard current != loggedViewers else { return }
        loggedViewers = current
        SessionLog.shared.record("viewers", ["opened": current.opened, "playing": current.playing, "otherDevices": otherDeviceViewers])
    }
    func shutdown() async {
        shuttingDown = true; pollTask?.cancel(); runtimeUpdates?.cancel(); sourceBrowser.stop(); observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        floating.close(); sourceDisplayPointers.close(); joinCodeWindow.close(); joinRequests.close(); localPlayer.stop(); audiencePlayer.stop(); gateway.stop(); retireLocalAddress(); sharingPower.hold(false); displayPower.hold(false)
        SessionLog.shared.record("app.quit", ["sharing": state.sharing])
        await runtime.shutdown(); apply(await runtime.snapshot())
    }
    private func writeIntegrationSession() {
        guard let viewerURL else { return }
        writeFile(option: "--session-file", value: ["viewerURL": viewerURL.absoluteString, "localURL": localViewerURL?.absoluteString ?? "",
            "pid": ProcessInfo.processInfo.processIdentifier])
    }
    private func writeExperienceState() {
        guard CommandLine.arguments.contains("--experience-file") else { return }
        writeFile(option: "--experience-file", value: ["monitoring": state.monitoring, "sharing": state.sharing, "holding": state.holding,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "fullKeyboardAccess": NSApp.isFullKeyboardAccessEnabled,
            "pointersOnSourceDisplay": pointersOnSourceDisplay, "sourcePointerWindow": sourceDisplayPointers.windowNumber ?? 0,
            "chatCount": chatMessages.count, "chatCapturing": chatCapturing,
            "sourceAvailable": state.sourceAvailable, "nativePreviewPlaying": nativePreviewPlaying, "busy": busy, "canShare": canShare, "setupConfirmed": setupConfirmed,
            "sourceName": sourceLabel, "kind": setup?.kind.rawValue ?? "none", "savedSetupID": provenSetup?.id.uuidString ?? "",
            "floatingVisible": pipVisible, "floatingKey": floating.keyboardActive, "floatingWash": floatingPresentation.washed, "floatingControl": String(describing: floatingPresentation.center), "audienceControlPending": audienceControl.pending.map { $0.holding ? "hold" : "resume" } ?? "", "localMuted": localMuted, "viewersOpened": openedViewers, "viewersPlaying": verifiedViewers,
            "status": statusLabel, "audience": state.audience.rawValue, "connectionStage": connectionStage?.rawValue ?? "",
            "viewerFPS": audienceFrameRate.rawValue, "screenFPS": screenFrameRate.rawValue,
            "audiencePreviewPlaying": audiencePreviewPlaying, "sourceHasAudio": sourceHasAudio, "audienceHasAudio": audienceHasAudio,
            "otherDeviceViewers": otherDeviceViewers, "setupCheckPassed": setupCheck.passed, "previousSource": previousSourceName ?? "",
            "viewerApproval": viewerApproval, "sharedPointers": sharedPointers, "viewersPending": pendingViewers.count,
            "viewersPointing": pointingViewers, "nativePointers": pointerPresence.items.count, "pointersOnThisMac": pointersOnThisMac,
            "nativePointersShown": showsPointers ? pointerPresence.items.count : 0,
            "localAddressEnabled": localAddressEnabled, "localAddressName": localAddressLabel,
            "localAddressActive": localAddress.activeLabel ?? "", "localAddressStatus": localAddressStatus.text,
            "shortAddressEnabled": shortAddressEnabled, "shortAddressOpen": shortAddressOpen, "shortAddressActive": shortAddressHost ?? "",
            "shortAddressStatus": shortAddressStatus.text, "sharingPanel": sharingSection?.rawValue ?? "",
            "sharingInWindow": sharingInWindow, "sharingFocusRequest": sharingFocusRequest, "sheet": sheet?.rawValue ?? "", "joinRequestCard": joinRequests.isShowing,
            "joinRequestsShown": joinRequests.requests.count, "joinRequestAlerts": joinRequests.alerts])
    }
    private func writeFile(option: String, value: [String: Any]) {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: option), index + 1 < args.count, let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        let destination = URL(fileURLWithPath: args[index+1]); try? data.write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

/// A window that returns from hidden normally resumes on its running capture. Cached availability
/// can stay true for seconds after the last frame, so only a frame received after the return
/// cancels the one-shot retry.
struct WindowReturnRetry {
    private var returnedAt: Date?
    mutating func observe(_ presence: MacWindowPresence, previous: MacWindowPresence?, lastFrameAt: Date?, now: Date = Date()) -> Bool {
        if presence != .visible { returnedAt = nil; return false }
        if previous == .hidden { returnedAt = now }
        guard let returned = returnedAt else { return false }
        if let lastFrameAt, lastFrameAt > returned { returnedAt = nil; return false }
        guard now.timeIntervalSince(returned) >= 3 else { return false }
        returnedAt = nil
        return true
    }
}
