import SwiftUI

enum MonitorStyle {
    // A fixed dark surround is intentional for picture assessment, in either app appearance.
    static let stage = Color(white: 0.04)
}

/// Audience commands have one stable position, including when Sharing is detached.
struct MonitorCommandBar: View {
    @ObservedObject var model: SessionModel
    private var presentation: AudiencePresentation { model.audiencePresentation }
    var body: some View {
        Group {
            if model.state.sharing || presentation.isChanging { adaptiveCommands }
            else {
                HStack(spacing: 12) { status; Spacer(minLength: 12); AudienceActionButtons(model: model) }
            }
        }.fixedSize(horizontal: false, vertical: true)
            .padding(16).background(Color(nsColor: .windowBackgroundColor))
            .accessibilityElement(children: .contain).accessibilityLabel("Sharing controls")
    }
    private var adaptiveCommands: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { status; audience; Spacer(minLength: 12); AudienceActionButtons(model: model) }
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                status
                audience
                HStack { Spacer(minLength: 0); AudienceActionButtons(model: model) }
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
    private var status: some View {
        Button { model.showSharingStatus() } label: {
            Label { Text(presentation.title).foregroundStyle(.primary) }
                icon: { Image(systemName: presentation.symbol).foregroundStyle(tint) }
                .font(.callout.weight(.semibold)).fixedSize().padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).help("\(outputStatus). Show Sharing details")
            .accessibilityLabel("\(presentation.title). \(outputStatus). Show Sharing details")
    }
    private var outputStatus: String {
        guard presentation.phase == .sharing else { return presentation.outputDetail }
        return "\(model.audiencePreviewPlaying ? "Outgoing picture confirmed" : "Checking outgoing picture"). \(model.audienceHasAudio ? "Sound included" : "No audio track")"
    }
    private var audience: some View {
        HStack(spacing: 12) {
            if model.state.sharing {
                if model.pendingViewers.isEmpty {
                    Button { model.showSharing(.viewers) } label: {
                        Label("\(model.admittedViewers.count) joined", systemImage: "person.2")
                    }.buttonStyle(.plain).foregroundStyle(.secondary).help("Show joined browser sessions and playback health")
                } else {
                    Button("\(model.pendingViewers.count) asking to join") { model.showSharing(.viewers) }
                        .buttonStyle(.link).help("Review viewers asking to join")
                }
                if !model.strugglingViewers.isEmpty {
                    Button { model.showSharing(.viewers) } label: {
                        Label("\(model.strugglingViewers.count) struggling", systemImage: "exclamationmark.circle")
                    }.buttonStyle(.plain).help("Show viewers with playback problems")
                }
                if model.chatUnreadCount > 0 {
                    Button { model.showSharing(.chat) } label: { Label("\(model.chatUnreadCount)", systemImage: "bubble.left") }
                        .buttonStyle(.plain).help("Show unread chat messages").accessibilityLabel("\(model.chatUnreadCount) unread chat messages")
                }
            }
        }.font(.callout).fixedSize()
    }
    private var tint: Color {
        if presentation.needsAttention || presentation.confirmedHold { return .orange }
        return presentation.phase == .sharing ? .green : .primary
    }
}

struct AudienceActionButtons: View {
    @ObservedObject var model: SessionModel
    private var presentation: AudiencePresentation { model.audiencePresentation }
    var body: some View {
        HStack(spacing: 8) {
            if model.busy || presentation.isChanging { ProgressView().controlSize(.small).accessibilityLabel(presentation.title) }
            if model.state.sharing {
                Button { model.performAudienceAction() } label: {
                    Label(presentation.primaryTitle, systemImage: presentation.primarySymbol)
                }.buttonStyle(.bordered).disabled(!presentation.primaryEnabled).help(presentation.primaryHelp)
                if presentation.phase == .failedResume {
                    Button("Hold") { model.setAudienceHold(true) }.disabled(model.busy)
                        .help("Request holding picture and silence instead of resuming")
                }
                Button { model.stopSharing() } label: { Label("Stop Sharing", systemImage: "stop.fill") }
                    .buttonStyle(.bordered).disabled(model.busy).help("End viewer access. Your local monitor continues.")
            } else {
                Button("Start Sharing") { model.startSharing() }.buttonStyle(.borderedProminent)
                    .disabled(!model.canShare || model.busy).keyboardShortcut(.return, modifiers: .command)
            }
        }.fixedSize()
    }
}
