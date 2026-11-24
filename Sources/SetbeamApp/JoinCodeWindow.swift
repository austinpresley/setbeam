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
                            if let url = model.viewingInvitation?.ipURL { QRView(payload: url.absoluteString, size: codeSize) }
                            else { Text(model.viewingCodeStatus).foregroundStyle(.secondary) }
                        }
                    }
                    if selection != "Wi-Fi", model.state.sharing, model.viewingInvitation == nil {
                        Button("Choose Viewing Network…") { model.showViewingNetwork() }
                            .buttonStyle(.link).padding(.top, 12)
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
                }.disabled(!JoinCodeExporter.canExport(model: model, includeWiFi: selection != "Feed", includeFeed: selection != "Wi-Fi"))
            }.padding(16)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func export(printing: Bool) {
        do {
            let snapshot = try JoinCodeExporter.snapshot(model: model, includeWiFi: selection != "Feed", includeFeed: selection != "Wi-Fi")
            problem = nil
            if printing { try JoinCodeExporter.print(snapshot, model: model) }
            else { try JoinCodeExporter.save(snapshot, model: model) }
        } catch { problem = error.localizedDescription }
    }
}

/// Invite and the codes window export the same dated snapshot and validate the same inputs.
@MainActor enum JoinCodeExporter {
    struct Snapshot {
        let document: JoinCodeDocumentView
        let endorsement: Endorsement
        let includeWiFi: Bool
        let includeFeed: Bool
    }

    struct Endorsement: Equatable {
        struct Feed: Equatable {
            let binding: UUID
            let url: URL
            let approval: Bool
        }
        let feed: Feed?
        let wifiPayload: String?
    }

    static func canExport(model: SessionModel, includeWiFi: Bool = true, includeFeed: Bool = true) -> Bool {
        let hasWiFi = includeWiFi && !model.wifiSSID.isEmpty
        let hasFeed = includeFeed && model.viewingInvitation != nil
        if hasWiFi && !model.viewingWiFiPasswordAvailable { return false }
        if includeFeed && model.state.sharing && !hasFeed { return false }
        return hasWiFi || hasFeed
    }

    static func snapshot(model: SessionModel, includeWiFi: Bool = true, includeFeed: Bool = true) throws -> Snapshot {
        let endorsement = try endorsement(model: model, includeWiFi: includeWiFi, includeFeed: includeFeed)
        let document = JoinCodeDocumentView(title: model.title, ssid: endorsement.wifiPayload == nil ? "" : model.wifiSSID,
            password: endorsement.wifiPayload == nil ? "" : model.wifiPassword,
            url: endorsement.feed?.url, date: Date(), approval: endorsement.feed?.approval ?? false)
        return Snapshot(document: document, endorsement: endorsement, includeWiFi: includeWiFi, includeFeed: includeFeed)
    }

    private static func endorsement(model: SessionModel, includeWiFi: Bool, includeFeed: Bool) throws -> Endorsement {
        model.loadViewingWiFi()
        let hasWiFi = includeWiFi && !model.wifiSSID.isEmpty
        guard !hasWiFi || model.viewingWiFiPasswordAvailable else { throw ExportProblem.passwordUnavailable }
        let invitation = includeFeed ? model.currentViewingInvitation() : nil
        if includeFeed && model.state.sharing && invitation == nil { throw ExportProblem.codeUnavailable }
        guard hasWiFi || invitation != nil else { throw ExportProblem.codeUnavailable }
        return Endorsement(feed: invitation.map { .init(binding: $0.binding, url: $0.ipURL, approval: model.viewerApproval) },
                           wifiPayload: hasWiFi ? QRCode.wifi(ssid: model.wifiSSID, password: model.wifiPassword) : nil)
    }

    static func validate(_ snapshot: Snapshot, model: SessionModel) throws {
        guard let current = try? endorsement(model: model, includeWiFi: snapshot.includeWiFi, includeFeed: snapshot.includeFeed),
              current == snapshot.endorsement else { throw ExportProblem.codesChanged }
    }

    static func save(_ snapshot: Snapshot, model: SessionModel) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Setbeam-join-codes.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try validate(snapshot, model: model)
        let document = snapshot.document
        do { try document.dataWithPDF(inside: document.bounds).write(to: url, options: .atomic) }
        catch { throw ExportProblem.saveFailed }
    }

    static func print(_ snapshot: Snapshot, model: SessionModel) throws {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit; info.verticalPagination = .fit
        info.isHorizontallyCentered = true; info.isVerticallyCentered = true
        // Resolve the print choices before handing the endorsed document to AppKit.
        guard NSPrintPanel().runModal(with: info) == NSPrintPanel.Result.printed.rawValue else { return }
        try validate(snapshot, model: model)
        let operation = NSPrintOperation(view: snapshot.document, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw ExportProblem.printFailed }
    }

    private enum ExportProblem: LocalizedError {
        case passwordUnavailable, codeUnavailable, codesChanged, saveFailed, printFailed

        var errorDescription: String? {
            switch self {
            case .passwordUnavailable: return "The Wi-Fi password is unavailable. Re-enter it in Invite before exporting."
            case .codeUnavailable: return "The selected code is unavailable. Check the viewing network or choose another code."
            case .codesChanged: return "The join codes changed while the dialog was open. Try again with the current codes."
            case .saveFailed: return "The codes could not be saved. Choose another location and try again."
            case .printFailed: return "The codes could not be printed."
            }
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
