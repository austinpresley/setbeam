import Foundation
import SwiftUI
import AppKit
import IOKit.pwr_mgt
import SetbeamCore

enum AppSheet: String, Identifiable { case connection, join, viewers, about; var id: String { rawValue } }
struct CaptureChoice: Identifiable { let id: Int; let name: String; let audio: Bool }

@MainActor final class SessionModel: ObservableObject {
    @Published var title: String { didSet { if !integration { defaults.set(title, forKey: "sessionTitle") }; publishGatewayState() } }
    @Published var state = SessionState()
    @Published var source: CameraSource = .sample
    @Published var preview: PlaybackDescriptor?
    @Published var viewerURL: URL?
    @Published var viewers: [ViewerActivity] = []
    @Published var busy = false
    @Published var error: String?
    @Published var localMuted = true { didSet { localPlayer.muted = localMuted } }
    let localPlayer = NativePreview()
    @Published var pipVisible = false
    @Published var sheet: AppSheet?
    @Published var networks: [NetworkAddress]
    @Published var viewerAddress: String
    @Published var wifiSSID: String
    @Published var wifiPassword = ""
    @Published var savedNetworkURL: String
    @Published var sourceKind: String
    @Published var captureVideo: Int
    @Published var captureAudio: Int
    @Published var captureAudioEnabled: Bool
    @Published var cameraSystem: String
    @Published var captureDevices: [CaptureChoice] = []
    @Published var listingDevices = false
    @Published var nativePreviewPlaying = false
    private var nativePreviewProblem: String?
    private let defaults: UserDefaults
    private let integration: Bool
    private let runtime = MediaRuntime(paths: AppAssets.runtimePaths)
    private let gateway = ViewerGateway(assets: AppAssets.viewerAssets)
    private var currentRuntime: RuntimeSnapshot?
    private var gatewayPort: UInt16?
    private var pollTask: Task<Void, Never>?
    private var launched = false
    private var powerAssertion: IOPMAssertionID = 0
    private lazy var floating = FloatingPreviewWindow(model: self)

    init() {
        integration = CommandLine.arguments.contains("--integration-demo")
        defaults = .standard
        title = defaults.string(forKey: "sessionTitle") ?? "Studio A"
        let availableNetworks = NetworkAddress.available() + [NetworkAddress(interface: "lo0", address: "127.0.0.1")]
        let preferredAddress = integration ? "127.0.0.1" : defaults.string(forKey: "viewerAddress") ?? availableNetworks.first?.address ?? "127.0.0.1"
        networks = availableNetworks
        viewerAddress = availableNetworks.contains(where: { $0.address == preferredAddress }) ? preferredAddress : availableNetworks.first?.address ?? "127.0.0.1"
        wifiSSID = defaults.string(forKey: "wifiSSID") ?? ""
        savedNetworkURL = defaults.string(forKey: "networkURL") ?? ""
        sourceKind = integration ? "sample" : defaults.string(forKey: "sourceKind") ?? "sample"
        captureVideo = defaults.integer(forKey: "captureVideo"); captureAudio = defaults.integer(forKey: "captureAudio")
        captureAudioEnabled = defaults.bool(forKey: "captureAudioEnabled")
        cameraSystem = defaults.string(forKey: "cameraSystem") ?? "Generic input"
        // Credentials are fetched only when the user opens connection settings or explicitly reconnects a saved input.
    }

    var sourceLabel: String { source == .sample ? "Sample camera · fictional studio portrait" : cameraSystem == "Generic input" ? source.label : cameraSystem }
    var viewerNetworkLabel: String { networks.first(where: { $0.address == viewerAddress })?.label ?? viewerAddress }
    var statusLabel: String {
        if busy { return "Connecting" }
        if let _ = error, !state.monitoring { return "Needs attention" }
        if state.sharing { switch state.audience { case .holding: return "On hold"; case .reconnecting: return "Reconnecting"; default: return "Sharing" } }
        return state.sourceAvailable ? "Preview only" : state.monitoring ? "Waiting for camera" : "Not connected"
    }
    var verifiedViewers: Int { viewers.filter(\.playing).count }

    func launch() {
        guard !launched else { return }; launched = true
        localPlayer.onPlaybackState = nativePlaybackState
        localPlayer.onSoundUnavailable = { [weak self] message in self?.localMuted = true; self?.error = message }
        connect()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.state.monitoring, !self.busy {
                    let snapshot = await self.runtime.snapshot(); self.currentRuntime = snapshot
                    self.preview = snapshot.preview; self.state.updateSource(available: snapshot.sourceAvailable)
                    self.localPlayer.checkHealth(sourceAvailable: snapshot.sourceAvailable)
                    self.viewers = self.gateway.viewers; self.publishGatewayState()
                    if let message = snapshot.message, !message.isEmpty { self.error = message }
                }
            }
        }
    }

    func connect(networkURL: String? = nil, remember: Bool = false) {
        guard !busy else { return }
        let chosen: CameraSource
        switch sourceKind {
        case "network":
            let address = networkURL ?? (defaults.bool(forKey: "rememberNetwork") ? SecureSettings.read("network-camera") : nil) ?? savedNetworkURL
            chosen = .network(address)
        case "capture": chosen = .capture(video: captureVideo, audio: captureAudioEnabled ? captureAudio : nil)
        default: chosen = .sample
        }
        do { _ = try chosen.validated() } catch { self.error = error.localizedDescription; return }
        busy = true; error = nil; sheet = nil
        Task {
            localPlayer.stop(); gateway.stop(); gatewayPort = nil; viewerURL = nil; viewers = []; preview = nil; state.end(); releasePowerAssertion()
            do {
                let snapshot = try await runtime.prepare(source: chosen, viewerAddress: viewerAddress)
                source = chosen; currentRuntime = snapshot; preview = snapshot.preview; state.beginMonitoring()
                try localPlayer.start(url: await runtime.localRTSP())
                if !integration {
                    defaults.set(sourceKind, forKey: "sourceKind"); defaults.set(viewerAddress, forKey: "viewerAddress")
                    defaults.set(cameraSystem, forKey: "cameraSystem"); defaults.set(wifiSSID, forKey: "wifiSSID")
                    defaults.set(captureVideo, forKey: "captureVideo"); defaults.set(captureAudio, forKey: "captureAudio"); defaults.set(captureAudioEnabled, forKey: "captureAudioEnabled")
                    if case .network(let address) = chosen {
                        savedNetworkURL = CameraSource.safeAddress(address); defaults.set(savedNetworkURL, forKey: "networkURL")
                        defaults.set(remember, forKey: "rememberNetwork")
                        if remember { try SecureSettings.store(address, account: "network-camera") }
                    }
                    if !wifiPassword.isEmpty { try SecureSettings.store(wifiPassword, account: "viewing-wifi-\(wifiSSID)") }
                }
                busy = false
                if integration { await startSharingNow(); writeIntegrationSession() }
            } catch { localPlayer.stop(); await runtime.shutdown(); busy = false; self.error = Redaction.text(error.localizedDescription); state.end(); preview = nil }
        }
    }

    func startSharing() { guard !busy else { return }; Task { await startSharingNow() } }
    private func startSharingNow() async {
        guard state.monitoring, !state.sharing else { return }
        busy = true; error = nil
        do {
            currentRuntime = try await runtime.startSharing(); try state.startSharing()
            publishGatewayState()
            if gatewayPort == nil { gatewayPort = try await gateway.start(address: viewerAddress) }
            if let port = gatewayPort, let snapshot = currentRuntime { viewerURL = URL(string: "http://\(viewerAddress):\(port)/s/\(snapshot.guestToken)/") }
            acquirePowerAssertion()
        } catch { await runtime.stopSharing(); state.stopSharing(); self.error = Redaction.text(error.localizedDescription) }
        busy = false
    }
    func toggleHold() {
        guard state.sharing, !busy else { return }
        busy = true
        let value = !state.holding
        Task {
            do { try await runtime.setHold(value); try state.setHold(value); publishGatewayState() }
            catch { self.error = Redaction.text(error.localizedDescription) }
            busy = false
        }
    }
    func stopSharing() {
        guard !busy else { return }; busy = true
        Task {
            // Tell existing pages to stop immediately; then revoke their media access.
            state.stopSharing(); publishGatewayState(); releasePowerAssertion()
            await runtime.stopSharing(); busy = false
        }
    }
    private func publishGatewayState() {
        guard let snapshot = currentRuntime else { return }
        gateway.update(ViewerSession(token: snapshot.guestToken, title: title, sample: source == .sample, state: state.audience, playback: snapshot.audience))
    }
    func togglePiP() { pipVisible ? floating.close() : floating.show() }
    func copyLink() { guard let viewerURL else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(viewerURL.absoluteString, forType: .string) }
    func loadPrivateSettings() {
        if defaults.bool(forKey: "rememberNetwork"), let value = SecureSettings.read("network-camera") { savedNetworkURL = value }
        if !wifiSSID.isEmpty { wifiPassword = SecureSettings.read("viewing-wifi-\(wifiSSID)") ?? "" }
        networks = NetworkAddress.available() + [NetworkAddress(interface: "lo0", address: "127.0.0.1")]
    }
    func saveFrame() {
        guard state.sourceAvailable else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(title.isEmpty ? "Setbeam" : title)-frame.jpg"; panel.allowedContentTypes = [.jpeg]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { do { try await runtime.saveFrame(to: destination) } catch { self.error = error.localizedDescription } }
    }
    func refreshCaptureDevices() {
        guard !listingDevices else { return }; listingDevices = true
        Task {
            defer { listingDevices = false }
            do {
                let listing = try await runtime.captureDeviceListing()
                let expression = try NSRegularExpression(pattern: #"\[(\d+)\]\s+(.+)$"#)
                var audio = false, devices: [CaptureChoice] = []
                for line in listing.components(separatedBy: .newlines) {
                    if line.lowercased().contains("video devices") { audio = false; continue }
                    if line.lowercased().contains("audio devices") { audio = true; continue }
                    guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                          let index = Range(match.range(at: 1), in: line), let name = Range(match.range(at: 2), in: line),
                          let id = Int(line[index]), !line[name].hasPrefix("Capture screen") else { continue }
                    devices.append(CaptureChoice(id: id, name: String(line[name]), audio: audio))
                }
                captureDevices = devices
            } catch { self.error = Redaction.text(error.localizedDescription) }
        }
    }
    func diagnostics() {
        Task {
            var data = await runtime.diagnosticStatus()
            data["nativePreviewPlaying"] = nativePreviewPlaying
            data["nativePreviewProblem"] = nativePreviewProblem.map(Redaction.text) ?? ""
            guard let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]), let text = String(data: encoded, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
    }
    func nativePlaybackState(_ playing: Bool, _ problem: String?) {
        if nativePreviewPlaying != playing { nativePreviewPlaying = playing }
        nativePreviewProblem = problem
    }
    private func acquirePowerAssertion() {
        guard powerAssertion == 0 else { return }
        _ = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Setbeam camera sharing" as CFString, &powerAssertion)
    }
    private func releasePowerAssertion() { if powerAssertion != 0 { IOPMAssertionRelease(powerAssertion); powerAssertion = 0 } }
    func shutdown() async {
        pollTask?.cancel(); floating.close(); localPlayer.stop(); gateway.stop(); releasePowerAssertion(); await runtime.shutdown(); state.end()
    }
    private func writeIntegrationSession() {
        let arguments = CommandLine.arguments
        guard let position = arguments.firstIndex(of: "--session-file"), position + 1 < arguments.count, let viewerURL else { return }
        let destination = URL(fileURLWithPath: arguments[position + 1])
        if let data = try? JSONSerialization.data(withJSONObject: ["viewerURL": viewerURL.absoluteString, "pid": ProcessInfo.processInfo.processIdentifier]) {
            try? data.write(to: destination, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }
}
