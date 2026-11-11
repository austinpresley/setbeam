import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A separate invitation window follows the live model. Export makes an explicit dated snapshot.
@MainActor final class JoinCodeWindow {
    private var window: NSWindow?
    func show(model: SessionModel) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                             styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        window.title = "Join Codes"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = false; window.level = .normal
        window.minSize = NSSize(width: 320, height: 420)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: FloatingJoinCodes(model: model) { [weak window] floating in
            window?.isFloatingPanel = floating
            window?.level = floating ? .floating : .normal
            window?.collectionBehavior = floating ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
        })
        window.center(); self.window = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak window] in window?.makeFirstResponder(nil) }
    }
    func close() { window?.close() }
}

private struct FloatingJoinCodes: View {
    @ObservedObject var model: SessionModel
    var setFloating: (Bool) -> Void
    @State private var floating = false
    @State private var selection = "Both"
    @State private var problem: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Codes", selection: $selection) {
                    Text("Both").tag("Both"); Text("Feed").tag("Feed"); Text("Wi-Fi").tag("Wi-Fi")
                }.labelsHidden().frame(maxWidth: 240)
                Spacer()
                Toggle("Keep on Top", isOn: $floating).toggleStyle(.checkbox).onChange(of: floating) { _, value in setFloating(value) }
            }.padding(16)
            Divider()
            GeometryReader { geometry in
                ScrollView {
                    let stacked = selection == "Both" && !model.wifiSSID.isEmpty && geometry.size.width < 520
                    let heightLimit = max(128, floor((geometry.size.height - 112) / 4) * 4)
                    let codeSize = max(128, min(320, heightLimit, floor((geometry.size.width - 72) / (selection == "Both" && !model.wifiSSID.isEmpty && !stacked ? 8 : 4)) * 4))
                    if selection == "Both" {
                        InvitationCodesView(model: model, codeSize: codeSize, presentation: true, vertical: geometry.size.width < 520)
                    } else if selection == "Wi-Fi" {
                        if model.wifiSSID.isEmpty { Text("Add viewing Wi-Fi in Sharing > Invite.").foregroundStyle(.secondary) }
                        else if !model.viewingWiFiPasswordAvailable { Text("Password unavailable. Re-enter viewing Wi-Fi details in Invite.").foregroundStyle(.secondary) }
                        else {
                            VStack(spacing: 12) {
                                Text("Join Wi-Fi").font(.headline)
                                QRView(payload: QRCode.wifi(ssid: model.wifiSSID, password: model.wifiPassword), size: codeSize)
                                Text(model.wifiSSID).font(.headline).textSelection(.enabled)
                            }
                        }
                    } else {
                        VStack(spacing: 12) {
                            Text(model.title).font(.headline)
                            if model.state.sharing, let url = model.viewerURL { QRView(payload: url.absoluteString, size: codeSize) }
                            else { Label("Sharing is off", systemImage: "lock").foregroundStyle(.secondary) }
                        }
                    }
                }.padding(20).frame(maxWidth: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Saved and printed viewing codes expire when sharing stops. Wi-Fi codes include any saved password.")
                    .font(.caption).foregroundStyle(.secondary)
                if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("Save PDF…") { export(printing: false) }
                    Button("Print…") { export(printing: true) }
                    Spacer()
                }.disabled(!model.state.sharing && model.wifiSSID.isEmpty)
            }.padding(16)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func export(printing: Bool) {
        model.loadViewingWiFi()
        let includeWiFi = selection != "Feed" && !model.wifiSSID.isEmpty
        guard !includeWiFi || model.viewingWiFiPasswordAvailable else { problem = "The Wi-Fi password is unavailable. Re-enter it in Invite before exporting."; return }
        let snapshotURL = selection != "Wi-Fi" && model.state.sharing ? model.viewerURL : nil
        guard includeWiFi || snapshotURL != nil else { problem = "The selected code is unavailable. Choose another code or start sharing."; return }
        let view = JoinCodeDocumentView(title: model.title, ssid: includeWiFi ? model.wifiSSID : "", password: includeWiFi ? model.wifiPassword : "",
                                        url: snapshotURL, date: Date(), approval: model.viewerApproval)
        if printing {
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.horizontalPagination = .fit; info.verticalPagination = .fit
            info.isHorizontallyCentered = true; info.isVerticallyCentered = true
            NSPrintOperation(view: view, printInfo: info).run()
        } else {
            let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "Setbeam-join-codes.pdf"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard snapshotURL == nil || model.state.sharing && model.viewerURL == snapshotURL else { problem = "Sharing changed while Save was open. Save the current codes again."; return }
            do { try view.dataWithPDF(inside: view.bounds).write(to: url, options: .atomic); problem = nil }
            catch { problem = "The codes could not be saved. Choose another location and try again." }
        }
    }
}

/// AppKit draws synchronously for PDF/printing, without an unattached SwiftUI render cycle.
@MainActor final class JoinCodeDocumentView: NSView {
    private let title: String, ssid: String, password: String
    private let url: URL?, date: Date, approval: Bool
    init(title: String, ssid: String, password: String, url: URL?, date: Date, approval: Bool) {
        self.title = title; self.ssid = ssid; self.password = password; self.url = url; self.date = date; self.approval = approval
        super.init(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        func label(_ value: String, rect: NSRect, size: CGFloat = 13, bold: Bool = false) {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
            (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
        }
        label(title.isEmpty ? "Setbeam" : title, rect: NSRect(x: 32, y: 32, width: 656, height: 48), size: 24, bold: true)
        var codes: [(String, String, String)] = []
        if !ssid.isEmpty { codes.append(("1. Join Wi-Fi", QRCode.wifi(ssid: ssid, password: password), ssid)) }
        if let url { codes.append((ssid.isEmpty ? "Scan to Watch" : "2. Watch the Feed", url.absoluteString, "Viewing code snapshot")) }
        for (index, code) in codes.enumerated() {
            let center = codes.count == 1 ? 360.0 : index == 0 ? 180.0 : 540.0
            label(code.0, rect: NSRect(x: center - 160, y: 100, width: 320, height: 24), size: 15, bold: true)
            NSGraphicsContext.current?.imageInterpolation = .none
            QRCode.image(code.1)?.draw(in: NSRect(x: center - 112, y: 148, width: 224, height: 224),
                                     from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            label(code.2, rect: NSRect(x: center - 160, y: 404, width: 320, height: 40))
        }
        label("This sharing session only. Viewing codes expire at Stop. Join the operator's network.", rect: NSRect(x: 32, y: 468, width: 656, height: 24))
        let access = url == nil ? "" : approval ? "Viewers still need the operator's approval." : "Anyone with this viewing code can join while its session is active."
        label((ssid.isEmpty ? "" : password.isEmpty ? "Open Wi-Fi network. " : "Contains Wi-Fi password. ") + access,
              rect: NSRect(x: 32, y: 500, width: 656, height: 24), size: 11)
        label(date.formatted(date: .abbreviated, time: .shortened), rect: NSRect(x: 32, y: 532, width: 656, height: 20), size: 11)
    }
}
