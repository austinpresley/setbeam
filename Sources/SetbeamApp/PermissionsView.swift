import SwiftUI
import AppKit
import AVFoundation
import CoreLocation
import SetbeamCore

/// What the operator plans to use. Each choice needs only its own macOS access.
struct PermissionUses: Equatable {
    var screen = false
    var camera = false
    var transmitter = false
    var sharing = true

    /// Access each choice needs. Microphone and Location are optional extras of a choice, never requested on their own.
    var needs: Set<PermissionKind> {
        var kinds = Set<PermissionKind>()
        if screen { kinds.insert(.screenRecording) }
        if camera { kinds.formUnion([.camera, .microphone]) }
        if transmitter { kinds.insert(.location) }
        if (transmitter || sharing) && PermissionKind.localNetwork.isAvailable { kinds.insert(.localNetwork) }
        return kinds
    }
}

enum PermissionKind: String, CaseIterable, Identifiable {
    case screenRecording, camera, microphone, localNetwork, location
    var id: String { rawValue }
    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .localNetwork: return "Local Network"
        case .location: return "Location"
        }
    }
    /// Tile name. `title` stays the name macOS uses in Privacy & Security.
    var shortTitle: String {
        switch self {
        case .screenRecording: return "Screen"
        case .location: return "Wi-Fi Name"
        default: return title
        }
    }
    var symbol: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .camera: return "video"
        case .microphone: return "mic"
        case .localNetwork: return "network"
        case .location: return "location"
        }
    }
    var purpose: String {
        switch self {
        case .screenRecording: return "Captures the display or window you choose and shows previews in Choose a source. Setbeam's own windows are left out."
        case .camera: return "Uses the USB camera or capture device you select."
        case .microphone: return "Optional. Only for sound from a capture input you choose in Source Details."
        case .localNetwork: return "Finds transmitters on this Mac's Wi-Fi and lets viewers on this network open your link."
        case .location: return "Lists Wi-Fi names when requested, verifies Pyro H Wi-Fi, and supports automatic transmitter rejoin when enabled."
        }
    }
    var isAvailable: Bool {
        if self == .localNetwork {
            if #available(macOS 15, *) { return true }
            return false
        }
        return true
    }

    /// The Privacy & Security pane for this access.
    var settingsURL: URL {
        let pane: String
        switch self {
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .camera: pane = "Privacy_Camera"
        case .microphone: pane = "Privacy_Microphone"
        case .localNetwork: pane = "Privacy_LocalNetwork"
        case .location: pane = "Privacy_LocationServices"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

/// What macOS reports for one kind of access. Local Network has no status API, so it stays unknown.
enum PermissionState: Equatable {
    case allowed, denied, notAsked, unknown, notNeeded

    static func media(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }
    static func location(_ status: CLAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorizedAlways: return .allowed
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }
}

/// Reads and requests access for the permissions guide. Requests happen only from the operator's button press,
/// through the same calls Setbeam already uses when a source starts.
@MainActor final class PermissionGuide: ObservableObject {
    @Published private(set) var states: [PermissionKind: PermissionState] = [:]
    /// Screen Recording reports only allowed or not; after one request a refusal is treated as denied.
    @Published private(set) var screenRequested = false
    @Published private(set) var networkRequested = false
    private let location = CLLocationManager()

    init() { refresh() }

    func refresh() {
        states[.screenRecording] = CGPreflightScreenCaptureAccess() ? .allowed : screenRequested ? .denied : .notAsked
        states[.camera] = .media(AVCaptureDevice.authorizationStatus(for: .video))
        states[.microphone] = .media(AVCaptureDevice.authorizationStatus(for: .audio))
        states[.localNetwork] = .unknown
        states[.location] = .location(location.authorizationStatus)
    }

    func state(_ kind: PermissionKind, needed: Bool) -> PermissionState { needed ? states[kind] ?? .unknown : .notNeeded }

    func request(_ kind: PermissionKind, model: SessionModel) {
        guard kind.isAvailable else { return }
        switch kind {
        case .screenRecording:
            _ = MacScreenCapture.requestPermission(); screenRequested = true; refresh()
        case .camera, .microphone:
            Task { _ = await AVCaptureDevice.requestAccess(for: kind == .camera ? .video : .audio); refresh() }
        case .localNetwork:
            // The chooser's own discovery is what makes macOS ask; run it briefly, then stop.
            networkRequested = true
            model.sourceBrowser.start { model.canDiscoverPyroH }
            Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if model.sheet != .connection { model.sourceBrowser.stop() } }
        case .location:
            NSWorkspace.shared.open(kind.settingsURL)
        }
    }
}

struct PermissionsView: View {
    @ObservedObject var model: SessionModel
    @StateObject private var guide = PermissionGuide()
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var uses: PermissionUses
    var inSettings = false

    init(model: SessionModel, inSettings: Bool = false) { self.model = model; self.inSettings = inSettings; _uses = State(initialValue: model.permissionUses) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                if !inSettings {
                    Text("Choose what you'll use. Setbeam asks only for what that needs.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !inSettings { Form {
                Section("What you'll use") {
                    Toggle("This Mac's screen or an app window", isOn: $uses.screen).accessibilityLabel("This Mac's screen or an app window")
                    Toggle("A camera or capture device", isOn: $uses.camera).accessibilityLabel("A camera or capture device")
                    Toggle("A wireless transmitter", isOn: $uses.transmitter).accessibilityLabel("A wireless transmitter")
                    if PermissionKind.localNetwork.isAvailable {
                        Toggle("Sharing with viewers on this network", isOn: $uses.sharing)
                    }
                    Text("The sample feed needs no access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).frame(height: 210) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                ForEach(PermissionKind.allCases.filter(\.isAvailable)) { kind in tile(kind) }
            }
            Label("Asked only when a source needs it", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            if !inSettings { HStack {
                Text("Reopen any time from Setbeam > Settings…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Later") { finish(openSources: false) }.keyboardShortcut(.cancelAction)
                    .help("Close without asking for anything. macOS asks when a source first needs access.")
                Button(model.setup == nil ? "Choose a Source…" : "Done") { finish(openSources: model.setup == nil) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } }
        }.padding(24).frame(width: inSettings ? nil : 640)
            .task { if !inSettings { headingFocused = true } }
            .onChange(of: uses) { _, value in if inSettings { model.permissionUses = value } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in guide.refresh() }
    }

    private func tile(_ kind: PermissionKind) -> some View {
        let state = guide.state(kind, needed: inSettings || uses.needs.contains(kind))
        let details = [kind.purpose, note(kind, state)].compactMap { $0 }.joined(separator: " ")
        return VStack(spacing: 9) {
            Image(systemName: kind.symbol).font(.system(size: 20)).foregroundStyle(.primary.opacity(0.8))
                .frame(width: 46, height: 46).background(.primary.opacity(0.06), in: Circle())
                .overlay(alignment: .bottomTrailing) { badge(kind, state) }
                .accessibilityHidden(true)
            Text(kind.shortTitle).font(.callout.weight(.medium)).lineLimit(1)
            actions(kind, state)
        }.frame(maxWidth: .infinity, minHeight: 132)
            .background(.background.opacity(state == .notNeeded || kind == .location && state != .allowed ? 0.5 : 1),
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.1), lineWidth: 1) }
            .overlay(alignment: .topTrailing) { PermissionInfoButton(title: kind.title, details: details).padding(6) }
            .opacity(state == .notNeeded ? 0.6 : 1)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(kind.title), \(label(kind, state))")
    }

    @ViewBuilder private func badge(_ kind: PermissionKind, _ state: PermissionState) -> some View {
        let mark: (String, Color)? = switch state {
        case .allowed: ("checkmark", .green)
        case .denied where kind != .location: ("xmark", .orange)
        default: nil
        }
        if let mark {
            Image(systemName: mark.0).font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(mark.1, in: Circle())
                .background(Color(nsColor: .windowBackgroundColor), in: Circle().inset(by: -2.5))
                .offset(x: 3, y: 3).help(label(kind, state))
        }
    }

    @ViewBuilder private func actions(_ kind: PermissionKind, _ state: PermissionState) -> some View {
        HStack(spacing: 12) {
            switch (kind, state) {
            case (_, .notNeeded), (_, .allowed): EmptyView()
            case (.location, _):
                if state == .denied { pill("Settings", prominent: false) { NSWorkspace.shared.open(kind.settingsURL) } }
                else { pill("Allow", prominent: false) { NSWorkspace.shared.open(kind.settingsURL) } }
            case (.localNetwork, _):
                if !guide.networkRequested {
                    pill("Allow", prominent: true) { guide.request(kind, model: model) }
                        .help("Look for transmitters briefly so macOS can ask about Local Network access")
                } else {
                    pill("Settings", prominent: false) { NSWorkspace.shared.open(kind.settingsURL) }
                }
            case (_, .notAsked):
                pill("Allow", prominent: true) { guide.request(kind, model: model) }.help("Ask macOS for \(kind.title) access now")
            default:
                pill("Settings", prominent: false) { NSWorkspace.shared.open(kind.settingsURL) }
                    .help("Turn on Setbeam in Privacy & Security > \(kind.title)")
            }
        }.font(.caption)
    }

    private func pill(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.medium)).padding(.horizontal, 12).frame(height: 22)
                .foregroundStyle(prominent ? Color.white : .primary)
                .background(prominent ? SetbeamChrome.blue : Color.primary.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    private func label(_ kind: PermissionKind, _ state: PermissionState) -> String {
        switch state {
        case .allowed: return "Allowed"
        case .denied: return kind == .location ? "Off" : "Not allowed"
        // Screen Recording reports only allowed or not, so an earlier refusal also reads as not allowed yet.
        case .notAsked: return kind == .location ? "Not requested" : kind == .screenRecording ? "Not allowed yet" : "Not asked yet"
        case .unknown: return guide.networkRequested ? "Requested" : "Asked when first needed"
        case .notNeeded: return "Not needed"
        }
    }
    private func note(_ kind: PermissionKind, _ state: PermissionState) -> String? {
        switch (kind, state) {
        case (.screenRecording, .denied): return "Turn on Setbeam in Screen & System Audio Recording. If you just allowed it, quit and reopen Setbeam."
        case (.localNetwork, .unknown): return "macOS doesn't report this setting to apps. If viewers or transmitters can't connect, check it in Settings."
        case (.camera, .denied), (.microphone, .denied): return "Turn on Setbeam in Privacy & Security > \(kind.title)."
        default: return nil
        }
    }
    private func symbol(_ state: PermissionState) -> String {
        switch state {
        case .allowed: return "checkmark.circle.fill"
        case .denied: return "xmark.circle"
        case .notAsked, .unknown: return "circle.dashed"
        case .notNeeded: return "minus.circle"
        }
    }
    private func color(_ kind: PermissionKind, _ state: PermissionState) -> Color {
        switch state {
        case .allowed: return .green
        // Location is optional, so leaving it off is not a problem to flag.
        case .denied: return kind == .location ? .secondary : .orange
        default: return .secondary
        }
    }
    private func finish(openSources: Bool) {
        model.permissionUses = uses
        if openSources { model.openSources() } else { model.sheet = nil }
    }
}

/// Reasons stay one click away rather than as a paragraph on every tile.
private struct PermissionInfoButton: View {
    let title: String
    let details: String
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(.tertiary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).help(details)
            .accessibilityLabel("About \(title) access").accessibilityHint(details)
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(details).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .frame(width: 260, alignment: .leading).padding(14)
            }
    }
}

/// The denied attempt is independent of the source already on the monitor.
struct DeniedSourceRequest: Equatable {
    let candidate: SourceSetup
    let address: String?
    let remember: Bool
    let permission: PermissionKind

    var instructions: String {
        if permission == .screenRecording {
            return "Allow Setbeam in Screen & System Audio Recording to use \(candidate.name), then retry. macOS may ask you to quit and reopen Setbeam."
        }
        return "Allow Setbeam in Privacy & Security > \(permission.title) to use \(candidate.name), then retry."
    }
}
