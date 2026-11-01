import SwiftUI
import SetbeamCore

struct ViewerActivityRow: View {
    let viewer: ViewerActivity
    /// Individual removal is offered only when approval makes it enforceable.
    var canRemove = false
    var admit: () -> Void = {}
    var decline: () -> Void = {}
    var remove: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(viewer.displayName).fontWeight(.medium).lineLimit(2)
                    Spacer(minLength: 8)
                    Text(title).font(.caption).foregroundStyle(color)
                }
                HStack(spacing: 5) {
                    if viewer.pointing {
                        Circle().fill(Color(red: viewer.color.rgb.red, green: viewer.color.rgb.green, blue: viewer.color.rgb.blue))
                            .frame(width: 7, height: 7).accessibilityHidden(true)
                    }
                    Text(([viewer.name == nil ? "Viewer \(viewer.number)" : "\(viewer.label) · \(viewer.number)",
                           viewer.onThisMac ? "This Mac" : "Another device"] + (viewer.pointing ? ["Pointing"] : [])).joined(separator: " · "))
                }.font(.caption).foregroundStyle(.secondary)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if viewer.admission == .pending {
                    HStack(spacing: 8) {
                        Button("Admit", action: admit).buttonStyle(.borderedProminent)
                            .accessibilityLabel("Admit \(viewer.displayName), session \(viewer.number)")
                        Button("Decline", action: decline)
                            .accessibilityLabel("Decline \(viewer.displayName), session \(viewer.number)")
                    }.controlSize(.small).padding(.top, 3)
                } else if canRemove {
                    Button("Remove", role: .destructive, action: remove).buttonStyle(.link).font(.caption)
                        .accessibilityLabel("Remove \(viewer.displayName), session \(viewer.number)")
                        .help("End this browser session's picture and pointer. Other viewers continue.")
                }
            }
        }.accessibilityElement(children: .contain)
    }

    private var title: String {
        if viewer.admission == .pending { return "Asking to join" }
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
        case .holding: return "On hold"
        }
    }
    private var detail: String {
        if viewer.admission == .pending { return "Names are chosen by viewers and are not verified." }
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
        case .holding: return "You have put viewers on Hold."
        }
    }
    private var color: Color {
        if viewer.admission == .pending { return .accentColor }
        switch viewer.health {
        case .good, .playing: return .green
        case .struggling, .reconnecting: return .orange
        case .holding: return .blue
        default: return .secondary
        }
    }
    private var symbol: String {
        if viewer.admission == .pending { return "person.badge.clock" }
        switch viewer.health {
        case .good, .playing: return "checkmark.circle.fill"
        case .struggling: return "exclamationmark.circle.fill"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .holding, .paused: return "pause.circle"
        case .background: return "rectangle.on.rectangle"
        case .ready: return "play.circle"
        default: return "circle.dashed"
        }
    }
}
