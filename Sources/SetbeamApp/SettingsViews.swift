import SwiftUI
import AppKit
import SetbeamCore

struct HardwareArtwork: View {
    let symbol: String
    var size: CGFloat = 44
    var body: some View {
        Group {
            if symbol == "accsoon.master" {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).stroke(lineWidth: 1.6).frame(width: size * 0.42, height: size * 0.48).offset(y: size * 0.07)
                    HStack(spacing: size * 0.07) { ForEach(0..<4) { _ in Capsule().frame(width: size * 0.035, height: size * 0.22) } }.offset(y: -size * 0.25)
                    RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.5)).frame(width: size * 0.24, height: size * 0.11).offset(y: size * 0.05)
                }
            } else { Image(systemName: symbol).font(.system(size: size * 0.56, weight: .regular)) }
        }
            .foregroundStyle(.secondary).frame(width: size, height: size)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: size * 0.23))
            .accessibilityHidden(true)
    }
}

struct ConnectionView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject private var browser: SourceBrowser
    init(model: SessionModel) { self.model = model; browser = model.sourceBrowser }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose a source").font(.title2.weight(.semibold))
                    Text("A computer display, camera, or another video output.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(); Button("Done") { model.sheet = nil }.keyboardShortcut(.cancelAction)
            }
            if model.state.sharing {
                Label("Changing source puts viewers on Hold. Their link stays the same. Resume after checking the new picture.", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    if let saved = model.provenSetup {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Last working setup").font(.headline)
                            sourceRow(saved.name, detail: "Picture confirmed \(saved.confirmedAt?.formatted(date: .abbreviated, time: .shortened) ?? "previously")", symbol: symbol(for: saved.kind), action: { model.restore(saved) })
                        }
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Wireless transmitters").font(.headline)
                        if model.wirelessDevices.isEmpty && model.wirelessDiscoveryProblem == nil {
                            Text("Join the Wi-Fi shown on your transmitter's display. Its name will appear here automatically.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(model.wirelessDevices.filter(\.recognized)) { device in
                            sourceRow(device.name, detail: device.videoAvailable ? device.wifiName : "\(device.wifiName) · Waiting for a source picture", symbol: "accsoon.master") { model.connectWireless(device) }
                        }
                        ForEach(model.wirelessDevices.filter { !$0.recognized }) { device in
                            HStack(alignment: .top, spacing: 13) {
                                HardwareArtwork(symbol: "antenna.radiowaves.left.and.right")
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(device.wifiName.isEmpty ? "Accsoon transmitter found" : device.wifiName).font(.callout.weight(.medium))
                                    Text(device.productID == nil ? "Checking the transmitter model. You can choose another input while Setbeam checks." : "This transmitter model has not been verified. Choose a verified transmitter or a capture input.")
                                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }.padding(.vertical, 8).accessibilityElement(children: .combine)
                        }
                        if let problem = model.wirelessDiscoveryProblem { Text(problem).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Text("On this Mac").font(.headline)
                        if model.captureDevices.filter({ !$0.audio }).isEmpty {
                            HStack(alignment: .top, spacing: 13) {
                                HardwareArtwork(symbol: "cable.connector")
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Connect your input").font(.callout.weight(.medium))
                                    Text("Connect a camera by USB, or connect your receiver's HDMI or SDI output to a capture device on this Mac. The device will appear here.")
                                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }.padding(.vertical, 8)
                        }
                        ForEach(model.captureDevices.filter { !$0.audio }) { device in
                            sourceRow(device.name, detail: "Detected on this Mac", symbol: device.builtIn ? "video" : "externaldrive.connected.to.line.below") {
                                model.connect(SourceSetup(kind: .capture, name: device.name, videoID: device.id, deviceName: device.name))
                            }
                        }
                    }
                    if !browser.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("On your network").font(.headline)
                            ForEach(browser.sources) { device in
                                sourceRow(device.name, detail: "Advertised network video", symbol: "antenna.radiowaves.left.and.right") {
                                    model.connect(SourceSetup(kind: .network, name: device.name, networkAddress: device.address), address: device.address)
                                }
                            }
                        }
                    }
                    Divider()
                    sourceRow("Sample feed", detail: "Try Setbeam with sample video and a test tone", symbol: "play.rectangle") {
                        model.connect(SourceSetup(kind: .sample, name: "Sample feed"))
                    }
                }.padding(.trailing, 3)
            }.frame(maxHeight: 410)
            HStack {
                Button("Open Wi-Fi Settings") { model.openWiFiSettings() }.buttonStyle(.link)
                Spacer()
                Button("Advanced…") { model.openAdvanced() }
            }.font(.callout)
        }.padding(26).frame(width: 540)
        .task { model.refreshCaptureDevices(); browser.start() }
        .onDisappear { browser.stop(); model.stopWirelessScan() }
    }
    private func symbol(for kind: InputKind) -> String { kind == .sample ? "play.rectangle" : kind == .capture ? "video" : kind == .accsoon ? "accsoon.master" : "antenna.radiowaves.left.and.right" }
    private func sourceRow(_ name: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                HardwareArtwork(symbol: symbol)
                VStack(alignment: .leading, spacing: 4) { Text(name).font(.callout.weight(.medium)).foregroundStyle(.primary); Text(detail).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 8); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(12).contentShape(Rectangle())
        }.buttonStyle(.plain).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10)).accessibilityLabel("Connect \(name). \(detail)")
    }
}

struct AdvancedView: View {
    @ObservedObject var model: SessionModel
    @State private var address: String
    @State private var name: String
    @State private var title: String
    @State private var sourceWiFi: String
    @State private var network: String
    @State private var ssid: String
    @State private var password: String
    @State private var audio: String
    @State private var remember = true
    @State private var showStream = false
    @State private var validation: String?
    init(model: SessionModel) {
        self.model = model
        _address = State(initialValue: model.savedNetworkURL); _name = State(initialValue: model.setup?.name ?? "Network source")
        _title = State(initialValue: model.title); _sourceWiFi = State(initialValue: model.setup?.sourceWiFi ?? "")
        _network = State(initialValue: model.networkChoice); _ssid = State(initialValue: model.wifiSSID)
        _password = State(initialValue: model.wifiPassword); _audio = State(initialValue: model.setup?.audioID ?? "")
        _showStream = State(initialValue: model.setup?.kind == .network)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Advanced").font(.title2.weight(.semibold))
            ScrollViewReader { scroll in
                Form {
                    Section("Workspace") {
                        TextField("Feed name", text: $title)
                        if let setup = model.setup, setup.kind != .sample { TextField("Source name", text: $name) }
                        Toggle("Remember once a picture is confirmed", isOn: $remember)
                        if model.provenSetup != nil { Button("Forget saved connection") { model.forgetSetup(); remember = false } }
                    }.id(AdvancedSection.workspace)
                    Section("Connection") {
                        if model.setup?.kind == .accsoon, let device = model.wirelessDevices.first(where: { $0.id == model.setup?.wirelessUID }) {
                            LabeledContent("Transmission system", value: device.name)
                            LabeledContent("Firmware", value: device.firmwareLabel ?? "Unknown")
                        }
                        if model.setup?.kind == .incoming { Button("Accsoon SEE setup…") { model.sheet = .incoming } }
                        if model.setup?.kind != .incoming { Button("Set up a SEE stream bridge…") { model.prepareAccsoon() } }
                        DisclosureGroup("Network stream", isExpanded: $showStream) {
                            TextField("Source name", text: $name)
                            TextField("Stream address", text: $address, prompt: Text("rtsp://source:port/path"))
                            TextField("Source Wi-Fi", text: $sourceWiFi, prompt: Text("Optional, for reconnect guidance"))
                            Text("Use a complete H.264 RTSP address. Saved addresses and credentials stay in Keychain.").font(.caption).foregroundStyle(.secondary)
                            Button("Connect network source") { connectNetwork() }.disabled(address.isEmpty)
                        }
                        if model.setup?.kind == .capture {
                            Picker("Sound input", selection: $audio) {
                                Text("No sound").tag("")
                                ForEach(model.captureDevices.filter(\.audio)) { device in Text(device.name).tag(device.id) }
                            }
                            Text("Sound input is explicit. Setbeam never substitutes another microphone.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.id(AdvancedSection.connection)
                    Section("Viewer network") {
                        Picker("Connection", selection: $network) {
                            Text("Automatic").tag("automatic")
                            ForEach(model.networks, id: \.interface) { item in Text(item.label).tag(item.interface) }
                            Text("This Mac only").tag("lo0")
                        }
                        TextField("Wi-Fi name", text: $ssid, prompt: Text("Optional"))
                        SecureField("Wi-Fi password", text: $password)
                        Text("Wi-Fi details create a join code. Changing the viewer network stops sharing and keeps local monitoring running.").font(.caption).foregroundStyle(.secondary)
                    }.id(AdvancedSection.network)
                    Section("Diagnostics") {
                        Button(model.diagnosticCopied ? "Diagnostics copied" : "Copy diagnostics") { model.diagnostics() }
                        Text("Device detection does not establish transmitter compatibility. Physical connection tests are recorded separately.").font(.caption).foregroundStyle(.secondary)
                    }.id(AdvancedSection.diagnostics)
                }.formStyle(.grouped).frame(height: 430)
                    .onAppear { scroll.scrollTo(model.advancedSection, anchor: .top) }
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Spacer(); Button("Save") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 570)
    }
    private func connectNetwork() {
        do { _ = try VideoSource.network(address).validated() }
        catch { validation = error.localizedDescription; return }
        var setup = model.setup?.kind == .network && model.savedNetworkURL == address ? model.setup! : SourceSetup(kind: .network, name: name)
        setup.name = name.isEmpty ? "Network source" : name; setup.networkAddress = VideoSource.safeAddress(address); setup.sourceWiFi = sourceWiFi
        model.title = title.isEmpty ? "My feed" : title
        model.connect(setup, address: address, remember: remember)
    }
    private func save() {
        model.title = title.isEmpty ? "My feed" : title
        if network != model.networkChoice || ssid != model.wifiSSID || password != model.wifiPassword { model.saveViewingSettings(network: network, ssid: ssid, password: password) }
        if var setup = model.setup, setup.kind == .capture, setup.audioID != (audio.isEmpty ? nil : audio) {
            setup.audioID = audio.isEmpty ? nil : audio; setup.name = name
            model.connect(setup, remember: remember)
        } else { model.renameSource(name, remember: remember); model.sheet = nil }
    }
}

struct IncomingSetupView: View {
    @ObservedObject var model: SessionModel
    @State private var ssid = ""
    @State private var showDetails = false
    @State private var copied = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                HardwareArtwork(symbol: "antenna.radiowaves.left.and.right", size: 58)
                VStack(alignment: .leading, spacing: 5) { Text("CineView Master 4K").font(.title2.weight(.semibold)); Text("Connect through Accsoon SEE").font(.callout).foregroundStyle(.secondary) }
            }
            if model.localReady {
                Label("Picture confirmed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Your local monitor is ready. Sharing starts only when you choose Start sharing.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    step("wifi", "Join the transmitter's Wi-Fi", "Power the transmitter and connect its HDMI or SDI input. Join the 5 GHz Wi-Fi shown on its display, usually Accsoon_ followed by the unit's four characters.")
                    TextField("Wi-Fi name", text: $ssid, prompt: Text("Optional. Remember the name for next time.")).textFieldStyle(.roundedBorder)
                    Button("Open Wi-Fi Settings") { model.openWiFiSettings() }.buttonStyle(.link)
                    step("play.rectangle", "Open your picture in Accsoon SEE", "Choose CineView Master 4K and start monitoring. A picture in SEE confirms the transmitter connection first.")
                    step("arrow.down.to.line", "Send the picture to Setbeam", "In SEE's Control Center, choose Push Stream, select RTMP, and use the connection details below. Then start streaming.")
                }
            }
            DisclosureGroup("Advanced connection details", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Paste these into Accsoon SEE. Keep the stream key private.").font(.caption).foregroundStyle(.secondary)
                    HStack { Text(model.incomingServer).font(.callout).textSelection(.enabled); Spacer(); Button(copied == "server" ? "Copied" : "Copy server") { copy(model.incomingServer, label: "server") } }
                    HStack { Text("Private stream key").font(.callout); Spacer(); Button(copied == "key" ? "Copied" : "Copy stream key") { copy(model.incomingStreamKey, label: "key") } }
                    if model.viewerAddress == "127.0.0.1" { Text("The destination currently works on this Mac only. Join the transmitter's network to receive a stream from another device.").font(.caption).foregroundStyle(.secondary) }
                }.padding(.top, 10)
            }
            Text("This is a candidate connection route. Receiving sample video does not establish CineView hardware compatibility.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose another source") { model.openSources() }
                Spacer(); Button("Done") { model.rememberSourceWiFi(ssid); model.sheet = nil }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 550).onAppear { ssid = model.setup?.sourceWiFi ?? "" }
    }
    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 25)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.callout.weight(.medium)); Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func copy(_ value: String, label: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string); copied = label
    }
}

struct JoinCodesView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Join the feed").font(.title2.weight(.semibold))
            if let url = model.viewerURL, model.state.sharing {
                HStack(alignment: .top, spacing: 28) {
                    if !model.wifiSSID.isEmpty {
                        VStack(spacing: 13) { Text("1. Join Wi-Fi").font(.headline); QRView(payload: QRCode.wifi(ssid: model.wifiSSID, password: model.wifiPassword), size: 190); Text(model.wifiSSID).font(.caption).foregroundStyle(.secondary) }
                    }
                    VStack(spacing: 13) { Text(model.wifiSSID.isEmpty ? "Scan to watch" : "2. Watch the feed").font(.headline); QRView(payload: url.absoluteString, size: 190); Text(model.title).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity)
                Text(model.viewerAddress == "127.0.0.1" ? "This link works on this Mac only. Join a local network to invite phones." : model.viewingInstructions)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(model.wifiSSID.isEmpty ? "Add a Wi-Fi join code" : "Edit viewing Wi-Fi") { model.loadPrivateSettings(); model.sheet = .viewingWiFi }.buttonStyle(.link)
                Text("\(model.openedViewers) opened · \(model.verifiedViewers) playing").font(.caption).foregroundStyle(.secondary)
            } else { Text("Start sharing to invite viewers. Your local preview stays private.").foregroundStyle(.secondary) }
            HStack {
                Button(model.copiedLink ? "Link copied" : "Copy viewing link") { model.copyLink() }.disabled(!model.state.sharing)
                Spacer(); Button("Done") { model.sheet = nil }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: model.wifiSSID.isEmpty ? 355 : 480)
    }
}

struct ViewingWiFiView: View {
    @ObservedObject var model: SessionModel
    @State private var ssid: String
    @State private var password: String
    init(model: SessionModel) {
        self.model = model; _ssid = State(initialValue: model.wifiSSID); _password = State(initialValue: model.wifiPassword)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Wi-Fi for viewers").font(.title2.weight(.semibold))
            Text("Use the Wi-Fi connected to this Mac's viewing network. These details let viewers join by scanning a code.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form { TextField("Wi-Fi name", text: $ssid); SecureField("Password", text: $password) }
            Text("Leave the password empty for an open network. Saving a join code keeps the current feed and viewing link running.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Back") { model.sheet = .join }.keyboardShortcut(.cancelAction)
                Spacer(); Button("Save") { model.saveViewingSettings(network: model.networkChoice, ssid: ssid, password: password); model.sheet = .join }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(ssid.utf8.count > 32)
            }
        }.padding(26).frame(width: 410)
    }
}

struct ViewerStatusView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Picture and viewers").font(.title2.weight(.semibold))
            statusRow(model.localReady ? "Your picture is playing" : model.recoveryTitle, detail: model.setup?.kind == .sample ? "Sample media. No physical source connected." : model.hardwareLabel, good: model.localReady)
            statusRow(model.audienceLabel, detail: model.state.holding ? "Viewers receive a holding picture and silence. Your monitor continues." : model.state.sharing ? "\(model.openedViewers) opened · \(model.verifiedViewers) playing" : "Start sharing when you are ready to invite viewers.", good: model.state.audience == .live)
            ForEach(model.viewers) { viewer in statusRow(viewer.label + (viewer.onThisMac ? " · This Mac" : " · Another device"), detail: viewer.playing ? "Fresh video playback confirmed" : "Link opened. Waiting for a picture.", good: viewer.playing) }
            if model.state.sharing && model.viewers.isEmpty { Text("Ask a viewer to scan the code. Playback is confirmed when their browser receives fresh video.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("Done") { model.sheet = nil }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 440)
    }
    private func statusRow(_ title: String, detail: String, good: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) { Image(systemName: good ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(good ? .green : .secondary); VStack(alignment: .leading, spacing: 3) { Text(title); Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }
    }
}

struct AboutView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                Image(nsImage: AppAssets.icon ?? NSApplication.shared.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                Text("Setbeam").font(.title2.weight(.semibold))
            }
            Text("Monitor and share video feeds.")
            Text("Developer build. Physical hardware compatibility remains under test.").font(.caption).foregroundStyle(.secondary)
            Text("Based on Holly Share by Faini Made. Includes MediaMTX, FFmpeg, and Opus. Bundled notices include licenses, versions, build information, and sources.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Button("Open source notices") { NSWorkspace.shared.open(AppAssets.root.appendingPathComponent("Licenses")) }; Spacer(); Button("Done") { model.sheet = nil }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 420)
    }
}
