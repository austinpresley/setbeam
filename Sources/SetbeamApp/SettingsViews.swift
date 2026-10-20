import SwiftUI
import AppKit
import SetbeamCore

struct ConnectionView: View {
    @ObservedObject var model: SessionModel
    @State private var kind: String
    @State private var address: String
    @State private var remember: Bool
    @State private var viewerAddress: String
    @State private var ssid: String
    @State private var password: String
    @State private var title: String
    @State private var system: String
    @State private var video: Int
    @State private var audio: Int
    init(model: SessionModel) {
        self.model = model
        _kind = State(initialValue: model.sourceKind); _address = State(initialValue: model.savedNetworkURL)
        _remember = State(initialValue: UserDefaults.standard.bool(forKey: "rememberNetwork"))
        _viewerAddress = State(initialValue: model.viewerAddress); _ssid = State(initialValue: model.wifiSSID); _password = State(initialValue: model.wifiPassword)
        _title = State(initialValue: model.title); _system = State(initialValue: model.transmissionSystem)
        _video = State(initialValue: model.captureVideo); _audio = State(initialValue: model.captureAudioEnabled ? model.captureAudio : -1)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect a source").font(.title2.weight(.semibold))
            Form {
                TextField("Session name", text: $title)
                Picker("Input", selection: $kind) {
                    Text("Sample").tag("sample"); Text("Network stream").tag("network"); Text("USB / capture").tag("capture")
                }.pickerStyle(.segmented)
                if kind == "sample" { Text("A generated sample portrait and test tone exercise the real media pipeline. No external source is connected.").font(.caption).foregroundStyle(.secondary) }
                if kind == "network" {
                    TextField("Stream address", text: $address, prompt: Text("rtsp://source-address:port/path")).textFieldStyle(.roundedBorder)
                    Toggle("Remember the complete address securely in Keychain", isOn: $remember).font(.caption)
                    Text("Use a verified H.264 RTSP feed. A transmitter working in its vendor app does not establish its RTSP address.").font(.caption).foregroundStyle(.secondary)
                }
                if kind == "capture" {
                    Picker("Video device", selection: $video) { ForEach(model.captureDevices.filter { !$0.audio }) { device in Text(device.name).tag(device.id) } }
                    Picker("Audio device", selection: $audio) { Text("No audio").tag(-1); ForEach(model.captureDevices.filter(\.audio)) { device in Text(device.name).tag(device.id) } }
                    HStack { Button("Refresh devices") { model.refreshCaptureDevices() }; if model.listingDevices { ProgressView().controlSize(.small) } }
                    Text("Connect a compatible capture device to a receiver, computer display output, or camera. Camera and microphone permission may be required.").font(.caption).foregroundStyle(.secondary)
                }
                if kind != "sample" {
                    Picker("Transmission system", selection: $system) { ForEach(["Generic input", "Hollyland Mars 300", "Hollyland Mars 300 Pro", "Accsoon CineView Master 4K"], id: \.self) { Text($0).tag($0) } }
                    Text("These model profiles are test targets. Direct wireless compatibility has not been verified.").font(.caption).foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 5)
                Picker("Viewers connect through", selection: $viewerAddress) { ForEach(model.networks) { network in Text(network.label).tag(network.address) } }
                TextField("Viewing Wi-Fi name", text: $ssid, prompt: Text("Optional"))
                SecureField("Wi-Fi password", text: $password, prompt: Text("Leave empty for an open network"))
                Text("Wi-Fi details create a join QR code. They do not change the Mac's network. Saved passwords use Keychain.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            if model.state.sharing { Text("Connecting starts a new session and ends the current viewing link.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect") {
                    model.sourceKind = kind; model.viewerAddress = viewerAddress; model.wifiSSID = ssid; model.wifiPassword = password
                    model.title = title.isEmpty ? "Feed" : title; model.transmissionSystem = system; model.captureVideo = video; model.captureAudio = max(0, audio); model.captureAudioEnabled = audio >= 0
                    model.connect(networkURL: address, remember: remember)
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(kind == "network" && address.isEmpty || kind == "capture" && model.captureDevices.filter({ !$0.audio }).isEmpty)
            }
        }.padding(24).frame(width: 560).task(id: kind) { if kind == "capture" { model.refreshCaptureDevices() } }
    }
}

struct JoinCodesView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Join the feed").font(.title2.weight(.semibold))
            if let url = model.viewerURL {
                HStack(alignment: .top, spacing: 28) {
                    if !model.wifiSSID.isEmpty { VStack(spacing: 13) { Text("1. Join Wi-Fi").font(.headline); QRView(payload: QRCode.wifi(ssid: model.wifiSSID, password: model.wifiPassword), size: 190); Text(model.wifiSSID).font(.caption).foregroundStyle(.secondary) } }
                    VStack(spacing: 13) { Text(model.wifiSSID.isEmpty ? "Scan to watch" : "2. Watch the feed").font(.headline); QRView(payload: url.absoluteString, size: 190); Text(model.title).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity)
                if model.wifiSSID.isEmpty { Text("Viewers must be on the same reachable network as this Mac. Add optional Wi-Fi join details in connection settings.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            HStack { Button("Copy viewing link") { model.copyLink() }; Spacer(); Button("Done") { model.sheet = nil }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: model.wifiSSID.isEmpty ? 340 : 475)
    }
}

struct ViewerStatusView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connection status").font(.title2.weight(.semibold))
            statusRow(model.state.sourceAvailable ? "Feed received" : "Waiting for source", detail: model.source == .sample ? "Sample input, not a physical source test" : "The selected input on this Mac", good: model.state.sourceAvailable)
            if model.viewers.isEmpty { statusRow("No audience playback yet", detail: "Open the viewing link in a separate phone or browser.", good: false) }
            ForEach(model.viewers) { viewer in statusRow(viewer.label, detail: viewer.playing ? "Video playback confirmed" : "Connected; waiting for picture", good: viewer.playing) }
            Text("A playable preview on the Mac does not confirm phone reachability. Your first viewer confirms the second part of the connection.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Button("Copy diagnostics") { model.diagnostics() }; Spacer(); Button("Done") { model.sheet = nil }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 420)
    }
    private func statusRow(_ title: String, detail: String, good: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) { Image(systemName: good ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(good ? .green : .secondary); VStack(alignment: .leading, spacing: 3) { Text(title); Text(detail).font(.caption).foregroundStyle(.secondary) } }
    }
}

struct AboutView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Setbeam").font(.title2.weight(.semibold))
            Text("Monitor and share video feeds.")
            Text("Developer prototype. Hardware compatibility remains under test.").font(.caption).foregroundStyle(.secondary)
            Text("Based on Holly Share by Faini Made. Includes MediaMTX, FFmpeg, and Opus. The bundled notices include their licenses, versions, build information, and source links.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Button("Open source notices") { NSWorkspace.shared.open(AppAssets.root.appendingPathComponent("Licenses")) }; Spacer(); Button("Done") { model.sheet = nil }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 420)
    }
}
