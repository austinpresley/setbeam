import SwiftUI
import SetbeamCore

struct ViewerActivityRow: View {
    let viewer: ViewerActivity
    /// Individual removal is offered only when approval makes it enforceable.
    var canRemove = false
    var stackedAdmissionActions = false
    var audiencePresentation: AudiencePresentation?
    /// The short address in use now, to name where a typed request came from.
    var shortAddressHost: String?
    var admit: () -> Void = {}
    var decline: () -> Void = {}
    var remove: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(String(viewer.displayName.prefix(1)).uppercased()).font(.caption.weight(.medium))
                .foregroundStyle(viewer.color.darkText ? Color(white: 0.06) : .white)
                .frame(width: 24, height: 24)
                .background(Color(red: viewer.color.rgb.red, green: viewer.color.rgb.green, blue: viewer.color.rgb.blue), in: Circle())
                .help("\(viewer.color.label), chosen by \(viewer.displayName)")
                .accessibilityLabel("Viewer color: \(viewer.color.label)")
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(viewer.displayName).fontWeight(.medium).lineLimit(2).help(viewer.displayName)
                    Spacer(minLength: 0)
                    if viewer.admission == .pending && !stackedAdmissionActions {
                        admissionActions
                    } else if canRemove {
                        Menu { Button("Remove Viewer", role: .destructive, action: remove) } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .accessibilityLabel("Actions for \(viewer.displayName), session \(viewer.number)")
                            .help("Remove this browser session. Other viewers continue.")
                    }
                }
                if viewer.admission != .pending {
                    Label(title, systemImage: symbol).font(.caption).foregroundStyle(color)
                }
                Text((["Session \(viewer.number)", viewer.onThisMac ? "This Mac" : "Another device"] + (viewer.pointing ? ["Pointing"] : [])).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if viewer.admission == .pending && stackedAdmissionActions { admissionActions.padding(.top, 4) }
                if viewer.admission == .pending && viewer.shortAddress {
                    Text("Typed \(shortAddressHost ?? "the local address")").font(.caption).foregroundStyle(.secondary)
                } else if problemDetail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.accessibilityElement(children: .contain).help(detail)
    }

    private var admissionActions: some View {
        HStack(spacing: 8) {
            Button("Admit", action: admit).buttonStyle(.bordered)
                .accessibilityLabel("Admit \(viewer.displayName), session \(viewer.number)")
            Button("Decline", action: decline)
                .accessibilityLabel("Decline \(viewer.displayName), session \(viewer.number)")
        }.controlSize(.small).fixedSize()
    }

    private var problemDetail: Bool {
        viewer.admission != .pending && (viewer.updatesMissing || [.ready, .paused, .background, .struggling, .reconnecting].contains(viewer.health))
    }

    private var title: String {
        if viewer.admission == .pending { return "Asking to join" }
        if viewer.updatesMissing { return "No recent update" }
        switch viewer.health {
        case .good: return "Good"
        case .struggling: return "Struggling"
        case .checking: return "Checking"
        case .playing: return "Playing"
        case .connecting: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .paused: return "Paused"
        case .background: return "In background"
        case .ready: return "Ready to play"
        case .holding: return audiencePresentation?.confirmedHold == false ? "Outgoing feed not confirmed" : "On Hold"
        }
    }
    private var detail: String {
        if viewer.updatesMissing {
            return "Playback is unconfirmed. This session still has access until you remove it or stop sharing."
        }
        if viewer.admission == .pending {
            return viewer.shortAddress ? "Typed \(shortAddressHost ?? "the local address"). Names are chosen by viewers and are not verified."
                : "Names are chosen by viewers and are not verified."
        }
        switch viewer.health {
        case .good: return "Fresh video with low reported loss and delay."
        case .struggling: return "Video is playing with sustained loss, delay, or dropped frames."
        case .checking: return "Picture is playing. Measuring reception."
        case .playing: return "Fresh picture. Detailed measurements are unavailable."
        case .connecting: return "Waiting for the current picture."
        case .reconnecting: return "Fresh playback has not been confirmed."
        case .paused: return "Playback is paused on this viewer."
        case .background: return "The viewer page is in the background."
        case .ready: return "The viewer needs to tap Play."
        case .holding: return audiencePresentation?.confirmedHold == false ? "Holding output is not confirmed." : "Viewers are on Hold."
        }
    }
    private var color: Color {
        if viewer.updatesMissing { return .orange }
        if viewer.admission == .pending { return .accentColor }
        switch viewer.health {
        case .good, .playing: return .green
        case .struggling, .reconnecting: return .orange
        case .holding: return .orange
        default: return .secondary
        }
    }
    private var symbol: String {
        if viewer.updatesMissing { return "clock" }
        if viewer.admission == .pending { return "person.badge.clock" }
        switch viewer.health {
        case .good, .playing: return "checkmark.circle.fill"
        case .struggling: return "exclamationmark.circle.fill"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .holding: return audiencePresentation?.confirmedHold == false ? "arrow.triangle.2.circlepath" : "pause.circle"
        case .paused: return "pause.circle"
        case .background: return "rectangle.on.rectangle"
        case .ready: return "play.circle"
        default: return "circle.dashed"
        }
    }
}
