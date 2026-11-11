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
        if transmitter { kinds.formUnion([.localNetwork, .location]) }
        if sharing { kinds.insert(.localNetwork) }
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
        case .location: return "Optional. Only for automatic transmitter Wi-Fi rejoin, because macOS shows Wi-Fi names only with Location access. Setbeam asks when you turn it on in Source Details."
        }
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
    @State private var uses: PermissionUses
    var inSettings = false

    init(model: SessionModel, inSettings: Bool = false) { self.model = model; self.inSettings = inSettings; _uses = State(initialValue: model.permissionUses) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions").font(.title2.weight(.semibold))
                Text(inSettings ? "Access for monitoring and sharing on this Mac. Allow only what you need; optional access is explained below." : "macOS asks once for each kind of access. Choose what you'll use, and Setbeam asks only for what that needs, when you press Allow.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Form {
                if !inSettings { Section("What you'll use") {
                    Toggle("This Mac's screen or an app window", isOn: $uses.screen).accessibilityLabel("This Mac's screen or an app window")
                    Toggle("A camera or capture device", isOn: $uses.camera).accessibilityLabel("A camera or capture device")
                    Toggle("A wireless transmitter", isOn: $uses.transmitter).accessibilityLabel("A wireless transmitter")
                    Toggle("Sharing with viewers on this network", isOn: $uses.sharing).accessibilityLabel("Sharing with viewers on this network")
                    Text("The sample feed needs no access. Turn on each kind of source you use.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
                Section("Access") {
                    ForEach(PermissionKind.allCases) { kind in row(kind) }
                }
            }.formStyle(.grouped).frame(height: 400)
            if !inSettings { HStack {
                Text("Reopen any time from Setbeam > Settings…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Later") { finish(openSources: false) }.keyboardShortcut(.cancelAction)
                    .help("Close without asking for anything. macOS asks when a source first needs access.")
                Button(model.setup == nil ? "Choose a Source…" : "Done") { finish(openSources: model.setup == nil) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } }
        }.padding(24).frame(width: inSettings ? nil : 640)
            .onChange(of: uses) { _, value in if inSettings { model.permissionUses = value } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in guide.refresh() }
    }

    private func row(_ kind: PermissionKind) -> some View {
        let state = guide.state(kind, needed: inSettings || uses.needs.contains(kind))
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind.symbol).font(.title3).foregroundStyle(.secondary).frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(kind.title).font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Label(label(kind, state), systemImage: symbol(state)).font(.caption).foregroundStyle(color(kind, state))
                }
                Text(kind.purpose).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let note = note(kind, state) {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                actions(kind, state)
            }
        }.padding(.vertical, 4).opacity(state == .notNeeded ? 0.6 : 1)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func actions(_ kind: PermissionKind, _ state: PermissionState) -> some View {
        HStack(spacing: 12) {
            switch (kind, state) {
            case (_, .notNeeded), (_, .allowed): EmptyView()
            case (.location, _):
                if state == .denied { Button("Open Settings") { NSWorkspace.shared.open(kind.settingsURL) } }
            case (.localNetwork, _):
                if !guide.networkRequested {
                    Button("Allow…") { guide.request(kind, model: model) }.help("Look for transmitters briefly so macOS can ask about Local Network access")
                }
                Button("Open Settings") { NSWorkspace.shared.open(kind.settingsURL) }
            case (_, .notAsked):
                Button("Allow…") { guide.request(kind, model: model) }.help("Ask macOS for \(kind.title) access now")
            default:
                Button("Open Settings") { NSWorkspace.shared.open(kind.settingsURL) }.help("Turn on Setbeam in Privacy & Security > \(kind.title)")
            }
        }.buttonStyle(.link).font(.caption)
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
