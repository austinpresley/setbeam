import AppKit
import AVFoundation
import SwiftUI
import SetbeamCore

struct ConnectionView: View {
    @ObservedObject var model: SessionModel
    let width: CGFloat
    let availableHeight: CGFloat
    @ObservedObject private var browser: SourceBrowser
    @StateObject private var displayPreviews = DisplaySourcePreviews()
    @StateObject private var windowPreviews: WindowSourcePreviews
    @State private var category: SourceCategory
    @State private var query = ""
    @State private var guide: TransmitterModel?
    @State private var contentHeight: CGFloat = 0
    @FocusState private var searchFocused: Bool

    init(model: SessionModel, width: CGFloat, availableHeight: CGFloat) {
        self.model = model; self.width = width; self.availableHeight = availableHeight
        browser = model.sourceBrowser
        _category = State(initialValue: model.sourceCategory ?? SourceCategory.initial(for: model.setup ?? model.provenSetup))
        let bundles = model.windowListBundle.map { Set($0.split(separator: ",").map(String.init)) }
        _windowPreviews = StateObject(wrappedValue: bundles == nil ? WindowSourcePreviews() : WindowSourcePreviews(list: {
            try await MacWindow.shareable().filter { bundles?.contains($0.window.bundleIdentifier ?? "") == true }.map { ($0.window, $0.handle) }
        }))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(SourceCategory.allCases) { item in categoryButton(item) }
                Spacer(minLength: 4)
                if model.state.sharing {
                    Label("Viewers hold", systemImage: "pause.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(SetbeamChrome.amberText)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(SetbeamChrome.amber.opacity(0.16), in: Capsule())
                        .help("Changing source puts viewers on Hold. Resume after checking the new picture.")
                        .accessibilityLabel("Changing source puts viewers on Hold")
                }
                ChromeIconButton("Close source chooser", symbol: "xmark") { model.sheet = nil }
            }.padding(16)
            Divider()
            categoryContent.frame(height: bodyHeight)
        }
        .frame(width: width)
        .background(SetbeamChrome.raised)
        .accessibilityElement(children: .contain).accessibilityLabel("Choose a source")
        .task { model.refreshCaptureDevices() }
        .task(id: category) {
            guard category == .wireless else { return }
            browser.start { model.canDiscoverPyroH }
            await model.refreshWireless()
        }
        .task(id: model.screenDisplays.map(\.id) + [monitoredDisplayID ?? "", category.rawValue]) {
            while !Task.isCancelled {
                await displayPreviews.refresh(displays: category == .displays ? model.screenDisplays : [], monitoredDisplayID: monitoredDisplayID)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .task(id: category) {
            while !Task.isCancelled {
                await windowPreviews.refresh(permitted: displayPreviews.permissionGranted, monitored: monitoredWindow, captureVisible: category == .windows)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onChange(of: category) { _, value in
            guide = nil; query = ""; searchFocused = false; contentHeight = 0
            if value != .wireless { browser.stop(); model.stopWirelessScan() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in model.refreshCaptureDevices() }
        .onDisappear { displayPreviews.clear(); windowPreviews.clear(); browser.stop(); model.stopWirelessScan() }
    }

    private var bodyHeight: CGFloat {
        let extra: CGFloat = category == .windows ? 80 : category == .displays ? 32 : 0
        let measured = contentHeight > 0 ? contentHeight + 40 + extra : 240
        return min(max(category == .windows ? 300 : 224, measured), availableHeight)
    }

    private func categoryButton(_ item: SourceCategory) -> some View {
        Button { category = item } label: {
            VStack(spacing: 4) {
                Image(systemName: item.symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 22))
                    .frame(width: 32, height: 28)
                Text(item.tabName).font(.caption.weight(.medium))
            }
            .foregroundStyle(category == item ? Color.white : .secondary)
            .frame(width: 88, height: 56)
            .background(category == item ? SetbeamChrome.blue : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }.buttonStyle(SourceChoiceStyle()).help(item.name)
            .accessibilityAddTraits(category == item ? .isSelected : [])
    }

    @ViewBuilder private var categoryContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if category == .windows {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find an application or window", text: $query).textFieldStyle(.plain).focused($searchFocused)
                        .accessibilityLabel("Find an application or window")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
                    }
                }.padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.15), lineWidth: 1) }
            }
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch category {
                        case .displays: displaySection
                        case .cameras: cameraSection
                        case .windows: windowSection
                        case .wireless: wirelessSection
                        }
                        if let saved = model.provenSetup, saved.kind != .sample { lastConnection(saved) }
                    }.frame(maxWidth: .infinity, alignment: .leading).id("source-top")
                        .background {
                            GeometryReader { proxy in Color.clear.preference(key: SourceChooserContentHeight.self, value: proxy.size.height) }
                        }
                }
                .modifier(SourceChooserScrollHeight(height: $contentHeight))
                .onChange(of: category) { _, _ in scroll.scrollTo("source-top", anchor: .top) }
                .onChange(of: guide) { _, _ in scroll.scrollTo("source-top", anchor: .top) }
            }
            if category == .windows {
                Text("Only the chosen window is captured. No audio.").font(.caption).foregroundStyle(.secondary)
            } else if category == .displays {
                Text("The entire display is captured, including other apps. No audio.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Displays").font(.headline)
            if !displayPreviews.permissionGranted { screenPermission }
            if model.screenDisplays.isEmpty {
                emptyState("No displays found", detail: "Connect a display to choose it here.", symbol: "display")
            }
            ForEach(model.screenDisplays) { display in
                let current = display.id == monitoredDisplayID
                sourceRow(display.name, detail: "Entire display · \(display.width) × \(display.height)", symbol: "display", current: current, display: display) {
                    if current { model.sheet = nil }
                    else { model.connect(SourceSetup(kind: .macScreen, name: "This Mac's screen · \(display.name)", videoID: display.id, deviceName: display.name)) }
                }
            }
        }
    }

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cameras & capture").font(.headline)
            let devices = model.captureDevices.filter { !$0.audio }
            if devices.isEmpty {
                emptyState("No cameras or capture devices found", detail: "Connect a USB camera or capture device. To receive HDMI or SDI, connect it through a capture device.", symbol: "camera")
            }
            ForEach(devices) { device in
                let setup = SourceSetup(kind: .capture, name: device.name, videoID: device.id, deviceName: device.name)
                let current = model.state.monitoring && model.setup?.kind == .capture && model.setup?.videoID == device.id
                sourceRow(device.name, detail: device.builtIn ? "Built-in camera" : "Camera or capture input", symbol: device.builtIn ? "video" : "externaldrive.connected.to.line.below", current: current) {
                    if current { model.sheet = nil } else { model.connect(setup) }
                }
            }
        }
    }

    @ViewBuilder private var windowSection: some View {
        if !displayPreviews.permissionGranted {
            screenPermission
        } else if !windowPreviews.loaded {
            Label("Looking for windows…", systemImage: "macwindow").foregroundStyle(.secondary)
        } else if windowPreviews.listFailed {
            emptyState("Unable to list windows", detail: "Check Screen Recording access in Privacy & Security, then reopen Choose a source.", symbol: "exclamationmark.triangle")
        } else if windowPreviews.windows.isEmpty {
            emptyState("No application windows found", detail: "Open and show the window you want to share. Minimized windows and hidden applications do not appear here.", symbol: "macwindow")
        } else {
            let groups = WindowApplicationGroup.grouping(windowPreviews.windows)
            if groups.allSatisfy({ $0.matching(query).isEmpty }) {
                emptyState("No matching windows", detail: "Try another application name or window title.", symbol: "magnifyingglass")
            }
            ForEach(groups) { application in
                let windows = application.matching(query)
                if !windows.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            applicationIcon(application.windows.first, size: 32)
                            Text(application.name).font(.title3.weight(.semibold)).lineLimit(1).help(application.name)
                            Spacer(minLength: 8)
                            Text(windows.count == 1 ? "1 window" : "\(windows.count) windows").font(.callout).foregroundStyle(.secondary)
                        }.accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(windows) { window in windowCard(window, detail: application.detail(for: window)) }
                        }
                    }
                }
            }
        }
    }

    private var screenPermission: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Allow Screen Recording", systemImage: "lock.display").font(.headline)
            Text("Setbeam needs access to capture the display or window you choose and show its preview.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Allow Screen Recording…") { displayPreviews.enable() }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var wirelessSection: some View {
        if let guide {
            TransmitterGuideView(model: model, browser: browser, transmitter: guide) { self.guide = nil }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(TransmitterModel.allCases) { transmitter in
                    let status = transmitterStatus(transmitter)
                    let selected = transmitter == .cineViewMaster4K ? model.setup?.kind == .accsoon : model.setup?.networkProfile == .pyroH
                    TransmitterCard(transmitter: transmitter, status: status.text, found: status.found, selected: selected) { guide = transmitter }
                }
                Button { model.openNetworkSource() } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "link").font(.system(size: 30))
                        Text("Stream address").font(.callout.weight(.medium))
                        Text("rtsp://").font(.system(.caption, design: .monospaced))
                    }.foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: TransmitterCard.height)
                        .contentShape(Rectangle())
                }.buttonStyle(SourceChoiceStyle())
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 4])).allowsHitTesting(false) }
                    .help("Enter the RTSP address of a network stream")
            }
            if !browser.sources.isEmpty {
                Text("Network streams").font(.headline)
                ForEach(browser.sources) { device in
                    sourceRow(device.name, detail: "Advertised network stream", symbol: "network") {
                        model.connect(SourceSetup(kind: .network, name: device.name, networkAddress: device.address), address: device.address)
                    }
                }
            }
        }
    }

    private func transmitterStatus(_ transmitter: TransmitterModel) -> (text: String, found: Bool) {
        switch transmitter {
        case .cineViewMaster4K:
            if model.setup?.kind == .accsoon && model.state.monitoring { return (model.localReady ? "Monitoring" : "Waiting", model.localReady) }
            let count = model.wirelessDevices.filter(\.recognized).count
            return count == 0 ? ("Join Wi-Fi", false) : ("Found", true)
        case .pyroH:
            if model.setup?.networkProfile == .pyroH && model.state.monitoring { return (model.localReady ? "Monitoring" : "Waiting", model.localReady) }
            return browser.pyroHSources.isEmpty ? ("Join Wi-Fi", false) : ("Found", true)
        }
    }

    private func windowCard(_ window: MacWindow, detail: String?) -> some View {
        let current = window.identity == monitoredWindow
        return Button {
            if current { model.sheet = nil } else { model.connectWindow(window) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                WindowSourceThumbnail(previews: windowPreviews, player: model.localPlayer, window: window, monitored: current, pictureReady: model.localReady)
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(window.label).font(.callout.weight(.medium)).foregroundStyle(.primary)
                            .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                        Text(detail ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if current {
                        Label { Text(model.localReady ? "Monitoring" : "Waiting for picture").foregroundStyle(.primary) }
                            icon: { Image(systemName: model.localReady ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(model.localReady ? .green : .secondary) }
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(SourceChoiceStyle())
            .background(.quaternary.opacity(current ? 0.12 : 0.2), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(current ? Color.accentColor : .primary.opacity(0.12), lineWidth: 1) }
            .help("\(window.applicationName) · \(window.label)\n\(window.width) × \(window.height) · No audio")
            .accessibilityLabel("\(current ? "Current source" : "Connect window"): \(window.label), \(window.applicationName)\(detail.map { ", \($0)" } ?? "")")
            .accessibilityAddTraits(current ? .isSelected : [])
            .onAppear { windowPreviews.appeared(window.identity) }
            .onDisappear { windowPreviews.disappeared(window.identity) }
    }

    private func sourceRow(_ name: String, detail: String, symbol: String, current: Bool = false, display: MacDisplay? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let display {
                    DisplaySourceThumbnail(previews: displayPreviews, player: model.localPlayer, display: display, monitored: current, pictureReady: model.localReady)
                } else { HardwareArtwork(symbol: symbol, size: 48) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                    Text(current ? "Current source" : detail).font(.caption).foregroundStyle(current ? Color.accentColor : .secondary)
                }.help(name)
                Spacer(minLength: 8)
                Image(systemName: current ? "checkmark.circle.fill" : "chevron.right").foregroundStyle(current ? Color.accentColor : .secondary)
            }.padding(12).contentShape(Rectangle())
        }.buttonStyle(SourceChoiceStyle()).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("\(current ? "Current source" : "Connect") \(name). \(detail)")
    }

    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func applicationIcon(_ window: MacWindow?, fallback: MacWindowIdentity? = nil, size: CGFloat) -> some View {
        if let identity = window?.identity ?? fallback,
           window != nil || MacProcess.startTime(identity.processID) == identity.processStart,
           let icon = windowPreviews.icons[identity.processID] ?? NSRunningApplication(processIdentifier: identity.processID)?.icon {
            Image(nsImage: icon).resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
        } else { HardwareArtwork(symbol: "app", size: size) }
    }

    private func lastConnection(_ saved: SourceSetup) -> some View {
        let current = model.state.monitoring && SourceChooserSelection.matches(saved, model.setup)
        let availability = lastAvailability(saved, current: current)
        let window = windowPreviews.windows.first { $0.identity == saved.window }
        return HStack(spacing: 16) {
            Text("Last connected").font(.callout).foregroundStyle(.secondary)
            Divider().frame(height: 32)
            if saved.kind == .macWindow { applicationIcon(window, fallback: saved.window, size: 32) }
            else { HardwareArtwork(symbol: SourceCategory.initial(for: saved).symbol, size: 32) }
            VStack(alignment: .leading, spacing: 4) {
                Text(SourceChooserSelection.name(for: saved, window: window)).font(.callout.weight(.semibold)).lineLimit(1).help(saved.name)
                Text(lastDetail(saved)).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(lastDetail(saved))
            }
            Spacer(minLength: 8)
            Label {
                Text(availability.text).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: availability.available ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(availability.available ? .green : .secondary)
            }.font(.caption)
            if !current {
                Button("Reconnect") { model.restore(saved) }.disabled(model.busy || availability.unavailable)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private func lastDetail(_ saved: SourceSetup) -> String {
        let kind = saved.kind == .macWindow ? saved.deviceName ?? "Application window" : SourceCategory.initial(for: saved).name
        guard let date = saved.confirmedAt else { return kind }
        return "\(kind) · Used \(date.formatted(.relative(presentation: .named)))"
    }

    private func lastAvailability(_ saved: SourceSetup, current: Bool) -> (text: String, available: Bool, unavailable: Bool) {
        if current {
            if saved.kind == .macWindow, model.windowPresence == .closed { return ("Window closed", false, false) }
            if saved.kind == .macWindow, model.windowPresence == .hidden { return ("Show this window", false, false) }
            return (model.localReady ? "Monitoring" : "Waiting for picture", model.localReady, false)
        }
        switch saved.kind {
        case .macWindow:
            guard let identity = saved.window else { return ("Window closed", false, true) }
            switch MacWindowLocator.status(of: identity).presence {
            case .closed: return ("Window closed", false, true)
            case .hidden: return ("Show this window", false, false)
            case .visible: return (displayPreviews.permissionGranted ? "Available" : "Needs permission", displayPreviews.permissionGranted, false)
            }
        case .macScreen:
            let found = model.screenDisplays.contains { $0.id.caseInsensitiveCompare(saved.videoID ?? "") == .orderedSame }
            let permitted = displayPreviews.permissionGranted
            return (found ? (permitted ? "Available" : "Needs permission") : "Display disconnected", found && permitted, !found)
        case .capture:
            return SourceChooserAvailability.capture(saved, devices: model.captureDevices,
                cameraAllowed: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                microphoneAllowed: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        case .accsoon:
            let found = model.wirelessDevices.contains { $0.id == saved.wirelessUID && $0.recognized && $0.videoAvailable }
            return (found ? "Available" : "Connection not checked", found, false)
        default: return ("Connection not checked", false, false)
        }
    }

    private var monitoredWindow: MacWindowIdentity? {
        model.state.monitoring && model.setup?.kind == .macWindow ? model.setup?.window : nil
    }
    private var monitoredDisplayID: String? {
        guard model.state.monitoring, model.setup?.kind == .macScreen, let id = model.setup?.videoID else { return nil }
        return model.screenDisplays.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.id ?? id
    }
}

private struct SourceChooserContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct SourceChooserScrollHeight: ViewModifier {
    @Binding var height: CGFloat
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height.rounded(.up) } action: { _, value in
                if abs(value - height) >= 1 { height = value }
            }
        } else {
            content.onPreferenceChange(SourceChooserContentHeight.self) { height = $0 }
        }
    }
}

struct SourceChoiceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SourceChoiceBody(configuration: configuration)
    }
    private struct SourceChoiceBody: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(.primary.opacity(configuration.isPressed ? 0.1 : hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 12))
                .onHover { hovered = $0 }
        }
    }
}
