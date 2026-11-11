import AppKit
import SwiftUI
import SetbeamCore

struct SourceDetailsView: View {
    @ObservedObject var model: SessionModel
    @State private var draft: SourceDetailsDraft
    @State private var confirmReconnect = false

    init(model: SessionModel) {
        self.model = model
        _draft = State(initialValue: Self.values(model))
    }
    private static func values(_ model: SessionModel) -> SourceDetailsDraft {
        SourceDetailsDraft(name: model.setup?.name ?? "", audioID: model.setup?.audioID ?? "",
            remember: model.rememberSetup, screenRate: model.screenFrameRate,
            rejoin: model.transmitterRejoin, password: model.transmitterWiFiPassword,
            openNetwork: model.transmitterOpenNetwork)
    }
    private var changed: Bool { draft != Self.values(model) }
    private var editing: Binding<SourceDetailsDraft> {
        Binding(get: { draft }, set: { value in draft = value; model.sourceDetailsDirty = value != Self.values(model) })
    }
    private var audioAvailable: Bool { draft.audioID.isEmpty || model.captureDevices.contains { $0.audio && $0.id == draft.audioID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Source Details").font(.title2.weight(.semibold))
                Text(model.setup?.kind.detailsTitle ?? "No source selected").foregroundStyle(.secondary)
            }
            if let setup = model.setup {
                ViewThatFits(in: .vertical) {
                    details(setup).fixedSize(horizontal: false, vertical: true)
                    ScrollView { details(setup).padding(.trailing, 4) }
                }.frame(maxHeight: max(280, (NSScreen.main?.visibleFrame.height ?? 800) - 220))
                if changed {
                    Text("Changes are not applied until you save.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Choose a computer display, camera, or another source to monitor on this Mac.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Choose Another Source…") { model.openSources() }.buttonStyle(.link).disabled(changed)
                    .help(changed ? "Save or cancel these changes before choosing another source" : "Choose another computer display, camera, or video output")
                Spacer()
                if changed { Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction) }
                Button(changed ? "Save" : "Done", action: save)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!canSave || model.busy)
            }
        }.padding(24).frame(width: 480)
            .background(SourceDetailsFocusReset().frame(width: 0, height: 0))
            .onAppear { model.sourceDetailsDirty = changed }
            .onDisappear { model.sourceDetailsDirty = false }
            .onExitCommand { model.sheet = nil }
            .confirmationDialog("Reconnect this source and put viewers on Hold?", isPresented: $confirmReconnect, titleVisibility: .visible) {
                Button("Apply Sound Input and Close", action: commit)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The new sound input reconnects the source. Inspect the picture before resuming sharing.")
            }
    }

    private func details(_ setup: SourceSetup) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    if let device = setup.deviceName {
                        LabeledContent(setup.kind == .macWindow ? "Application" : setup.kind == .macScreen ? "Display" : "Input") {
                            Text(device).lineLimit(2).help(device).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    if setup.kind == .macWindow { LabeledContent("Window") { Text(model.windowTitle ?? setup.name).lineLimit(2).help(model.windowTitle ?? setup.name).frame(maxWidth: .infinity, alignment: .trailing) } }
                    if setup.kind == .sample { LabeledContent("Source name", value: setup.name) }
                    else { LabeledContent("Source name") { TextField("Source name", text: editing.name).labelsHidden().accessibilityLabel("Source name") } }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            } label: { Text("Source").font(.headline) }
            if setup.kind.isMacCapture {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Capture frame rate", selection: editing.screenRate) {
                            ForEach(VideoFrameRate.allCases, id: \.self) { rate in
                                Text(rate == .source ? (setup.kind == .macWindow ? "Match source, up to 30 fps" : "Match display") : rate.title).tag(rate)
                            }
                        }.accessibilityLabel("Capture frame rate")
                        Text("Applies to this Mac and the shared feed. Viewer frame rate can be lower.")
                            .font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Sound") { Text(setup.kind == .macWindow ? "No sound for application windows" : "No sound for display capture").frame(maxWidth: .infinity, alignment: .trailing) }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("Capture").font(.headline) }
            } else if setup.kind == .capture {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Sound input", selection: editing.audioID) {
                            Text("No sound").tag("")
                            ForEach(model.captureDevices.filter(\.audio)) { device in Text(device.name).tag(device.id) }
                            if !audioAvailable { Text("Selected input disconnected").tag(draft.audioID) }
                        }.accessibilityLabel("Sound input")
                        Text("Uses only the input you choose. Saving a different input reconnects this source and puts viewers on Hold.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("Sound input").font(.headline) }
            }
            if setup.kind == .accsoon {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        if let device = model.wirelessDevices.first(where: { $0.id == setup.wirelessUID }) {
                            LabeledContent("Transmission system", value: device.name)
                            LabeledContent("Firmware", value: device.firmwareLabel ?? "Unknown")
                        }
                        if !setup.sourceWiFi.isEmpty {
                            Toggle("Rejoin \(setup.sourceWiFi) automatically", isOn: editing.rejoin)
                            if draft.rejoin {
                                Toggle("This transmitter uses an open Wi-Fi network", isOn: editing.openNetwork)
                                if !draft.openNetwork { SecureField("Transmitter Wi-Fi password", text: editing.password) }
                                if draft.needsPassword(for: setup) {
                                    Text("Enter the transmitter's Wi-Fi password before saving.").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Text("Off by default. Location access is needed to read Wi-Fi names. Setbeam never switches networks while viewers depend on Wi-Fi.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let problem = model.rejoinProblem { Text(problem).font(.caption).foregroundStyle(.orange) }
                        }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("Transmitter").font(.headline) }
            }
            if setup.kind == .network {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Address", value: setup.networkAddress).textSelection(.enabled)
                        Button("Edit Stream Address…") { model.openNetworkSource() }.disabled(changed)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("Network source").font(.headline) }
            } else if setup.kind == .incoming {
                Button("Accsoon SEE Setup…") { model.present(.incoming) }.disabled(changed)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Remember after picture is confirmed", isOn: editing.remember)
                        .accessibilityLabel("Remember after picture is confirmed")
                    if !draft.remember && model.provenSetup?.id == setup.id {
                        Text("Saving will forget this source's saved connection. Local monitoring continues.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if model.rememberFailed {
                        Label("Couldn't save this connection", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("Try Again") { model.renameSource(model.setup?.name ?? "", remember: true); draft.remember = true }.disabled(changed)
                    } else {
                        Label(model.setupRemembered ? "Saved for next launch" : model.rememberSetup ? "Will save once the picture is confirmed" : "Not saved for next launch",
                              systemImage: model.setupRemembered ? "checkmark.circle" : "circle.dashed").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Sharing always starts off.").font(.caption).foregroundStyle(.secondary)
                    if let saved = model.provenSetup {
                        Button("Forget \(saved.name)") {
                            let current = saved.id == model.setup?.id
                            model.forgetSetup()
                            if current { draft.remember = false }
                            model.sourceDetailsDirty = changed
                        }
                            .lineLimit(2).help("Forget saved connection: \(saved.name)").disabled(changed)
                    }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            } label: { Text("Saved setup").font(.headline) }
        }
    }
    private var canSave: Bool {
        guard let setup = model.setup else { return true }
        return !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.needsPassword(for: setup) && (setup.kind != .capture || audioAvailable)
    }
    private func save() {
        guard canSave, !model.busy else { return }
        if let setup = model.setup, draft.reconnects(setup), model.state.sharing { confirmReconnect = true }
        else { commit() }
    }
    private func commit() {
        guard canSave, !model.busy, let setup = model.setup else { model.sheet = nil; return }
        guard let plan = draft.plan(for: setup, current: Self.values(model)) else { return }
        if let rejoin = plan.rejoin {
            guard model.setTransmitterRejoin(rejoin.enabled, password: rejoin.password, openNetwork: rejoin.openNetwork) else { return }
        }
        if let rate = plan.captureRate {
            model.setVideoSettings(quality: model.audienceQuality, frameRate: model.audienceFrameRate, screenRate: rate)
        }
        if plan.nameOrRememberChanged { model.renameSource(plan.source.name, remember: plan.remember) }
        if plan.reconnect { model.connect(plan.source, remember: plan.remember) }
        else { model.sheet = nil }
    }
}
struct NetworkSourceView: View {
    @ObservedObject var model: SessionModel
    @State private var address: String
    @State private var name: String
    @State private var sourceWiFi: String
    @State private var remember: Bool
    @State private var problem: String?
    @FocusState private var streamFocused: Bool

    init(model: SessionModel) {
        self.model = model
        let current = model.setup?.kind == .network
        _address = State(initialValue: model.savedNetworkURL)
        _remember = State(initialValue: model.rememberSetup)
        _name = State(initialValue: current ? model.setup?.name ?? "Network source" : "Network source")
        _sourceWiFi = State(initialValue: current ? model.setup?.sourceWiFi ?? "" : "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Enter Stream Address").font(.title2.weight(.semibold))
            Text("Receive a computer display, camera, or another output over RTSP.").foregroundStyle(.secondary)
            Form {
                TextField("Source name", text: $name)
                TextField("Stream address", text: $address, prompt: Text("rtsp://source:port/path")).focused($streamFocused).accessibilityLabel("Stream address")
                TextField("Source Wi-Fi", text: $sourceWiFi, prompt: Text("Optional, for reconnect guidance"))
                Toggle("Remember after picture is confirmed", isOn: $remember)
            }
            Text("Use a complete H.264 RTSP address. Saved addresses and credentials stay in Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            if model.state.sharing {
                Label("Connecting puts viewers on Hold. Resume after checking the new picture.", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Back to Sources") { model.openSources() }.keyboardShortcut("[", modifiers: .command)
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Connect", action: connect).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
            }
        }.padding(24).frame(width: 480).onAppear { streamFocused = true }.onExitCommand { model.sheet = nil }
    }
    private func connect() {
        do { _ = try VideoSource.network(address).validated() }
        catch { problem = error.localizedDescription; return }
        var setup = model.setup?.kind == .network && model.savedNetworkURL == address ? model.setup! : SourceSetup(kind: .network, name: name)
        setup.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Network source" : name
        setup.networkAddress = VideoSource.safeAddress(address); setup.sourceWiFi = sourceWiFi
        model.connect(setup, address: address, remember: remember)
    }
}


/// Opening details is not a typing task. Tab or a click can enter the source-name field.
private struct SourceDetailsFocusReset: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Anchor() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class Anchor: NSView {
        private weak var configuredWindow: NSWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, configuredWindow !== window else { return }
            configuredWindow = window
            DispatchQueue.main.async { [weak window] in window?.initialFirstResponder = nil; window?.makeFirstResponder(nil) }
        }
    }
}

private extension InputKind {
    var detailsTitle: String {
        switch self {
        case .sample: return "Sample feed"
        case .macScreen: return "This Mac's screen"
        case .macWindow: return "Application window"
        case .capture: return "Camera or capture device"
        case .network: return "Network stream"
        case .incoming: return "Incoming stream"
        case .accsoon: return "Wireless transmitter"
        }
    }
}

