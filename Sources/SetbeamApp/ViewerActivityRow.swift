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
    var returnAccessibilityFocus: () -> Void = {}
    @AccessibilityFocusState private var decisionFocused: Bool?

    var body: some View {
        let request = JoinRequest(viewer, link: model.viewingLink)
        return HStack(spacing: 8) {
            ViewerAvatar(viewer: viewer, size: 28)
            ViewerSessionLabel(request: request, status: "Asking to join")
            Spacer(minLength: 0)
            ViewerDeviceIcon(viewer: viewer)
            requestButton(request, admit: true)
            requestButton(request, admit: false)
        }.padding(.horizontal, 12).frame(minHeight: 48)
            .background(framed ? SetbeamChrome.raised : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                if framed {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(SetbeamChrome.line, lineWidth: 1).allowsHitTesting(false)
                }
            }
    }

    private func requestButton(_ request: JoinRequest, admit: Bool) -> some View {
        let description = "\(admit ? "Admit" : "Decline") \(request.name), session \(request.number)"
        return Button {
            let hadFocus = decisionFocused == admit
            if model.answer(request, admit: admit) {
                if hadFocus { returnAccessibilityFocus() }
                request.announceDecision(admit: admit)
            }
        } label: {
            Image(systemName: admit ? "checkmark" : "xmark").font(.system(size: 13, weight: .bold))
                .foregroundStyle(admit ? Color.white : .primary)
                .frame(width: 28, height: 28)
                .background(admit ? SetbeamChrome.admit : .primary.opacity(0.10), in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain).help(description).accessibilityLabel(description)
            .accessibilityFocused($decisionFocused, equals: admit)
    }
}

private struct ViewerSessionLabel: View {
    let request: JoinRequest
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(request.name).font(.callout.weight(.semibold)).lineLimit(1)
            Text(request.sessionLabel).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .layoutPriority(1)
        .help("\(request.name) · \(request.sessionLabel) · \(status)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(request.name), session \(request.number), \(request.routeLabel). \(status)")
    }
}

struct ViewerActivityRow: View {
    @ObservedObject var model: SessionModel
    let viewer: ViewerActivity
    let showingDetails: Bool
    let returnAccessibilityFocus: () -> Void
    let toggleDetails: () -> Void
    @State private var hover = false
    @FocusState private var removeFocused: Bool
    @AccessibilityFocusState private var removeAccessibilityFocused: Bool

    var body: some View {
        let status = ViewerStatus(viewer: viewer, holding: model.audiencePresentation.confirmedHold)
        VStack(alignment: .leading, spacing: 0) {
            row(status: status)
            if showingDetails {
                ViewerDetails(viewer: viewer, status: status.title,
                              measurements: model.state.audience == .live && !model.busy ? viewer.measurements : nil)
            }
        }
    }

    private var showsRemove: Bool { hover || removeFocused || removeAccessibilityFocused }

    private func row(status: ViewerStatus) -> some View {
        let reference = JoinRequest(viewer, link: model.viewingLink)
        return HStack(spacing: 8) {
            ViewerAvatar(viewer: viewer, holding: model.audiencePresentation.confirmedHold)
            ViewerSessionLabel(request: reference, status: status.title)
            Spacer(minLength: 0)
            if viewer.pointing {
                Image(systemName: "cursorarrow").font(.caption).foregroundStyle(.secondary)
                    .help("Pointing").accessibilityLabel("Pointing")
            }
            ViewerDeviceIcon(viewer: viewer)
            ChromeIconButton("Details for \(viewer.displayName), session \(viewer.number)", symbol: "info.circle", size: 28,
                             selected: showingDetails, hint: showingDetails ? "Hide viewer details" : "Show viewer details",
                             action: toggleDetails)
                .foregroundStyle(.secondary)
            ZStack {
                Image(systemName: status.symbol, variableValue: status.variableValue).font(.system(size: 14)).foregroundStyle(status.tint)
                    .help(status.title).accessibilityHidden(true)
                    .opacity(model.viewerApproval && showsRemove ? 0 : 1)
                if model.viewerApproval {
                    ChromeIconButton("Remove \(viewer.displayName), session \(viewer.number)", symbol: "minus.circle", size: 28,
                                     hint: "Remove this viewer. Other viewers continue.") { remove(reference) }
                        .foregroundStyle(SetbeamChrome.red)
                        .focused($removeFocused).accessibilityFocused($removeAccessibilityFocused)
                        .opacity(showsRemove ? 1 : 0.001)
                        .allowsHitTesting(showsRemove)
                }
            }.frame(width: 28, height: 28)
        }.padding(.horizontal, 8).frame(minHeight: 48)
            .background(.primary.opacity(hover ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle()).onHover { hover = $0 }
            .help("\(viewer.displayName) · \(status.title)")
            .accessibilityElement(children: .contain)
            .contextMenu {
                if model.viewerApproval {
                    Button("Remove Viewer", role: .destructive) { remove(reference) }
                }
            }
    }

    private func remove(_ request: JoinRequest) {
        guard model.removeViewer(request) else { return }
        returnAccessibilityFocus()
        AccessibilityNotification.Announcement("Removed \(request.name), session \(request.number).").post()
    }
}

private struct ViewerDetails: View {
    let viewer: ViewerActivity
    let status: String
    let measurements: ViewerMeasurements?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    LabeledContent("Received resolution", value: "\(width) × \(height)")
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
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
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
