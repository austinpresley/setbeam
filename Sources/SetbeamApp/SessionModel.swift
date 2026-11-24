import Foundation
import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import IOKit.pwr_mgt
import SetbeamCore

enum AppSheet: String, Identifiable { case connection, sourceDetails, networkSource, incoming, join, rename, about, permissions; var id: String { rawValue } }

@MainActor final class SessionModel: ObservableObject {
    @Published var title: String { didSet { if !integration { defaults.set(title, forKey: "sessionTitle") }; publishGatewayState() } }
    @Published private(set) var state: SessionState
    @Published var source: VideoSource = .sample
    @Published var setup: SourceSetup? {
        didSet {
            let identity = TransmitterWiFiIdentity(setup)
            if identity != TransmitterWiFiIdentity(oldValue) {
                rejoinAttempt?.revoke()
                rejoinPolicy = TransmitterRejoinPolicy()
                rejoinProblem = nil
                transmitterWiFiPassword = ""
                loadTransmitterRejoinMode(for: identity)
            }
        }
    }
    @Published var provenSetup: SourceSetup?
    @Published var preview: PlaybackDescriptor?
    @Published private var viewingBinding: ViewingGatewayBinding?
    @Published private var viewingGatewayAttempt: UUID?
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
    /// Advertises `_setbeam._tcp` for native receivers, only while the short address answers.
    private let receiverDiscovery = ReceiverDiscoveryPublisher()
    private var receiverDiscoveryState: ReceiverDiscoveryState = .stopped
    private let receiverDiscoveryID: String
    /// Changes with each viewing link, so a request from an earlier link can never be admitted into this one.
    private(set) var viewingLink = 0
    /// Requests to join, announced once each with a card that keeps this Mac's other apps in front.
    let joinRequests = JoinRequestCenter()
    @Published var viewers: [ViewerActivity] = [] {
        didSet { observeJoinRequests() }
    }
    @Published var busy = false
    @Published private(set) var stoppingSharing = false
    @Published private var startingSharing = false
    private var audienceCommandGeneration: UInt64 = 0
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
    private struct OutgoingPreview: Equatable {
        let generation: UInt64
        let revision: Int

        init?(_ snapshot: RuntimeSnapshot) {
            guard snapshot.session.audience == .live else { return nil }
            generation = snapshot.audienceGeneration
            revision = snapshot.audienceRevision
        }
    }
    private var audiencePreviewTarget: OutgoingPreview?
    private var audiencePreviewStart: Task<Void, Never>?
    @Published private var outgoingTransition = OutgoingTransition()
    @Published private(set) var audienceControl = AudienceControlState()
    @Published var sourceHasAudio = false
    @Published var audienceHasAudio = false
    let sourceBrowser: SourceBrowser
    @Published var pipVisible = false
    @Published var sheet: AppSheet?
    private(set) var sourceCategory: SourceCategory?
    @Published var sourceDetailsDirty = false
    var protectsSourceDraft: Bool { sheet == .sourceDetails && sourceDetailsDirty }
    @Published var sharingSection: SharingSection?
    private var lastSharingSection = SharingSection.viewers
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
    @Published private var viewingWiFiScan: Task<Void, Never>?
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
    /// The LIVE menu holds Hold, Stop and audience options; menus and Go Live can ask it to open.
    @Published var audienceControlsShown = false
    /// Incremented to ask the main window to open Settings at `settingsSection`.
    @Published private(set) var settingsRequest = 0
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
    @Published private(set) var deniedSourceRequest: DeniedSourceRequest?
    var permissionDenied: Bool { deniedSourceRequest != nil }
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
    @Published private(set) var applyingViewerApproval = false
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
    private let integrationSessionFile = IntegrationSessionFile(arguments: CommandLine.arguments)
    private let store: ProvenSetupStore
    private let runtime: MediaRuntime
    private let gateway = ViewerGateway(assets: AppAssets.viewerAssets)
    private var currentRuntime: RuntimeSnapshot?
    private var gatewayPort: UInt16?
    private var viewerInterface: String
    private var viewingNetwork: NetworkAddress?
    private var viewerNetworkNeedsUpdate = false
    private var networkOperation = UUID()
    private var lastReadyViewingAddress: (link: Int, address: String)?
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
    private var rejoinAttempt: RejoinPermit?
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
            let fixtureNetworks: @Sendable () -> [PyroHNetwork] = { [.loopbackFixture] }
            sourceBrowser = SourceBrowser(pyroHNetworks: fixtureNetworks, pyroHPorts: [port])
            runtime = MediaRuntime(paths: AppAssets.runtimePaths, pyroHNetworks: fixtureNetworks)
        } else {
            sourceBrowser = SourceBrowser()
            runtime = MediaRuntime(paths: AppAssets.runtimePaths)
        }
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
        viewingNetwork = selected
        viewerInterface = integration ? "lo0" : selected?.interface ?? "lo0"
        viewerAddress = integration ? "127.0.0.1" : selected?.address ?? "127.0.0.1"
        wifiSSID = defaults.string(forKey: "wifiSSID") ?? ""
        provenSetup = integration ? nil : store.setup
        localMuted = integration ? true : defaults.object(forKey: "localMuted") as? Bool ?? true
        audienceQuality = defaults.string(forKey: "audienceQuality").flatMap(AudienceQuality.init(rawValue:)) ?? .best
        audienceFrameRate = VideoFrameRate(rawValue: defaults.integer(forKey: "audienceFrameRate")) ?? .source
        screenFrameRate = VideoFrameRate(rawValue: defaults.integer(forKey: "screenFrameRate")) ?? .source
        transmitterRejoin = false
        viewerApproval = integration ? false : defaults.bool(forKey: "viewerApproval")
        sharedPointers = integration ? false : defaults.bool(forKey: "sharedPointers")
        localAddressEnabled = defaults.object(forKey: "localAddressEnabled") as? Bool ?? true
        localAddressLabel = defaults.string(forKey: "localAddressName").flatMap { try? LocalAddressName.validated($0).get() } ?? LocalAddressName.defaultLabel
        shortAddressEnabled = defaults.bool(forKey: "shortAddressEnabled")
        if let saved = defaults.string(forKey: "receiverDiscoveryID"), ReceiverAdvertisement.isInstallationID(saved) {
            receiverDiscoveryID = saved
        } else {
            let fresh = ReceiverAdvertisement.newInstallationID()
            receiverDiscoveryID = fresh
            if !integration { defaults.set(fresh, forKey: "receiverDiscoveryID") }
        }
        localAddressPublisher.onChange = { [weak self] state in
            // Deliver in order; the publisher reports each change once on its own queue.
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, self.localAddressPublisher.state == state else { return }
                self.localAddressChanged(state)
            } }
        }
        shortAddressListener.onChange = { [weak self] state in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.shortAddressChanged(state) } }
        }
        receiverDiscovery.onChange = { [weak self] state in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receiverDiscoveryChanged(state) } }
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
    var viewerNetworkLabel: String { viewingNetwork?.name ?? "This Mac only" }
    var canInviteOtherDevices: Bool { viewingNetwork?.isLoopback == false }
    var viewingCodeStatus: String {
        if stoppingSharing || !state.sharing { return "Sharing is off" }
        if !canInviteOtherDevices { return "Choose a viewing network to invite other devices." }
        return "Waiting for the viewing network…"
    }
    var viewingInstructions: String {
        if !canInviteOtherDevices { return "Choose a viewing network to invite other devices." }
        if !wifiSSID.isEmpty { return "Join \(wifiSSID), then scan to watch." }
        if viewingNetwork?.wireless == false {
            return "Join the Wi-Fi on this Mac's Ethernet network, then scan."
        }
        if setup?.kind == .accsoon, let ssid = setup?.sourceWiFi, !ssid.isEmpty { return "Join \(ssid), then scan to watch." }
        return "Join the same Wi-Fi as this Mac, then scan to watch."
    }
    var localReady: Bool { state.sourceAvailable && nativePreviewPlaying }
    var floatingPresentation: FloatingPreviewState {
        FloatingPreviewState(session: state, control: audienceControl, localReady: localReady, busy: busy,
                             starting: startingSharing, stopping: stoppingSharing, viewers: viewers)
    }
    private var outgoingReady: Bool { state.audienceAvailable && (state.holding || state.sourceAvailable) }
    var audiencePresentation: AudiencePresentation {
        AudiencePresentation(session: state, control: audienceControl,
                             change: !state.sharing && startingSharing ? .startSharing : outgoingTransition.activeChange(),
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
    var openedViewers: Int { admittedViewers.count }
    var otherDeviceViewers: Int { viewers.filter { $0.playing && !$0.onThisMac }.count }
    private var appliedReaders: Set<ViewerReader> = []
    /// The approval choice MediaMTX has accepted. An uncertain active-session change ends
    /// sharing; private monitoring continues and a later Start reapplies authorization.
    private var appliedApproval = false
    /// Pointers describe the live shared picture, so they appear only while it is being shared,
    /// and on this Mac only after the operator chooses to see them.
    var showsPointers: Bool { sharedPointers && pointersOnThisMac && state.sharing && !state.holding && !stoppingSharing }
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
        guard !busy, !applyingViewerApproval, enabled != viewerApproval else { return }
        applyingViewerApproval = true
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
    /// Acts only if the exact request is still pending on the current link.
    @discardableResult func answer(_ request: JoinRequest, admit: Bool) -> Bool {
        guard state.sharing, viewerApproval, !stoppingSharing else { return false }
        viewers = gateway.viewers
        guard let viewer = request.current(in: viewers, link: viewingLink),
              admit ? gateway.approve(viewer) : gateway.decline(viewer) else { return false }
        SessionLog.shared.record(admit ? "viewer.admit" : "viewer.decline",
                                 ["number": viewer.number, "shortAddress": viewer.shortAddress])
        viewers = gateway.viewers
        if admit { syncViewerAccess() }
        return true
    }
    private func observeJoinRequests() {
        joinRequests.observe(link: viewingLink, active: state.sharing && viewerApproval, viewers: viewers)
    }
    /// Ends the exact admitted session's playback and presence. Other viewers continue.
    @discardableResult func removeViewer(_ reference: JoinRequest) -> Bool {
        guard state.sharing, viewerApproval, !stoppingSharing else { return false }
        viewers = gateway.viewers
        guard let current = reference.current(in: viewers, link: viewingLink, admission: .admitted),
              gateway.remove(current) else { return false }
        SessionLog.shared.record("viewer.remove", ["number": current.number])
        viewers = gateway.viewers; syncViewerAccess()
        return true
    }
    /// Applies the gateway's admitted readers to the media server, one change at a time. A page
    /// receives its own credential only after the server has accepted it.
    private func syncViewerAccess() {
        guard accessSync == nil else { accessSyncAgain = true; return }
        accessSync = Task { [weak self] in
            while let self, !self.shuttingDown, !self.stoppingSharing {
                self.accessSyncAgain = false
                let approval = self.viewerApproval, readers = self.gateway.desiredReaders, wasSharing = self.state.sharing
                let generation = self.audienceCommandGeneration
                let runtimeGeneration = wasSharing ? self.currentRuntime?.audienceGeneration : nil
                do {
                    try await self.runtime.setViewerAccess(approval: approval, readers: readers, for: runtimeGeneration)
                    let applied: Bool
                    if wasSharing, let runtimeGeneration {
                        applied = await self.runtime.viewerAccessConfirmed(approval: approval, readers: readers, for: runtimeGeneration)
                    } else { applied = !wasSharing }
                    if self.isCurrentAudienceCommand(generation), self.viewerApproval == approval,
                       self.gateway.desiredReaders == readers, applied {
                        self.appliedReaders = readers; self.appliedApproval = approval
                        self.gateway.confirm(readers: readers)
                        if approval == self.viewerApproval { self.applyingViewerApproval = false }
                        self.apply(await self.runtime.snapshot())
                        self.publishGatewayState()
                    }
                } catch is CancellationError {
                    // Stop or a new runtime lifetime superseded this authorization.
                } catch {
                    if self.isCurrentAudienceCommand(generation) {
                        self.lastRuntimeProblem = Redaction.text(error.localizedDescription)
                        if wasSharing, self.beginStoppingSharing() {
                            self.error = "Sharing stopped because viewer access could not be confirmed. Your local monitor continues. Start sharing again to retry."
                            await self.finishStoppingSharing()
                        } else if !wasSharing {
                            self.error = "Viewer access could not be confirmed. Setbeam will retry before sharing."
                        }
                    }
                }
                guard self.accessSyncAgain else { break }
            }
            self?.applyingViewerApproval = false
            self?.accessSync = nil
        }
    }
    var setupViewingNetwork: NetworkAddress? {
        guard !viewerNetworkNeedsUpdate, canInviteOtherDevices else { return nil }
        return networks.first { $0.interface == viewerInterface && $0.address == viewerAddress }
    }
    var setupViewingLinkReady: Bool {
        setupViewingNetwork != nil && viewingInvitation != nil
    }
    var setupApprovalReady: Bool { !applyingViewerApproval && (!state.sharing || viewerApproval == appliedApproval) }

    private var setupCheckOutput: SetupCheckOutput? {
        guard setupViewingLinkReady, setupApprovalReady, audiencePresentation.phase == .sharing,
              let network = setupViewingNetwork, let revision = currentRuntime?.audienceRevision else { return nil }
        return SetupCheckOutput(link: viewingLink, revision: revision, route: network.id, reports: gateway.viewers)
    }
    var setupCheckPlayingCount: Int { setupCheckOutput?.viewerCount ?? 0 }

    var setupCheck: SetupCheck {
        let output = setupCheckOutput
        return SetupCheck(picture: localReady && !permissionDenied, viewingAddress: setupViewingLinkReady,
            otherDevicePlaying: (output?.viewerCount ?? 0) > 0,
            outgoingAudio: state.sharing && audiencePresentation.phase == .sharing && audienceHasAudio)
    }
    var incomingAudioLabel: String { !state.sourceAvailable ? "Input audio: waiting" : sourceHasAudio ? "Input audio: track received" : "Input audio: no track" }
    var audienceAudioLabel: String {
        if !state.sharing { return "Audience audio: off" }
        if audiencePresentation.confirmedHold { return "Audience audio: silenced by Hold" }
        if audiencePresentation.phase != .sharing { return "Audience audio: not confirmed" }
        if state.audience != .live { return "Audience audio: reconnecting" }
        return audienceHasAudio ? "Audience audio: included" : "Audience audio: no track"
    }
    var canShare: Bool { localReady && !busy && !stoppingSharing }
    var canStopSharing: Bool { !shuttingDown && !stoppingSharing && (state.sharing || startingSharing) }
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
        if let request = deniedSourceRequest { return "Allow \(request.permission.title) Access" }
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
        if let request = deniedSourceRequest { return request.instructions }
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
                return pyroHRouteProblem ?? "Turn on the Pyro H and its computer or camera output. Rejoin the original Wi-Fi and close HollyView or other direct viewers."
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
        audiencePlayer.onPlaybackState = { [weak self] playing, _ in
            guard let self else { return }
            let ready = playing && self.freshOutgoingPicture != nil
            if ready != self.audiencePreviewPlaying { self.audiencePreviewPlaying = ready }
        }
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
        if integration { openSample() }
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
                self.refreshViewingGatewayReadiness()
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
        guard snapshot.audienceGeneration >= (currentRuntime?.audienceGeneration ?? 0),
              !stoppingSharing || !snapshot.session.sharing else { return }
        if !snapshot.session.sharing || snapshot.source != .sample { integrationSessionFile?.clear() }
        if currentRuntime?.audienceRevision != snapshot.audienceRevision || snapshot.session.audience != .live { clearChatAttachment() }
        currentRuntime = snapshot; preview = snapshot.session.monitoring ? snapshot.preview : nil
        sourceHasAudio = snapshot.sourceHasAudio; audienceHasAudio = snapshot.audienceHasAudio
        state = snapshot.session
        audienceControl.observe(snapshot.session)
        lastRuntimeProblem = snapshot.message ?? ""
        outgoingTransition.observeReady(outgoingReady)
        if let frame = snapshot.lastFrameAt { lastFrameAt = frame }
        updateSourceDisplayPointers()
        updateAudiencePreview()
    }

    private func updateAudiencePreview() {
        guard launched, !shuttingDown, !stoppingSharing, audienceControl.pending == nil,
              let currentRuntime, let target = OutgoingPreview(currentRuntime) else {
            stopAudiencePreview()
            return
        }
        guard audiencePreviewTarget != target else { return }
        stopAudiencePreview()
        audiencePreviewTarget = target
        audiencePreviewStart = Task { [weak self, runtime] in
            let url = await runtime.audiencePreviewURL(generation: target.generation, revision: target.revision)
            guard !Task.isCancelled, let self, self.audiencePreviewTarget == target else { return }
            self.audiencePreviewStart = nil
            guard let url else { self.audiencePreviewTarget = nil; return }
            do {
                try self.audiencePlayer.start(url: url)
                self.audiencePlayer.checkHealth(sourceAvailable: true)
            } catch {
                self.audiencePreviewTarget = nil
                SessionLog.shared.record("audience.preview.start.failed", ["error": error.localizedDescription])
            }
        }
    }

    private func stopAudiencePreview() {
        guard audiencePreviewTarget != nil || audiencePreviewPlaying else { return }
        audiencePreviewTarget = nil
        audiencePreviewStart?.cancel(); audiencePreviewStart = nil
        audiencePlayer.stop(); audiencePreviewPlaying = false
    }

    private var freshOutgoingPicture: PreviewPicture? {
        guard let currentRuntime, let target = OutgoingPreview(currentRuntime), audiencePreviewTarget == target,
              let decoder = audiencePlayer.decoderGeneration else { return nil }
        return audiencePlayer.freshPicture(for: decoder)
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
    func openSources(category: SourceCategory? = nil) {
        guard present(.connection, prepare: { sourceCategory = category }) else { return }
        refreshCaptureDevices()
    }
    func openSample() {
        connect(SourceSetup(kind: .sample, name: "Sample feed"), remember: false)
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
    var pyroHRouteProblem: String? {
        guard setup?.networkProfile == .pyroH else { return nil }
        return error ?? [PyroHRoute.changedWiFi, PyroHRoute.verifyWiFi].first { $0 == currentRuntime?.message }
    }
    func requestPyroHLocation() { transmitterWiFi.requestLocation() }
    var canDiscoverPyroH: Bool { !(state.monitoring && setup?.kind == .network) }
    func connectPyroH(_ device: PyroHSource) {
        var candidate = device.setup
        if device.network.interface == "lo0" { candidate.name = "Pyro H test stream" }
        connect(candidate, address: device.address)
    }
    func openSourceDetails() {
        present(.sourceDetails) {
            refreshCaptureDevices()
            if !integration, let identity = TransmitterWiFiIdentity(setup) {
                loadTransmitterRejoinMode(for: identity)
                transmitterWiFiPassword = transmitterOpenNetwork ? "" : SecureSettings.read(identity.credentialAccount) ?? ""
            }
        }
    }
    func openNetworkSource() {
        present(.networkSource) {
            let activeAddress = setup?.networkProfile == .pyroH ? nil : activeNetworkURL
            savedNetworkURL = Self.networkSourcePrefill(kind: setup?.kind, activeAddress: activeAddress)
                ?? provenSetup.flatMap { $0.kind == .network && $0.networkProfile == nil ? SecureSettings.read($0.credentialAccount) : nil } ?? ""
        }
    }
    nonisolated static func networkSourcePrefill(kind: InputKind?, activeAddress: String?) -> String? {
        kind == .network ? activeAddress : nil
    }
    func showSharing(_ section: SharingSection) {
        if sheet != nil || monitorWindow?.isVisible == false { sharingInWindow = true }
        if section == .viewers { loadViewingWiFi() }
        lastSharingSection = section
        sharingSection = section
        sharingFocusRequest &+= 1
        if sharingInWindow { sharingWindow?.makeKeyAndOrderFront(nil) }
    }
    func showSharingStatus() { showSharing(sharingSection ?? lastSharingSection) }
    func showViewingNetwork() { prepareSharingDraft(); selectSettings(.network); settingsRequest &+= 1 }
    func showAudienceControls() { prepareSharingDraft(); audienceControlsShown = true }
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
        if saved.networkProfile == .pyroH && saved.pyroHRoute == nil {
            error = PyroHRoute.rediscover
            if !state.monitoring { setup = saved }
            return
        }
        let address = saved.kind == .network || saved.kind == .incoming ? SecureSettings.read(saved.credentialAccount) : nil
        if (saved.kind == .network || saved.kind == .incoming) && address == nil {
            error = saved.networkProfile == .pyroH ? PyroHRoute.rediscover
                : "The saved address is unavailable. Reconnect this source using Enter Stream Address."
            if !state.monitoring { setup = saved }
            return
        }
        connect(saved, address: address)
    }
    func connect(_ candidate: SourceSetup, address: String? = nil, remember: Bool = true) {
        guard !busy, !shuttingDown else { return }
        let chosen: VideoSource
        do { chosen = try candidate.source(address: address).validated() }
        catch {
            if candidate.networkProfile == .pyroH, !state.monitoring { setup = candidate }
            self.error = error.localizedDescription; return
        }
        busy = true; error = nil; deniedSourceRequest = nil; sheet = nil
        let discovery = sourceBrowser.stop()
        rejoinAttempt?.revoke()
        Task {
            defer { preparingConnection = false; busy = false }
            await viewingWiFiScan?.value
            await discovery?.value
            guard !shuttingDown else { return }
            if let denied = await Self.deniedPermission(for: candidate) {
                guard !shuttingDown else { return }
                recordDeniedSource(DeniedSourceRequest(candidate: candidate, address: address, remember: remember, permission: denied))
                return
            }
            guard !shuttingDown else { return }
            let changingSource = state.monitoring
            if localReady, let setup {
                previousSource = (setup, activeNetworkURL, rememberSetup)
            }
            if state.sharing && !stoppingSharing && (!state.holding || !state.audienceAvailable) {
                outgoingTransition.begin(.hold)
                audienceControl.begin(.hold)
                stopAudiencePreview()
                gateway.setChatFramePermission(false); clearChatAttachment(); updateSourceDisplayPointers()
            }
            preparingConnection = true
            if !changingSource {
                clearViewingInvitation()
                gateway.stop(); gatewayPort = nil; viewers = []; sharingPower.hold(false)
                retireLocalAddress()
                currentRuntime = nil
            }

            do {
                let inputAddress = candidate.kind == .incoming ? networks.first(where: \.wireless)?.address ?? "127.0.0.1" : nil
                if changingSource { _ = try await runtime.replaceSource(chosen, inputAddress: inputAddress) }
                else {
                    await runtime.setVideoSettings(quality: audienceQuality, frameRate: audienceFrameRate, screenFrameRate: screenFrameRate)
                    _ = try await runtime.prepare(source: chosen, viewerAddress: viewerAddress, inputAddress: inputAddress)
                }
                guard !shuttingDown else { return }
                commitSourceSelection(candidate, source: chosen, address: address, remember: remember)
                try await refreshSelectedSourcePlayback()
                if state.sharing && !stoppingSharing, let pending = audienceControl.pending, pending == .hold {
                    audienceControl.complete(state)
                }
                publishGatewayState()
                if restoreFloating { floating.show() }
                preparingConnection = false; busy = false
                if candidate.kind == .incoming && candidate.confirmedAt == nil { present(.incoming) }
                if integration && !changingSource { await startSharingNow(); writeIntegrationSession() }
            } catch {
                guard !shuttingDown else { return }
                if !changingSource {
                    await runtime.shutdown()
                    guard !shuttingDown else { return }
                    commitSourceSelection(candidate, source: chosen, address: address, remember: remember)
                } else {
                    let actual = await runtime.snapshot()
                    guard !shuttingDown else { return }
                    if actual.source == chosen, source != chosen {
                        commitSourceSelection(candidate, source: chosen, address: address, remember: remember)
                    }
                }
                try? await refreshSelectedSourcePlayback()
                guard !shuttingDown else { return }
                if state.sharing && !stoppingSharing && audienceControl.pending == .hold {
                    if state.holding && state.audienceAvailable { audienceControl.complete(state) }
                    else { audienceControl.fail(.hold, session: state); outgoingTransition.reset() }
                }
                if case .pyroH = chosen, case SetbeamError.unavailable(let message) = error,
                   [PyroHRoute.changedWiFi, PyroHRoute.verifyWiFi].contains(message) {
                    self.error = message
                } else {
                    self.error = state.sharing && !stoppingSharing
                        ? (audiencePresentation.confirmedHold ? "The new input could not start. Viewers remain on Hold. Retry or return to the previous source."
                           : "The new input could not start and holding output is not confirmed. Retry Hold or stop sharing.")
                        : "The connection could not start. Retry, or return to the previous source."
                }
                lastRuntimeProblem = Redaction.text(error.localizedDescription)
                publishGatewayState()
            }
        }
    }
    private func commitSourceSelection(_ candidate: SourceSetup, source: VideoSource, address: String?, remember: Bool) {
        localPlayer.stop()
        nativePreviewPlaying = false; sourceHasAudio = false
        readiness = SetupReadiness(); setupConfirmed = false; lastFrameAt = nil; connectedAt = Date()
        rememberFailed = false
        setup = candidate; activeNetworkURL = address; rememberSetup = remember
        windowPresence = nil; windowTitle = nil
        self.source = source
        incomingServer = ""; incomingStreamKey = ""
    }

    private func refreshSelectedSourcePlayback() async throws {
        let destination = await runtime.incomingDestination()
        let localURL = await runtime.localRTSP()
        let snapshot = await runtime.snapshot()
        guard !shuttingDown else { return }
        if setup?.kind == .incoming, let destination {
            incomingServer = destination.server; incomingStreamKey = destination.streamKey
        }
        apply(snapshot)
        if state.monitoring, !nativePreviewPlaying { try localPlayer.start(url: localURL) }
    }

    func returnToPreviousSource() {
        guard !protectsSourceDraft else { monitorWindow?.makeKeyAndOrderFront(nil); return }
        guard !busy, let previousSource else { return }
        connect(previousSource.setup, address: previousSource.address, remember: previousSource.remember)
    }
    private static func deniedPermission(for candidate: SourceSetup) async -> PermissionKind? {
        if candidate.kind.isMacCapture {
            let allowed = await Task.detached { MacScreenCapture.requestPermission() }.value
            return allowed ? nil : .screenRecording
        }
        guard candidate.kind == .capture else { return nil }
        guard await requestPermission(.video) else { return .camera }
        if candidate.audioID != nil, !(await requestPermission(.audio)) { return .microphone }
        return nil
    }

    func recordDeniedSource(_ request: DeniedSourceRequest) {
        deniedSourceRequest = request
        SessionLog.shared.record("source.permission.denied", ["permission": request.permission.rawValue])
    }

    private static func requestPermission(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }
    private func confirmSetupIfReady() {
        guard !preparingConnection, !setupConfirmed, !rememberFailed, readiness.observe(sourceFresh: state.sourceAvailable, previewFresh: nativePreviewPlaying), let setup else { return }
        guard rememberSetup, !integration else { setupConfirmed = true; return }
        do {
            if setup.kind == .network || setup.kind == .incoming {
                guard let activeNetworkURL else { throw SetbeamError.unavailable("The source address is unavailable.") }
                try SecureSettings.store(activeNetworkURL, account: setup.credentialAccount)
            }
            let previous = provenSetup
            try store.confirm(setup)
            provenSetup = store.setup; setupConfirmed = true
            if let previous, previous.id != setup.id, previous.kind == .network || previous.kind == .incoming {
                if !SecureSettings.remove(previous.credentialAccount) {
                    SessionLog.shared.record("source.credential.retirement.failed")
                }
            }
        } catch { rememberFailed = true; self.error = "Your picture is working, but Setbeam could not remember this connection. Retry saving in Source Details." }
    }
    func retry() {
        guard !busy else { return }; error = nil
        if let request = deniedSourceRequest {
            connect(request.candidate, address: request.address, remember: request.remember)
            return
        }
        if state.monitoring {
            busy = true
            connectedAt = Date()
            Task {
                await runtime.retrySource()
                guard !shuttingDown else { return }
                localPlayer.retry(); apply(await runtime.snapshot()); busy = false
            }
            return
        }
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
        guard !shuttingDown, !busy, !stoppingSharing, state.monitoring, !state.sharing, (localReady || integration) else { return }
        // Viewers may come to depend on this Mac's Wi-Fi; a pending rejoin must not switch it.
        if rejoinAttempt?.revoke() == true {
            error = "The transmitter is joining Wi-Fi. Try Go Live again when it finishes."
            return
        }
        busy = true; startingSharing = true; error = nil
        let generation = audienceCommandGeneration
        defer { busy = false; startingSharing = false; writeIntegrationSession() }
        outgoingTransition.begin(.startSharing)
        do {
            await viewingWiFiScan?.value
            guard isCurrentAudienceCommand(generation) else { return }
            guard localReady || integration else { outgoingTransition.reset(); return }
            await refreshNetworks()
            guard isCurrentAudienceCommand(generation) else { return }
            guard !viewerNetworkNeedsUpdate else { throw SetbeamError.unavailable("The viewing network could not be configured.") }
            let snapshot = try await runtime.startSharing(approval: viewerApproval)
            guard isCurrentAudienceCommand(generation) else { return }
            apply(snapshot)
            appliedReaders = []; viewingLink += 1
            publishGatewayState()
            try await bindViewingGateway(port: gatewayPort ?? 0)
            guard isCurrentAudienceCommand(generation) else { return }
            observeJoinRequests()
            networkChanged = false; sharingPower.hold(true)
            // Going live shows the codes while nobody is watching yet. Presentation only.
            if admittedViewers.isEmpty && sharingSection == nil { showSharing(.viewers) }
        } catch {
            guard isCurrentAudienceCommand(generation), beginStoppingSharing() else { return }
            gateway.stop(); gatewayPort = nil
            self.error = "Sharing could not start. Check the viewing network and try again."
            lastRuntimeProblem = Redaction.text(error.localizedDescription)
            await finishStoppingSharing()
        }
    }
    private func isCurrentAudienceCommand(_ generation: UInt64) -> Bool {
        generation == audienceCommandGeneration && !shuttingDown && !stoppingSharing
    }

    func toggleHold() { performAudienceAction() }
    func setAudienceHold(_ value: Bool) {
        guard state.sharing, !busy, !stoppingSharing, !shuttingDown else { return }
        guard value || localReady else { error = "Wait for a fresh local picture before resuming sharing."; return }
        busy = true
        let generation = audienceCommandGeneration
        audienceControl.begin(AudienceTarget(holding: value))
        stopAudiencePreview()
        gateway.setChatFramePermission(false); clearChatAttachment()
        updateSourceDisplayPointers()
        outgoingTransition.begin(value ? .hold : .resume)
        writeExperienceState()
        Task {
            defer { busy = false; writeExperienceState() }
            do {
                try await runtime.setHold(value)
                let snapshot = await runtime.snapshot()
                guard isCurrentAudienceCommand(generation) else { return }
                apply(snapshot)
                audienceControl.complete(state)
                updateAudiencePreview()
            } catch {
                let snapshot = await runtime.snapshot()
                guard isCurrentAudienceCommand(generation) else { return }
                apply(snapshot)
                audienceControl.fail(AudienceTarget(holding: value), session: state)
                outgoingTransition.reset()
                self.error = value ? "Hold did not finish. Retry Hold or stop sharing." : "Resume did not finish. Retry Resume, Hold, or stop sharing."
                lastRuntimeProblem = Redaction.text(error.localizedDescription)
            }
            publishGatewayState()
        }
    }
    func stopSharing() {
        guard canStopSharing, beginStoppingSharing() else { return }
        Task { await finishStoppingSharing() }
    }
    private func beginStoppingSharing() -> Bool {
        guard !stoppingSharing, !shuttingDown else { return false }
        stoppingSharing = true
        audienceCommandGeneration &+= 1
        integrationSessionFile?.clear()
        clearViewingInvitation()
        if startingSharing && gatewayPort == nil { gateway.stop() }
        sharingPower.hold(false)
        retireLocalAddress()
        outgoingTransition.reset()
        audienceControl = AudienceControlState()
        stopAudiencePreview(); audienceHasAudio = false
        clearChatAttachment()
        pointerPresence.clear(); pointersOnThisMac = false
        updateSourceDisplayPointers()
        publishGatewayState()
        return true
    }
    private func finishStoppingSharing() async {
        await runtime.stopSharing()
        let stopped = await runtime.snapshot()
        appliedReaders = []
        apply(stopped)
        publishGatewayState()
        viewers = gateway.viewers
        refreshChat()
        stoppingSharing = false
        writeExperienceState()
    }
    private func publishGatewayState() {
        guard let snapshot = currentRuntime else { return }
        gateway.update(ViewerSession(token: snapshot.guestToken, title: title, sample: snapshot.source == .sample,
            state: stoppingSharing ? .stopped : state.audience,
            playback: snapshot.audience, revision: snapshot.audienceRevision, wifiSSID: wifiSSID))
        gateway.setChatFramePermission(audienceAllowsFrame)
    }
    private var audienceAllowsFrame: Bool { state.audience == .live && outgoingReady && audienceControl.pending == nil && !busy && !stoppingSharing && !shuttingDown }
    var canCaptureChatFrame: Bool { audienceAllowsFrame && freshOutgoingPicture != nil }
    func refreshChat() {
        let messages = state.sharing ? gateway.chatMessages : []
        if messages != chatMessages {
            let imageIDs = Set(messages.filter(\.hasFrame).map(\.id))
            chatImages = chatImages.filter { imageIDs.contains($0.key) }
            for id in imageIDs where chatImages[id] == nil { if let data = gateway.chatFrame(id: id), let image = NSImage(data: data) { chatImages[id] = image } }
            chatMessages = messages
        }
        if (sharingInWindow || sharingCanDock), sharingSection == .chat, NSApp?.isActive == true,
           (sharingInWindow ? sharingWindow : monitorWindow)?.isKeyWindow == true { markChatRead() }
        if !state.sharing {
            if !chatText.isEmpty { chatText = "" }
            if chatReplyTo != nil { chatReplyTo = nil }
            if chatReadThrough != 0 { chatReadThrough = 0 }
            if chatProblem != nil { chatProblem = nil }
            if chatCapturing || chatAttachment != nil { clearChatAttachment(discard: true) }
        }
    }
    func chatFrame(id: Int) -> Data? { gateway.chatFrame(id: id) }
    var chatReplyUnavailable: Bool {
        chatReplyTo.map { id in !chatMessages.contains(where: { $0.id == id }) } ?? false
    }
    var chatAttachmentStale: Bool {
        chatAttachment != nil && (chatAttachmentLink != viewingLink || chatAttachmentRevision != currentRuntime?.audienceRevision ||
            chatAttachmentRevision == nil || !canCaptureChatFrame)
    }
    var canSendChat: Bool {
        state.sharing && !chatCapturing && !chatReplyUnavailable && !chatAttachmentStale &&
            (!chatText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatAttachment != nil)
    }
    func clearChatAttachment(discard: Bool = false) {
        if chatCapturing { chatCaptureGeneration = UUID(); chatCapturing = false }
        if discard { chatAttachment = nil }
        chatAttachmentRevision = nil; chatAttachmentLink = nil
    }
    func captureChatFrame() {
        guard !chatCapturing, audienceAllowsFrame, let picture = freshOutgoingPicture,
              let decoder = audiencePlayer.decoderGeneration, let snapshot = currentRuntime else { return }
        let generation = UUID(), link = viewingLink, revision = snapshot.audienceRevision
        chatCaptureGeneration = generation; chatCapturing = true
        Task {
            let data = await Task.detached(priority: .userInitiated) { ChatFrameEncoder.encode(picture) }.value
            guard chatCaptureGeneration == generation else { return }
            chatCapturing = false
            guard link == viewingLink, currentRuntime?.audienceRevision == revision,
                  audiencePlayer.decoderGeneration == decoder, canCaptureChatFrame else { return }
            guard let data else { chatProblem = "The outgoing frame could not be prepared. Try another frame."; return }
            chatAttachment = data; chatAttachmentRevision = revision; chatAttachmentLink = link; chatProblem = nil
        }
    }
    func sendChat() {
        refreshChat()
        guard canSendChat, let snapshot = currentRuntime else { return }
        do {
            try gateway.postChat(text: chatText, replyTo: chatReplyTo, frame: chatAttachment, revision: snapshot.audienceRevision,
                                 token: snapshot.guestToken, name: chatOperatorName, color: chatOperatorColor, requestID: UUID().uuidString)
            chatText = ""; chatReplyTo = nil; clearChatAttachment(discard: true); chatProblem = nil; refreshChat()
        } catch { chatProblem = error.localizedDescription; refreshChat() }
    }
    func likeChat(_ message: ChatMessage) {
        guard let snapshot = currentRuntime, let current = chatMessages.first(where: { $0.id == message.id }) else { return }
        do { try gateway.likeChat(id: message.id, liked: !current.liked, token: snapshot.guestToken); chatProblem = nil; refreshChat() }
        catch { chatProblem = error.localizedDescription }
    }
    func reactChat(_ message: ChatMessage, reaction: ChatReaction) {
        guard let snapshot = currentRuntime, let current = chatMessages.first(where: { $0.id == message.id }) else { return }
        let selected = current.reactions.contains { $0.reaction == reaction && $0.selected }
        do { try gateway.reactChat(id: message.id, reaction: selected ? nil : reaction, token: snapshot.guestToken); chatProblem = nil; refreshChat() }
        catch { chatProblem = error.localizedDescription }
    }
    func removeChat(_ message: ChatMessage) {
        guard let snapshot = currentRuntime else { return }
        gateway.removeChat(id: message.id, token: snapshot.guestToken); refreshChat()
    }
    func refreshNetworks() async {
        guard !shuttingDown else { return }
        let available = NetworkAddress.available()
        networks = available
        await refreshViewingNetwork(available)
        guard !shuttingDown else { return }
        if let selectedSetup = setup, selectedSetup.kind == .incoming, state.monitoring, !preparingConnection {
            try? await runtime.updateInputAddress(available.first(where: \.wireless)?.address ?? "127.0.0.1", for: source)
            if let destination = await runtime.incomingDestination(), setup == selectedSetup, !preparingConnection {
                incomingServer = destination.server; incomingStreamKey = destination.streamKey
            }
        }
    }

    private func refreshViewingNetwork(_ available: [NetworkAddress]) async {
        guard !stoppingSharing else { return }
        let selected: NetworkAddress?
        if state.sharing, let current = viewingNetwork {
            guard let observed = current.observation(in: available) else {
                clearViewingInvitation()
                return
            }
            switch current.trust(in: observed) {
            case .same:
                selected = observed
            case .unresolved:
                clearViewingInvitation()
                return
            case .changed:
                clearViewingInvitation()
                gateway.stop(); gatewayPort = nil
                if beginStoppingSharing() { await finishStoppingSharing() }
                networkChanged = true
                return
            }
        } else if state.sharing {
            return
        } else {
            selected = networkChoice == "automatic" ? NetworkAddress.preferred(in: available) : available.first { $0.interface == networkChoice }
        }
        let address = selected?.address ?? "127.0.0.1"
        let changed = viewingNetwork != selected
        let rebind = state.sharing && (changed || viewingBinding == nil)
        guard changed || viewerNetworkNeedsUpdate || rebind else { return }
        let operation = UUID()
        networkOperation = operation
        clearViewingInvitation(invalidateOperation: false)
        viewingNetwork = selected
        viewerInterface = selected?.interface ?? "lo0"
        viewerNetworkNeedsUpdate = true
        SessionLog.shared.record("network.viewing", ["interface": viewerInterface, "sharing": state.sharing])
        viewerAddress = address
        do {
            try await runtime.updateViewerAddress(address)
            let snapshot = await runtime.snapshot()
            guard !shuttingDown, !stoppingSharing, operation == networkOperation else { return }
            viewerNetworkNeedsUpdate = false
            if state.monitoring { apply(snapshot) }
            if state.sharing, let port = gatewayPort {
                // Keep the port and token while the same network recovers or renews its address.
                publishGatewayState()
                try await bindViewingGateway(port: port)
            } else {
                gateway.stop(); gatewayPort = nil
            }
        }
        catch {
            if operation == networkOperation { lastRuntimeProblem = Redaction.text(error.localizedDescription) }
        }
    }

    private func bindViewingGateway(port: UInt16 = 0) async throws {
        guard state.sharing, let token = currentRuntime?.guestToken else { return }
        let binding = ViewingGatewayBinding(address: viewerAddress, token: token)
        viewingBinding = binding
        do {
            let boundPort = try await gateway.start(address: binding.address, port: port)
            guard viewingBinding?.confirm(id: binding.id, port: boundPort, currentToken: activeViewingToken) == true else { return }
            gatewayPort = boundPort
            refreshViewingGatewayReadiness()
        } catch {
            guard viewingBinding?.id == binding.id, token == activeViewingToken else { return }
            // A same-network rebind keeps retrying the requested port inside ViewerGateway.
            if port != 0 { _ = viewingBinding?.confirm(id: binding.id, port: port, currentToken: activeViewingToken) }
            throw error
        }
    }

    private func clearViewingInvitation(invalidateOperation: Bool = true) {
        if invalidateOperation { networkOperation = UUID() }
        integrationSessionFile?.clear()
        guard viewingBinding != nil || viewingGatewayAttempt != nil else { return }
        viewingBinding = nil
        viewingGatewayAttempt = nil
        if state.sharing { networkChanged = false }
        copiedLink = false; copiedIPLink = false
        retireLocalAddress()
    }

    private func refreshViewingGatewayReadiness() {
        let listener = gateway.readyBinding
        let isCurrent = listener.map { viewingBinding?.matches($0, currentToken: activeViewingToken) == true } == true
            && viewingNetworkIsCurrent(in: networks)
        guard isCurrent, let listener else {
            guard viewingGatewayAttempt != nil else { return }
            viewingGatewayAttempt = nil
            retireLocalAddress()
            return
        }
        guard listener.id != viewingGatewayAttempt else { return }
        if viewingGatewayAttempt != nil {
            viewingGatewayAttempt = nil
            retireLocalAddress()
        }
        guard viewingNetworkIsCurrent(in: NetworkAddress.available()) else { return }
        viewingGatewayAttempt = listener.id
        if let last = lastReadyViewingAddress, last.link == viewingLink, last.address != listener.address {
            networkChanged = true
        }
        lastReadyViewingAddress = (viewingLink, listener.address)
        updateLocalAddress()
        writeIntegrationSession()
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
        guard network != networkChoice, !busy else { return }
        networkChoice = network
        if !integration { defaults.set(network, forKey: "viewerInterface") }
        clearViewingInvitation()
        gateway.stop(); gatewayPort = nil
        let endingShare = canStopSharing && beginStoppingSharing()
        busy = true
        Task {
            if endingShare { await finishStoppingSharing(); networkChanged = true }
            await refreshNetworks()
            busy = false
        }
    }
    func setAudienceQuality(_ quality: AudienceQuality) {
        setVideoSettings(quality: quality, frameRate: audienceFrameRate, screenRate: screenFrameRate)
    }
    var presenterCursorHighlight: Bool {
        currentRuntime?.source == source && currentRuntime?.presenterCursorHighlight == true
    }

    func setVideoSettings(quality: AudienceQuality, frameRate: VideoFrameRate, screenRate: VideoFrameRate,
                          presenterCursorHighlight: Bool? = nil) {
        let ratesChanged = quality != audienceQuality || frameRate != audienceFrameRate || screenRate != screenFrameRate
        guard ratesChanged || presenterCursorHighlight != nil else { return }
        audienceQuality = quality; audienceFrameRate = frameRate; screenFrameRate = screenRate
        if ratesChanged, !integration {
            defaults.set(quality.rawValue, forKey: "audienceQuality")
            defaults.set(frameRate.rawValue, forKey: "audienceFrameRate")
            defaults.set(screenRate.rawValue, forKey: "screenFrameRate")
        }
        Task { [source] in
            if let presenterCursorHighlight {
                await runtime.setPresenterCursorHighlight(presenterCursorHighlight, for: source)
            }
            if ratesChanged {
                await runtime.setVideoSettings(quality: quality, frameRate: frameRate, screenFrameRate: screenRate)
            }
        }
    }
    /// Opt-in. Joining another Wi-Fi network is never automatic unless the operator enables it here.
    @discardableResult func setTransmitterRejoin(_ enabled: Bool, password: String, openNetwork: Bool = false) -> Bool {
        guard let identity = TransmitterWiFiIdentity(setup) else { return false }
        guard !enabled || !password.isEmpty || openNetwork else {
            rejoinProblem = "Enter the transmitter's Wi-Fi password or choose an open network before enabling automatic rejoin."
            return false
        }
        if !integration, !password.isEmpty || openNetwork {
            do { if openNetwork { SecureSettings.remove(identity.credentialAccount) } else { try SecureSettings.store(password, account: identity.credentialAccount) } }
            catch { rejoinProblem = "The transmitter Wi-Fi password could not be saved."; return false }
            transmitterWiFiPassword = openNetwork ? "" : password
        }
        transmitterRejoin = enabled; transmitterOpenNetwork = openNetwork
        rejoinPolicy = TransmitterRejoinPolicy(); rejoinProblem = nil; rejoinAttempt?.revoke()
        if !integration {
            let network: TransmitterRejoinNetwork = openNetwork ? .open : .secured
            defaults.set(enabled ? network.rawValue : nil, forKey: identity.preferenceKey)
        }
        if enabled { transmitterWiFi.requestLocation() }
        if enabled && transmitterWiFi.locationDenied { rejoinProblem = TransmitterWiFiResult.needsLocation.message }
        SessionLog.shared.record("wifi.rejoin.setting", ["enabled": enabled])
        return true
    }
    private func loadTransmitterRejoinMode(for identity: TransmitterWiFiIdentity?) {
        let mode = integration ? nil : identity.flatMap { defaults.string(forKey: $0.preferenceKey) }
            .flatMap(TransmitterRejoinNetwork.init(rawValue:))
        transmitterRejoin = mode != nil
        transmitterOpenNetwork = mode == .open
    }
    private func rejoinTransmitterIfNeeded() {
        // Sharing over Wi-Fi depends on the current network; switching it would end viewing.
        let sharingOverWiFi = state.sharing && viewerInterface == transmitterWiFi.interfaceName
        if !transmitterRejoin || shuttingDown || sharingOverWiFi || localReady { rejoinAttempt?.revoke() }
        guard let setup, let identity = TransmitterWiFiIdentity(setup), !shuttingDown else { return }
        let visible = wirelessDevices.contains { $0.id == setup.wirelessUID }
        guard rejoinPolicy.observe(enabled: transmitterRejoin, transmitterVisible: visible, pictureLive: localReady,
                                   blocked: busy || rejoinAttempt != nil || viewingWiFiScan != nil || sharingOverWiFi, now: Date()) else { return }
        let ssid = identity.ssid
        guard transmitterWiFi.locationAllowed else {
            rejoinProblem = TransmitterWiFiResult.needsLocation.message
            SessionLog.shared.record("wifi.rejoin.result", ["network": ssid, "result": TransmitterWiFiResult.needsLocation.logValue])
            return
        }
        let password = transmitterOpenNetwork ? nil : SecureSettings.read(identity.credentialAccount)
        guard transmitterOpenNetwork || password?.isEmpty == false else {
            rejoinProblem = "The saved Wi-Fi password is unavailable. Re-enter it in Source Details."
            return
        }
        let permit = RejoinPermit(); rejoinAttempt = permit
        SessionLog.shared.record("wifi.rejoin.attempt", ["network": ssid])
        Task {
            let result = await TransmitterWiFi.join(ssid: ssid, password: password, permit: permit)
            rejoinAttempt = nil
            guard !shuttingDown, transmitterRejoin, identity == TransmitterWiFiIdentity(setup) else { return }
            rejoinProblem = result.message
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
        guard let url = currentViewingInvitation()?.preferredURL else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
        copiedLink = true; Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copiedLink = false }
    }
    func copyIPLink() {
        guard let url = currentViewingInvitation()?.ipURL else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
        copiedIPLink = true; Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copiedIPLink = false }
    }
    private var activeViewingToken: String? {
        guard state.sharing, !stoppingSharing, !shuttingDown else { return nil }
        return currentRuntime?.guestToken
    }

    private func viewingNetworkIsCurrent(in available: [NetworkAddress]) -> Bool {
        guard let viewingNetwork else { return viewerInterface == "lo0" }
        return available.contains(viewingNetwork)
    }

    private var readyViewingListener: ViewerGateway.Binding? {
        guard let listener = gateway.readyBinding, listener.id == viewingGatewayAttempt,
              viewingBinding?.matches(listener, currentToken: activeViewingToken) == true,
              viewingNetworkIsCurrent(in: networks) else { return nil }
        return listener
    }

    var viewingInvitation: ViewingInvitation? {
        viewingBinding?.invitation(currentToken: activeViewingToken, listener: readyViewingListener,
                                   localLabel: localAddressEnabled ? localAddress.activeLabel : nil)
    }

    /// Actions may run between polls or after a native modal panel has yielded the main run loop.
    func currentViewingInvitation() -> ViewingInvitation? {
        guard viewingNetworkIsCurrent(in: NetworkAddress.available()), let invitation = viewingInvitation else { return nil }
        guard invitation.localURL != nil, localAddressPublisher.state != localAddress else { return invitation }
        return ViewingInvitation(binding: invitation.binding, ipURL: invitation.ipURL, localURL: nil)
    }

    var localViewerURL: URL? { viewingInvitation?.localURL }
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
        guard !shuttingDown, !stoppingSharing, viewingInvitation != nil, localAddressEnabled else {
            localAddressPublisher.stop(); return
        }
        localAddressPublisher.publish(label: localAddressLabel, scope: .interface(viewerInterface), address: viewerAddress)
    }
    /// Withdraw the advertised entry points before the next asynchronous listener operation.
    private func retireLocalAddress() {
        receiverDiscovery.stop(); localAddressPublisher.stop(); shortAddressListener.stop()
        localAddress = .stopped
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
        shortAddressEnabled && viewerApproval && localAddressEnabled && viewingInvitation != nil && !shuttingDown && !stoppingSharing
    }
    /// The gateway accepts new short-address requests while it is open. Port 80 answers only once the
    /// name is active, and only connections to the viewing address.
    private func updateShortAddress() {
        defer { updateReceiverDiscovery() }
        let open = shortAddressOpen
        // Keep issued short-address passes valid during a same-network outage.
        if !shortAddressEnabled || !viewerApproval || !localAddressEnabled || open {
            gateway.setShortAddress(open: open)
        }
        guard open, let label = localAddress.activeLabel, let listener = readyViewingListener, let path = listener.shortAddressPath else {
            shortAddressListener.stop(); return
        }
        shortAddressListener.serve(.init(address: listener.address, hosts: [LocalAddressName.host(label)], port: listener.port, path: path))
    }
    func shortAddressChanged(_ value: ShortAddressListener.State) {
        shortAddress = value
        updateReceiverDiscovery()
        let detail: [String: Any]
        switch value {
        case .stopped: detail = ["state": "stopped"]
        case .starting: detail = ["state": "starting"]
        case .active: detail = ["state": "active"]
        case .unavailable(let problem): detail = ["state": "unavailable", "problem": problem.rawValue]
        }
        SessionLog.shared.record("short.address", detail)
    }
    /// Receivers can discover the short address exactly while typing it works. The listener's own state is
    /// read directly, so a stop takes effect before its asynchronous change notice arrives.
    private func updateReceiverDiscovery() {
        receiverDiscovery.publish(shuttingDown ? nil : ReceiverAdvertisement.current(
            shortAddressOpen: shortAddressOpen, listener: shortAddressListener.state, localAddress: localAddress,
            askPath: readyViewingListener?.shortAddressPath, interface: viewerInterface, installationID: receiverDiscoveryID))
    }
    func receiverDiscoveryChanged(_ value: ReceiverDiscoveryState) {
        guard value != receiverDiscoveryState else { return }
        receiverDiscoveryState = value
        let detail: [String: Any]
        switch value {
        case .stopped: detail = ["state": "stopped"]
        case .registering: detail = ["state": "registering"]
        case .active(let name): detail = ["state": "active", "renamed": name != localAddress.activeLabel]
        case .unavailable(let problem): detail = ["state": "unavailable", "problem": String(describing: problem)]
        }
        SessionLog.shared.record("receiver.discovery", detail)
        writeExperienceState()
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
        if !state.sharing { return ("Viewers can type \(host) and ask to join while you share.", false) }
        if viewingInvitation == nil { return (viewingCodeStatus, false) }
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
        if state.sharing && viewingInvitation == nil { return (viewingCodeStatus, false) }
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

    var canScanViewingWiFi: Bool {
        guard !busy, !shuttingDown, !state.sharing, viewingWiFiScan == nil, rejoinAttempt == nil else { return false }
        return !state.monitoring || setup?.kind.isMacCapture == true || setup?.kind == .sample || setup?.kind == .capture
    }

    func scanViewingWiFi(_ browser: ViewingWiFiBrowser) {
        guard canScanViewingWiFi else { return }
        viewingWiFiScan = Task { [weak self] in
            await browser.scan()
            self?.viewingWiFiScan = nil
        }
    }
    /// A hidden Wi-Fi name is inconclusive. An inactive Wi-Fi interface is a known miss.
    var isOnSourceWiFi: Bool? {
        if let expected = setup?.sourceWiFi, !expected.isEmpty, let actual = transmitterWiFi.connectedName {
            return expected == actual
        }
        if let name = transmitterWiFi.interfaceName, !networks.contains(where: { $0.interface == name }) { return false }
        return nil
    }
    func openWiFiSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!) }
    func openPrivacySettings() {
        guard let request = deniedSourceRequest else { return }
        NSWorkspace.shared.open(request.permission.settingsURL)
    }
    private var savingFrame = false
    func saveFrame() {
        guard localReady, !savingFrame else { return }
        guard let generation = localPlayer.decoderGeneration, let picture = localPlayer.freshPicture(for: generation) else {
            error = "The frame could not be saved. Wait for the picture and try again."
            return
        }
        savingFrame = true
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(title.isEmpty ? "Setbeam" : title)-frame.jpg"; panel.allowedContentTypes = [.jpeg]
        guard panel.runModal() == .OK, let destination = panel.url else { savingFrame = false; return }
        Task {
            defer { savingFrame = false }
            do {
                try await Task.detached(priority: .userInitiated) { try LocalFrameExport.save(picture, to: destination) }.value
            } catch {
                self.error = "The frame could not be saved. Check the destination and try again."
            }
        }
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
        integrationSessionFile?.clear()
        rejoinAttempt?.revoke()
        shuttingDown = true; pollTask?.cancel(); runtimeUpdates?.cancel(); sourceBrowser.stop(); observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        floating.close(); sourceDisplayPointers.close(); joinCodeWindow.close(); joinRequests.close(); localPlayer.stop(); stopAudiencePreview(); gateway.stop(); retireLocalAddress(); sharingPower.hold(false); displayPower.hold(false)
        SessionLog.shared.record("app.quit", ["sharing": state.sharing])
        await runtime.shutdown(); apply(await runtime.snapshot())
    }
    private func writeIntegrationSession() {
        guard let integrationSessionFile, currentRuntime?.source == .sample,
              let viewerURL = viewingBinding?.url(currentToken: activeViewingToken, listener: readyViewingListener) else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["viewerURL": viewerURL.absoluteString,
                "localURL": localViewerURL?.absoluteString ?? "", "pid": ProcessInfo.processInfo.processIdentifier])
            try integrationSessionFile.write(data)
        } catch {
            SessionLog.shared.record("integration.session.export.failed")
        }
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
            "shortAddressStatus": shortAddressStatus.text, "receiverDiscovery": receiverDiscoveryState.label, "sharingPanel": sharingSection?.rawValue ?? "",
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

private extension ReceiverDiscoveryState {
    /// A plain value for the integration state file. Never carries a code or credential.
    var label: String {
        switch self {
        case .stopped: return "stopped"
        case .registering: return "registering"
        case .active(let name): return "active:\(name)"
        case .unavailable: return "unavailable"
        }
    }
}
