import Foundation
import SwiftUI
import AppKit
import AVFoundation
import IOKit.pwr_mgt
import SetbeamCore

enum AppSheet: String, Identifiable { case connection, advanced, incoming, join, viewingWiFi, viewers, setupCheck, rename, about; var id: String { rawValue } }
enum AdvancedSection: Hashable { case workspace, connection, network, diagnostics }

@MainActor final class SessionModel: ObservableObject {
    @Published var title: String { didSet { if !integration { defaults.set(title, forKey: "sessionTitle") }; publishGatewayState() } }
    @Published private(set) var state: SessionState
    @Published var source: VideoSource = .sample
    @Published var setup: SourceSetup?
    @Published var provenSetup: SourceSetup?
    @Published var preview: PlaybackDescriptor?
    @Published var viewerURL: URL?
    @Published var viewers: [ViewerActivity] = []
    @Published var busy = false
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
    @Published var sourceHasAudio = false
    @Published var audienceHasAudio = false
    @Published var expectsAudio = false
    @Published var testSoundConfirmed = false
    let sourceBrowser = SourceBrowser()
    @Published var pipVisible = false
    @Published var sheet: AppSheet?
    var advancedSection: AdvancedSection = .workspace
    @Published var networks: [NetworkAddress]
    @Published var viewerAddress: String
    @Published var networkChoice: String
    @Published var wifiSSID: String
    @Published var wifiPassword = ""
    @Published var captureDevices: [CaptureHardware] = []
    @Published var wirelessDevices: [AccsoonDevice] = []
    @Published var wirelessDiscoveryProblem: String?
    @Published var nativePreviewPlaying = false
    @Published var setupConfirmed = false
    @Published var copiedLink = false
    @Published var lastFrameAt: Date?
    @Published var permissionDenied = false
    @Published var networkChanged = false
    @Published var diagnosticCopied = false
    @Published var incomingServer = ""
    @Published var incomingStreamKey = ""
    @Published private(set) var audienceQuality: AudienceQuality
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
    private var rememberSetup = true
    private var rememberFailed = false
    private var connectedAt = Date.distantPast
    private var lastRuntimeProblem = ""
    private let sharingPower = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep, reason: "Setbeam feed sharing")
    private let displayPower = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: "Setbeam live monitoring")
    private var loggedViewers = (opened: 0, playing: 0)
    private var observers: [NSObjectProtocol] = []
    private lazy var floating = FloatingPreviewWindow(model: self)

    init(initialState: SessionState = SessionState()) {
        state = initialState
        integration = CommandLine.arguments.contains("--integration-demo")
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--preferences-suite"), index + 1 < args.count {
            defaults = UserDefaults(suiteName: args[index + 1])!
        } else { defaults = .standard }
        store = ProvenSetupStore(defaults: defaults)
        title = defaults.string(forKey: "sessionTitle") ?? "My feed"
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
    }

    var sourceLabel: String { setup?.name ?? "Choose a source" }
    var hardwareLabel: String { setup?.deviceName ?? (setup?.kind == .sample ? "Sample video and test tone" : setup?.kind == .network ? "Network video" : "No input selected") }
    var viewerNetworkLabel: String { networks.first(where: { $0.address == viewerAddress })?.name ?? "This Mac only" }
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
    private var outgoingReady: Bool { state.audienceAvailable && (state.holding || state.sourceAvailable) }
    var outgoingIsChanging: Bool { state.sharing && !outgoingReady && outgoingTransition.activeChange() != nil }
    var outgoingNeedsAttention: Bool {
        state.sharing && !outgoingReady && !outgoingIsChanging
    }
    var sharingTitle: String {
        guard state.sharing else { return "Private" }
        if outgoingIsChanging, let change = outgoingTransition.activeChange() { return change.title }
        if state.holding { return "On hold" }
        return outgoingNeedsAttention ? "Reconnecting" : "Sharing"
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
    var verifiedViewers: Int { viewers.filter(\.playing).count }
    var openedViewers: Int { viewers.count }
    var otherDeviceViewers: Int { viewers.filter { $0.playing && !$0.onThisMac }.count }
    var setupCheck: SetupCheck {
        SetupCheck(picture: localReady, viewingAddress: state.sharing && gateway.isRunning && viewerAddress != "127.0.0.1",
            otherDevicePlaying: otherDeviceViewers > 0, expectsAudio: expectsAudio,
            outgoingAudio: state.audience == .live && audienceHasAudio, soundConfirmed: testSoundConfirmed)
    }
    var incomingAudioLabel: String { !state.sourceAvailable ? "Input audio: waiting" : sourceHasAudio ? "Input audio: track received" : "Input audio: no track" }
    var audienceAudioLabel: String {
        if !state.sharing { return "Audience audio: off" }
        if state.holding { return "Audience audio: silenced by Hold" }
        if state.audience != .live { return "Audience audio: reconnecting" }
        return audienceHasAudio ? "Audience audio: included" : "Audience audio: no track"
    }
    var canShare: Bool { localReady && !busy }
    var restoreFloating: Bool { !integration && defaults.bool(forKey: "floatingVisible") }
    var audienceLabel: String {
        guard state.sharing else { return "Only you can see this" }
        if outgoingIsChanging { return sharingTitle }
        switch state.audience { case .holding: return "Audience on hold"; case .reconnecting: return "Audience reconnecting"; default: return "Sharing with viewers" }
    }
    var statusLabel: String {
        if preparingConnection { return "Connecting" }
        if setup == nil { return "Choose a source" }
        if connectingToPicture { return "Connecting" }
        if setup?.kind == .accsoon, let device = wirelessDevices.first(where: { $0.id == setup?.wirelessUID }), !device.videoAvailable { return "Waiting for a source" }
        if !localReady { return "Reconnecting" }
        if state.holding { return "On hold" }
        if state.sharing { return state.audience == .live ? "Sharing" : "Connecting viewers" }
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
        if state.sourceAvailable && !nativePreviewPlaying { return "Restoring your preview" }
        return setup.kind == .network || setup.kind == .incoming ? "Waiting for \(setup.name)" : "Waiting for a picture"
    }
    var recoveryDetail: String {
        if permissionDenied { return "Enable Setbeam in Privacy & Security, then retry. Access is only needed for the input you chose." }
        if connectingToPicture { return "Your monitor is opening. Your picture stays private until you start sharing." }
        guard let setup else { return "Connect a receiver, camera, or computer output. You can also try a clearly labeled sample." }
        if setup.kind == .capture { return "Connect the selected device to this Mac. If it is connected, check the HDMI or SDI cable and turn on the source. Setbeam keeps trying this same input." }
        if setup.kind == .network {
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
        Task { await runtime.setAudienceQuality(audienceQuality) }
        localPlayer.muted = localMuted
        localPlayer.onPlaybackState = nativePlaybackState
        audiencePlayer.onPlaybackState = { [weak self] playing, _ in self?.audiencePreviewPlaying = playing }
        localPlayer.onSoundUnavailable = { [weak self] message in self?.localMuted = true; self?.error = message }
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
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshCaptureDevices(); self?.localPlayer.retry(); self?.audiencePlayer.retry() }
        })
        if integration { connect(SourceSetup(kind: .sample, name: "Sample feed"), remember: false) }
        else if let saved = provenSetup { restore(saved) }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, !self.shuttingDown else { return }
                tick += 1
                self.updateDisplayWake()
                if tick % 3 == 0 && !self.busy {
                    self.refreshCaptureDevices(); await self.refreshNetworks()
                    if self.sheet == .connection || self.setup?.kind == .accsoon { await self.refreshWireless() }
                }
                guard self.state.monitoring, !self.busy else { self.writeExperienceState(); continue }
                self.viewers = self.gateway.viewers
                self.recordViewerChanges()
                self.confirmSetupIfReady()
                self.writeExperienceState()
            }
        }
    }
    func apply(_ snapshot: RuntimeSnapshot) {
        currentRuntime = snapshot; preview = snapshot.session.monitoring ? snapshot.preview : nil
        sourceHasAudio = snapshot.sourceHasAudio; audienceHasAudio = snapshot.audienceHasAudio
        state = snapshot.session
        lastRuntimeProblem = snapshot.message ?? ""
        outgoingTransition.observeReady(outgoingReady)
        if let frame = snapshot.lastFrameAt { lastFrameAt = frame }
    }
    func openSources() { refreshCaptureDevices(); sheet = .connection; Task { await refreshWireless() } }
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
    func openAdvanced(section: AdvancedSection = .workspace) { advancedSection = section; loadPrivateSettings(); sheet = .advanced }
    func restore(_ saved: SourceSetup) {
        let address = saved.kind == .network || saved.kind == .incoming ? SecureSettings.read(saved.credentialAccount) : nil
        if (saved.kind == .network || saved.kind == .incoming) && address == nil {
            error = "The saved address is unavailable. Reconnect this source in Advanced."
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
        busy = true; error = nil; permissionDenied = false; sheet = nil
        Task {
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
            }
            preparingConnection = true
            defer { preparingConnection = false }
            localPlayer.stop(); audiencePlayer.stop(); audiencePreviewPlaying = false
            if !changingSource {
                gateway.stop(); gatewayPort = nil; viewerURL = nil; viewers = []; sharingPower.hold(false)
                currentRuntime = nil
            }
            preview = nil; nativePreviewPlaying = false; sourceHasAudio = false; audienceHasAudio = false; testSoundConfirmed = false
            readiness = SetupReadiness(); setupConfirmed = false; lastFrameAt = nil; connectedAt = Date()
            rememberFailed = false
            setup = candidate; activeNetworkURL = address; rememberSetup = remember
            source = chosen
            do {
                let inputAddress = candidate.kind == .incoming ? networks.first(where: \.wireless)?.address ?? "127.0.0.1" : nil
                let snapshot: RuntimeSnapshot
                if changingSource { snapshot = try await runtime.replaceSource(chosen, inputAddress: inputAddress) }
                else { snapshot = try await runtime.prepare(source: chosen, viewerAddress: viewerAddress, inputAddress: inputAddress) }
                guard !shuttingDown else { return }
                apply(snapshot); publishGatewayState()
                if let destination = await runtime.incomingDestination() { incomingServer = destination.server; incomingStreamKey = destination.streamKey }
                let localURL = await runtime.localRTSP()
                let audienceURL = state.sharing ? await runtime.localRTSP("live") : nil
                guard !shuttingDown else { busy = false; return }
                try localPlayer.start(url: localURL)
                if let audienceURL { try audiencePlayer.start(url: audienceURL) }
                if restoreFloating { floating.show() }
                busy = false
                if candidate.kind == .incoming && candidate.confirmedAt == nil { sheet = .incoming }
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
                    if actual.session.monitoring {
                        let localURL = await runtime.localRTSP()
                        guard !shuttingDown else { return }
                        try? localPlayer.start(url: localURL)
                    }
                }
                self.error = state.sharing ? "The new input could not start. Viewers remain on Hold. Retry or return to the previous source." : "The connection could not start. Retry, or return to the previous source."
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
        } catch { rememberFailed = true; self.error = "Your picture is working, but Setbeam could not remember this connection. Retry saving in Advanced." }
    }
    func retry() {
        guard !busy else { return }; error = nil
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
        if let provenSetup { SecureSettings.remove(provenSetup.credentialAccount) }
        store.forget(); provenSetup = nil; rememberSetup = false
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
        rememberSetup = remember; setupConfirmed = false; readiness = SetupReadiness()
        rememberFailed = false
    }
    func startSharing() { guard !busy else { return }; Task { await startSharingNow() } }
    private func startSharingNow() async {
        guard !shuttingDown, state.monitoring, !state.sharing, (localReady || integration) else { return }
        busy = true; error = nil
        outgoingTransition.begin(.startSharing)
        do {
            await refreshNetworks()
            guard !shuttingDown else { busy = false; return }
            apply(try await runtime.startSharing())
            guard !shuttingDown else { busy = false; return }
            outgoingTransition.observeReady(outgoingReady)
            publishGatewayState()
            if gatewayPort == nil { gatewayPort = try await gateway.start(address: viewerAddress) }
            guard !shuttingDown else { busy = false; return }
            if let port = gatewayPort, let snapshot = currentRuntime { viewerURL = URL(string: "http://\(viewerAddress):\(port)/s/\(snapshot.guestToken)/") }
            let audienceURL = await runtime.localRTSP("live")
            guard !shuttingDown else { busy = false; return }
            try audiencePlayer.start(url: audienceURL)
            networkChanged = false; sharingPower.hold(true)
        } catch {
            guard !shuttingDown else { busy = false; return }
            gateway.stop(); gatewayPort = nil; viewerURL = nil; await runtime.stopSharing(); apply(await runtime.snapshot()); outgoingTransition.reset(); audiencePlayer.stop(); self.error = "Sharing could not start. Check the viewing network and try again."; lastRuntimeProblem = Redaction.text(error.localizedDescription)
        }
        busy = false; writeIntegrationSession()
    }
    func toggleHold() {
        guard state.sharing, !busy else { return }; busy = true
        let value = !state.holding
        guard value || localReady else { busy = false; error = "Wait for a fresh local picture before resuming sharing."; return }
        outgoingTransition.begin(value ? .hold : .resume)
        testSoundConfirmed = false
        Task {
            do {
                try await runtime.setHold(value)
                let snapshot = await runtime.snapshot()
                let audienceURL = await runtime.localRTSP("live")
                guard !shuttingDown else { busy = false; return }
                apply(snapshot)
                audiencePlayer.stop(); audiencePreviewPlaying = false
                try? audiencePlayer.start(url: audienceURL)
            }
            catch {
                guard !shuttingDown else { busy = false; return }
                apply(await runtime.snapshot()); outgoingTransition.reset(); self.error = "The audience change did not finish. Retry the audience control."; lastRuntimeProblem = Redaction.text(error.localizedDescription)
            }
            publishGatewayState()
            busy = false
        }
    }
    func stopSharing() {
        guard !busy else { return }; busy = true
        Task { await endSharing(); busy = false }
    }
    private func endSharing() async {
        sharingPower.hold(false)
        outgoingTransition.reset()
        audiencePlayer.stop(); audiencePreviewPlaying = false; audienceHasAudio = false; testSoundConfirmed = false
        await runtime.stopSharing()
        apply(await runtime.snapshot()); publishGatewayState()
    }
    private func publishGatewayState() {
        guard let snapshot = currentRuntime else { return }
        gateway.update(ViewerSession(token: snapshot.guestToken, title: title, sample: source == .sample, state: state.audience,
            playback: snapshot.audience, revision: snapshot.audienceRevision, wifiSSID: wifiSSID))
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
                guard !shuttingDown else { return }
                _ = try await gateway.start(address: address, port: port)
            } else { gateway.stop(); gatewayPort = nil; viewerURL = nil; viewers = [] }
            viewerNetworkNeedsUpdate = false
        }
        catch { lastRuntimeProblem = Redaction.text(error.localizedDescription) }
    }
    func saveViewingSettings(network: String, ssid: String, password: String) {
        let selectionChanged = network != networkChoice
        networkChoice = network; wifiSSID = ssid; wifiPassword = password
        if !integration {
            defaults.set(network, forKey: "viewerInterface"); defaults.set(ssid, forKey: "wifiSSID")
            do { if password.isEmpty { SecureSettings.remove("viewing-wifi-\(ssid)") } else { try SecureSettings.store(password, account: "viewing-wifi-\(ssid)") } }
            catch { self.error = "The viewing Wi-Fi password could not be saved." }
        }
        publishGatewayState()
        if selectionChanged { Task { if state.sharing { await endSharing(); networkChanged = true }; await refreshNetworks() } }
    }
    func setAudienceQuality(_ quality: AudienceQuality) {
        guard quality != audienceQuality else { return }
        audienceQuality = quality
        if !integration { defaults.set(quality.rawValue, forKey: "audienceQuality") }
        Task { await runtime.setAudienceQuality(quality) }
    }
    func togglePiP() { pipVisible ? floating.close() : floating.show() }
    func toggleLocalSound() {
        localMuted.toggle()
        if !integration { defaults.set(localMuted, forKey: "localMuted") }
    }
    func floatingVisibilityChanged(_ visible: Bool) {
        pipVisible = visible
        updateDisplayWake()
        if !integration && !shuttingDown { defaults.set(visible, forKey: "floatingVisible") }
    }
    func copyLink() {
        guard let viewerURL else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(viewerURL.absoluteString, forType: .string)
        copiedLink = true; Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copiedLink = false }
    }
    func loadPrivateSettings() {
        savedNetworkURL = activeNetworkURL ?? provenSetup.flatMap { $0.kind == .network ? SecureSettings.read($0.credentialAccount) : nil } ?? ""
        if !integration && !wifiSSID.isEmpty { wifiPassword = SecureSettings.read("viewing-wifi-\(wifiSSID)") ?? "" }
        refreshCaptureDevices()
    }
    func openWiFiSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!) }
    func openPrivacySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!) }
    func saveFrame() {
        guard localReady else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(title.isEmpty ? "Setbeam" : title)-frame.jpg"; panel.allowedContentTypes = [.jpeg]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { do { try await runtime.saveFrame(to: destination) } catch { self.error = "The frame could not be saved. Wait for the picture and try again." } }
    }
    func refreshCaptureDevices() { captureDevices = CaptureDiscovery.devices() }
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
        let previewVisible = pipVisible || NSApp.windows.contains {
            $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }
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
        floating.close(); localPlayer.stop(); audiencePlayer.stop(); gateway.stop(); sharingPower.hold(false); displayPower.hold(false)
        SessionLog.shared.record("app.quit", ["sharing": state.sharing])
        await runtime.shutdown(); apply(await runtime.snapshot())
    }
    private func writeIntegrationSession() {
        guard let viewerURL else { return }
        writeFile(option: "--session-file", value: ["viewerURL": viewerURL.absoluteString, "pid": ProcessInfo.processInfo.processIdentifier])
    }
    private func writeExperienceState() {
        writeFile(option: "--experience-file", value: ["monitoring": state.monitoring, "sharing": state.sharing, "holding": state.holding,
            "sourceAvailable": state.sourceAvailable, "nativePreviewPlaying": nativePreviewPlaying, "setupConfirmed": setupConfirmed,
            "sourceName": sourceLabel, "kind": setup?.kind.rawValue ?? "none", "savedSetupID": provenSetup?.id.uuidString ?? "",
            "floatingVisible": pipVisible, "localMuted": localMuted, "viewersOpened": openedViewers, "viewersPlaying": verifiedViewers,
            "status": statusLabel, "audience": state.audience.rawValue, "connectionStage": connectionStage?.rawValue ?? "",
            "audiencePreviewPlaying": audiencePreviewPlaying, "sourceHasAudio": sourceHasAudio, "audienceHasAudio": audienceHasAudio,
            "otherDeviceViewers": otherDeviceViewers, "setupCheckPassed": setupCheck.passed, "previousSource": previousSourceName ?? ""])
    }
    private func writeFile(option: String, value: [String: Any]) {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: option), index + 1 < args.count, let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        let destination = URL(fileURLWithPath: args[index+1]); try? data.write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
