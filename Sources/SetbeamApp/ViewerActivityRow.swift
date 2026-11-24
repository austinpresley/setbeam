import SwiftUI
import SetbeamCore

struct ViewerAvatar: View {
    let viewer: ViewerActivity
    var holding = false
    var size: CGFloat = 28

    var body: some View {
        let status = ViewerStatus(viewer: viewer, holding: holding)
        Text(String(viewer.displayName.prefix(1)).uppercased()).font(.caption.weight(.semibold))
            .foregroundStyle(viewer.color.darkText ? Color(white: 0.06) : .white)
            .frame(width: size, height: size)
            .background(Color(red: viewer.color.rgb.red, green: viewer.color.rgb.green, blue: viewer.color.rgb.blue), in: Circle())
            .padding(3)
            .overlay { Circle().strokeBorder(status.ring, lineWidth: 2) }
            .help("\(viewer.displayName) · \(status.title)")
            .accessibilityHidden(true)
    }
}

struct ViewerRequestRow: View {
    @ObservedObject var model: SessionModel
    let viewer: ViewerActivity
    var framed = true

    var body: some View {
        let request = JoinRequest(viewer, link: model.viewingLink)
        let method = viewer.shortAddress ? "Typed \(model.shortAddressHost ?? "the local address"). " : ""
        return HStack(spacing: 8) {
            ViewerAvatar(viewer: viewer, size: 28)
            Text(viewer.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                .help("\(viewer.displayName) · \(method)Name chosen by the viewer")
                .accessibilityLabel("\(viewer.displayName), session \(viewer.number). \(method)Asking to join")
            Spacer(minLength: 0)
            ViewerDeviceIcon(viewer: viewer)
            requestButton("Admit", symbol: "checkmark", tint: SetbeamChrome.admit) { model.answer(request, admit: true) }
            requestButton("Decline", symbol: "xmark", tint: nil) { model.answer(request, admit: false) }
        }.padding(.horizontal, 12).frame(minHeight: 48)
            .background(framed ? SetbeamChrome.raised : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                if framed {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(SetbeamChrome.line, lineWidth: 1).allowsHitTesting(false)
                }
            }
    }

    private func requestButton(_ title: String, symbol: String, tint: Color?, action: @escaping () -> Void) -> some View {
        let description = "\(title) \(viewer.displayName), session \(viewer.number)"
        return Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint == nil ? Color.primary : .white)
                .frame(width: 28, height: 28)
                .background(tint ?? .primary.opacity(0.10), in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain).help(description).accessibilityLabel(description)
    }
}

struct ViewerActivityRow: View {
    @ObservedObject var model: SessionModel
    let viewer: ViewerActivity
    @State private var hover = false
    @State private var showingDetails = false
    @FocusState private var removeFocused: Bool

    var body: some View {
        let reference = JoinRequest(viewer, link: model.viewingLink)
        let status = ViewerStatus(viewer: viewer, holding: model.audiencePresentation.confirmedHold)
        return HStack(spacing: 8) {
            ViewerAvatar(viewer: viewer, holding: model.audiencePresentation.confirmedHold)
            Text(viewer.displayName).font(.callout.weight(.semibold)).lineLimit(2)
                .accessibilityLabel("\(viewer.displayName), session \(viewer.number)")
            Spacer(minLength: 0)
            if viewer.pointing {
                Image(systemName: "cursorarrow").font(.caption).foregroundStyle(.secondary)
                    .help("Pointing").accessibilityLabel("Pointing")
            }
            ViewerDeviceIcon(viewer: viewer)
            ChromeIconButton("Details for \(viewer.displayName), session \(viewer.number)", symbol: "info.circle", size: 28,
                             hint: "Viewer details") { showingDetails.toggle() }
                .foregroundStyle(.secondary)
                .popover(isPresented: $showingDetails) {
                    ViewerDetails(viewer: viewer, status: status.title,
                                  measurements: model.state.audience == .live && !model.busy ? viewer.measurements : nil)
                }
            ZStack {
                Image(systemName: status.symbol, variableValue: status.variableValue).font(.system(size: 14)).foregroundStyle(status.tint)
                    .help(status.title).accessibilityLabel(status.title)
                    .opacity(model.viewerApproval && (hover || removeFocused) ? 0 : 1)
                if model.viewerApproval {
                    ChromeIconButton("Remove \(viewer.displayName), session \(viewer.number)", symbol: "minus.circle", size: 28,
                                     hint: "Remove this viewer. Other viewers continue.") { model.removeViewer(reference) }
                        .foregroundStyle(SetbeamChrome.red)
                        .focused($removeFocused).opacity(hover || removeFocused ? 1 : 0.001)
                        .allowsHitTesting(hover || removeFocused)
                }
            }.frame(width: 28, height: 28)
        }.padding(.horizontal, 8).frame(minHeight: 48)
            .background(.primary.opacity(hover ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle()).onHover { hover = $0 }
            .help("\(viewer.displayName) · \(status.title)")
            .accessibilityElement(children: .contain)
            .accessibilityValue(status.title)
            .contextMenu {
                if model.viewerApproval {
                    Button("Remove Viewer", role: .destructive) { model.removeViewer(reference) }
                }
            }
    }
}

private struct ViewerDetails: View {
    let viewer: ViewerActivity
    let status: String
    let measurements: ViewerMeasurements?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewer.displayName).font(.headline)
                Text("Session \(viewer.number) · Admitted").foregroundStyle(.secondary)
            }
            Divider()
            LabeledContent("Playback", value: status)
            if let joined = viewer.admittedAt {
                LabeledContent("Joined") { timestamp(joined) }
            }
            LabeledContent("Last update") { timestamp(viewer.lastSeen) }
            LabeledContent("Last playback report") {
                if let updated = viewer.playbackUpdatedAt { timestamp(updated) }
                else { Text("Unavailable") }
            }
            if let measurements {
                Divider()
                if let width = measurements.width, let height = measurements.height {
                    LabeledContent("Received resolution") { Text("\(width) × \(height)") }
                }
                if let fps = measurements.framesPerSecond {
                    LabeledContent("Inbound frame rate") {
                        Text("\(fps, format: .number.precision(.fractionLength(0...1))) fps")
                    }
                }
                if let dropped = measurements.droppedFrames {
                    LabeledContent("Dropped frames") {
                        Text(dropped, format: .number)
                            .help("Total for the current inbound video stream")
                    }
                }
            }
        }
        .font(.callout)
        .padding(16)
        .frame(width: 304)
    }

    private func timestamp(_ date: Date) -> some View {
        Text(date.formatted(.dateTime.month().day().hour().minute().second()))
            .monospacedDigit()
    }
}

private struct ViewerDeviceIcon: View {
    let viewer: ViewerActivity
    var body: some View {
        let title = viewer.onThisMac ? "This Mac" : viewer.label
        Image(systemName: viewer.mobile ? "iphone" : "laptopcomputer").font(.system(size: 14))
            .frame(width: 16).foregroundStyle(.secondary).help(title).accessibilityLabel(title)
    }
}

private struct ViewerStatus {
    let viewer: ViewerActivity
    let holding: Bool

    var title: String {
        if viewer.admission == .pending { return "Asking to join" }
        if holding { return "On Hold" }
        if viewer.updatesMissing { return "No recent update. This session still has access." }
        switch viewer.health {
        case .good: return "Good playback"
        case .struggling: return "Struggling playback"
        case .checking: return "Playing. Checking reception"
        case .playing: return "Playing"
        case .connecting: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .paused: return "Paused by viewer"
        case .background: return "In background"
        case .ready: return "Viewer needs to press Play"
        case .holding: return "Holding output unconfirmed"
        }
    }

    private var needsAttention: Bool {
        viewer.admission == .pending || holding || viewer.updatesMissing || [.struggling, .reconnecting, .holding].contains(viewer.health)
    }
    var ring: Color {
        if needsAttention { return SetbeamChrome.amber }
        return viewer.playing ? SetbeamChrome.green : .secondary.opacity(0.55)
    }
    var tint: Color {
        if needsAttention { return SetbeamChrome.amberText }
        return viewer.playing ? SetbeamChrome.greenText : .secondary
    }

    var variableValue: Double? { !holding && !viewer.updatesMissing && viewer.health == .struggling ? 0.25 : nil }

    var symbol: String {
        if holding { return "pause.fill" }
        if viewer.updatesMissing { return "clock" }
        switch viewer.health {
        case .good, .playing, .checking: return "play.fill"
        case .struggling: return "cellularbars"
        case .reconnecting, .holding: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .background: return "rectangle.on.rectangle"
        case .ready: return "play.circle"
        case .connecting: return "circle.dashed"
        }
    }
}
