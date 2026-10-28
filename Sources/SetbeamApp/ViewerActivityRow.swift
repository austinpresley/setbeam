import SwiftUI
import SetbeamCore

struct ViewerActivityRow: View {
    let viewer: ViewerActivity

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(viewer.displayName).fontWeight(.medium).lineLimit(2)
                    Spacer(minLength: 8)
                    Text(title).font(.caption).foregroundStyle(color)
                }
                Text("\(viewer.name == nil ? "Viewer \(viewer.number)" : "\(viewer.label) · \(viewer.number)") · \(viewer.onThisMac ? "This Mac" : "Another device")")
                    .font(.caption).foregroundStyle(.secondary)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }

    private var title: String {
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
        switch viewer.health {
        case .good, .playing: return .green
        case .struggling, .reconnecting: return .orange
        case .holding: return .blue
        default: return .secondary
        }
    }
    private var symbol: String {
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
