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
            .padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 56)
            .background(Color(nsColor: .windowBackgroundColor))
            .accessibilityElement(children: .contain).accessibilityLabel("Sharing controls")
    }
    private var adaptiveCommands: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { status; audience; Spacer(minLength: 12); AudienceActionButtons(model: model) }
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) { status; Spacer(minLength: 8); requests; AudienceActionButtons(model: model) }
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
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: presentation.symbol).foregroundStyle(tint).font(.callout).frame(width: 12).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    if model.state.sharing || presentation.isChanging {
                        Text(outputStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.fixedSize().contentShape(Rectangle())
        }.buttonStyle(.plain).help("\(outputStatus). Show Sharing details")
            .accessibilityLabel("\(presentation.title). \(outputStatus). Show Sharing details")
    }
    private var outputStatus: String {
        presentation.visibleOutputDetail(pictureConfirmed: model.audiencePreviewPlaying, hasAudio: model.audienceHasAudio)
    }
    private var audience: some View {
        HStack(spacing: 12) {
            if model.state.sharing {
                Button { model.showSharing(.viewers) } label: {
                    Label("\(model.admittedViewers.count) joined · \(model.verifiedViewers) playing", systemImage: "person.2")
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("Show joined browser sessions and fresh playback health")
                requests
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
    @ViewBuilder private var requests: some View {
        if !model.pendingViewers.isEmpty {
            Button("\(model.pendingViewers.count) waiting") { model.showSharing(.viewers) }
                .buttonStyle(.link).font(.callout).help("Review viewers asking to join")
                .accessibilityLabel("\(model.pendingViewers.count) viewers asking to join")
        }
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
