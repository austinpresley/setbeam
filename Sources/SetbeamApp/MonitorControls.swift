import SwiftUI

enum MonitorStyle {
    static let stage = Color(white: 0.04)
}

struct SharingTally: View {
    @ObservedObject var model: SessionModel
    @State private var expanded = false
    private var sharing: AudiencePresentation { model.audiencePresentation }

    var body: some View {
        Button {
            if sharing.phase == .privateMonitoring { model.startSharing() }
            else { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                tallySymbol
                Text(title).font(.system(size: 12, weight: .bold)).tracking(hasTallyColor ? 0.7 : 0)
                if model.canStopSharing {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12).frame(height: 28)
            .background(background, in: Capsule())
            .overlay { Capsule().strokeBorder(.primary.opacity(hasTallyColor ? 0 : 0.18), lineWidth: 1) }
            .contentShape(Capsule())
        }.buttonStyle(.plain)
            .disabled(sharing.phase == .privateMonitoring && !model.canShare)
            .opacity(sharing.phase == .privateMonitoring && !model.canShare ? 0.45 : 1)
            .help(sharing.phase == .privateMonitoring ? "Go Live · Start sharing this picture with viewers" : "\(sharing.title) · \(outputStatus)")
            .accessibilityLabel(title)
            .accessibilityValue(sharing.phase == .privateMonitoring ? "Private" : outputStatus)
            .popover(isPresented: $expanded, arrowEdge: .bottom) { sharingActions }
            .onChange(of: model.state.sharing) { _, active in if !active { expanded = false } }
    }

    private var title: String {
        switch sharing.phase {
        case .privateMonitoring: return "Go Live"
        case .sharing: return "LIVE"
        case .holding: return "HOLD"
        case .starting: return "Going Live"
        case .stopping: return "Stopping"
        case .applyingHold: return "Applying Hold"
        case .resuming: return "Resuming"
        case .failedHold, .failedResume: return "Check Sharing"
        case .reconnecting: return "Reconnecting"
        }
    }

    private var hasTallyColor: Bool { sharing.phase == .sharing || sharing.confirmedHold }
    private var foreground: Color {
        if sharing.phase == .sharing { return .white }
        if sharing.confirmedHold { return SetbeamChrome.onAmber }
        return .primary
    }
    private var background: Color {
        if sharing.phase == .sharing { return SetbeamChrome.red }
        if sharing.confirmedHold { return SetbeamChrome.amber }
        return SetbeamChrome.raised
    }
    private var outputStatus: String {
        sharing.visibleOutputDetail(pictureConfirmed: model.audiencePreviewPlaying, hasAudio: model.audienceHasAudio)
    }

    @ViewBuilder private var tallySymbol: some View {
        if sharing.isChanging {
            ProgressView().controlSize(.mini).accessibilityHidden(true)
        } else if sharing.phase == .privateMonitoring {
            Circle().strokeBorder(SetbeamChrome.red, lineWidth: 2).frame(width: 10, height: 10)
        } else if sharing.phase == .sharing {
            Circle().fill(.white).frame(width: 8, height: 8)
                .background(.white.opacity(0.28), in: Circle().inset(by: -3))
        } else {
            Image(systemName: sharing.confirmedHold ? "pause.fill" : sharing.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(sharing.needsAttention ? SetbeamChrome.amberText : foreground)
        }
    }

    private var sharingActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sharing.title).font(.headline)
                Text(outputStatus).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if model.state.sharing {
                Button { model.performAudienceAction(); expanded = false } label: {
                    Label(sharing.primaryTitle, systemImage: sharing.primarySymbol)
                }.disabled(!sharing.primaryEnabled).help(sharing.primaryHelp)
                if sharing.phase == .failedResume {
                    Button { model.setAudienceHold(true); expanded = false } label: { Label("Hold", systemImage: "pause.fill") }
                        .disabled(model.busy)
                }
                Button { model.showSharing(.invite); expanded = false } label: { Label("Invite viewers", systemImage: "qrcode") }
            }
            if model.canStopSharing || model.stoppingSharing {
                Button { model.stopSharing(); expanded = false } label: { Label("Stop Sharing", systemImage: "stop.fill") }
                    .disabled(!model.canStopSharing).help("End viewer access. Your local monitor continues.")
            }
        }.padding(16).frame(minWidth: 244, alignment: .leading)
    }
}

struct ToolbarPeople: View {
    @ObservedObject var model: SessionModel
    @State private var requestsExpanded = false
    private let maxAvatars = 2

    var body: some View {
        HStack(spacing: 4) {
            Button { model.showSharing(.viewers) } label: {
                HStack(spacing: -5) {
                    if model.admittedViewers.isEmpty {
                        Image(systemName: "person.2").font(.system(size: 16)).foregroundStyle(.secondary)
                            .frame(width: 32, height: 28)
                    } else {
                        ForEach(model.admittedViewers.prefix(maxAvatars)) { viewer in
                            ViewerAvatar(viewer: viewer, holding: model.audiencePresentation.confirmedHold, size: 24)
                        }
                        if model.admittedViewers.count > maxAvatars {
                            Text("+\(model.admittedViewers.count - maxAvatars)")
                                .font(.caption2.weight(.semibold)).monospacedDigit().padding(.leading, 10).padding(.trailing, 2)
                        }
                    }
                }.frame(height: 28).contentShape(Rectangle())
            }.buttonStyle(ChromeButtonStyle())
                .help("\(model.admittedViewers.count) joined · \(model.verifiedViewers) playing · Show people")
                .accessibilityLabel("People").accessibilityValue("\(model.admittedViewers.count) joined, \(model.verifiedViewers) playing")
            if let first = model.pendingViewers.first {
                Button { requestsExpanded.toggle() } label: {
                    ViewerAvatar(viewer: first, size: 24)
                        .overlay(alignment: .bottomTrailing) {
                            Group {
                                if model.pendingViewers.count > 1 {
                                    Text("\(model.pendingViewers.count)").monospacedDigit()
                                } else {
                                    Image(systemName: "hand.raised.fill")
                                }
                            }.font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(SetbeamChrome.onAmber).frame(width: 16, height: 16)
                                .background(SetbeamChrome.amber, in: Circle())
                                .background(SetbeamChrome.toolbar, in: Circle().inset(by: -1))
                                .offset(x: 5, y: 4)
                        }
                        .padding(.horizontal, 4).frame(height: 28).contentShape(Rectangle())
                }.buttonStyle(ChromeButtonStyle()).padding(.trailing, 4)
                    .help("Review \(model.pendingViewers.count) join requests")
                    .accessibilityLabel("Join requests").accessibilityValue("\(model.pendingViewers.count) waiting")
                    .popover(isPresented: $requestsExpanded, arrowEdge: .bottom) {
                        let visibleCount = min(4, model.pendingViewers.count)
                        let rows = VStack(spacing: 8) {
                            ForEach(model.pendingViewers) { viewer in
                                ViewerRequestRow(model: model, viewer: viewer, framed: false)
                            }
                        }.padding(.horizontal, 8).padding(.vertical, 4)
                        if model.pendingViewers.count > visibleCount {
                            ScrollView { rows }
                                .frame(width: 244, height: CGFloat(visibleCount * 48 + (visibleCount - 1) * 8 + 8))
                        } else {
                            rows.frame(width: 244)
                        }
                    }
            }
        }.fixedSize()
            .onChange(of: model.pendingViewers.isEmpty) { _, empty in if empty { requestsExpanded = false } }
    }
}
