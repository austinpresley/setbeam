import SwiftUI

enum MonitorStyle {
    static let stage = Color(white: 0.04)
}

struct SharingTally: View {
    @ObservedObject var model: SessionModel
    private var sharing: AudiencePresentation { model.audiencePresentation }
    private var expanded: Binding<Bool> {
        Binding(get: { model.audienceControlsShown }, set: { model.audienceControlsShown = $0 })
    }

    var body: some View {
        HStack(spacing: 2) {
            tally
            if sharing.phase == .privateMonitoring && !model.canStopSharing {
                // Before going live, the same options are one click away without starting anything.
                Button { model.showAudienceControls() } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 13))
                        .foregroundStyle(.secondary).frame(width: 26, height: 28).contentShape(Rectangle())
                }.buttonStyle(ChromeButtonStyle()).help("Audience options").accessibilityLabel("Audience options")
            }
        }.popover(isPresented: expanded, arrowEdge: .bottom) {
            AudienceControlsView(model: model) { model.audienceControlsShown = false }
        }
    }

    private var tally: some View {
        Button {
            if sharing.phase == .privateMonitoring { model.startSharing() }
            else { model.audienceControlsShown.toggle() }
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
            .accessibilityHint(sharing.phase == .privateMonitoring ? "" : "Opens Hold, Stop Sharing and audience options")
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

}

struct ToolbarPeople: View {
    @ObservedObject var model: SessionModel
    @State private var requestsExpanded = false
    @AccessibilityFocusState private var peopleFocused: Bool
    private let maxAvatars = 2

    var body: some View {
        HStack(spacing: 4) {
            Button { model.showSharing(.viewers) } label: {
                HStack(spacing: -5) {
                    if model.admittedViewers.isEmpty {
                        Image(systemName: "qrcode").font(.system(size: 16)).foregroundStyle(.secondary)
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
                .help(model.admittedViewers.isEmpty ? "Invite viewers" : "\(model.admittedViewers.count) joined · \(model.verifiedViewers) playing · Show people")
                .accessibilityLabel("People").accessibilityFocused($peopleFocused).accessibilityValue("\(model.admittedViewers.count) joined, \(model.verifiedViewers) playing")
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
                                ViewerRequestRow(model: model, viewer: viewer, framed: false) {
                                    requestsExpanded = false; peopleFocused = true
                                }
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
