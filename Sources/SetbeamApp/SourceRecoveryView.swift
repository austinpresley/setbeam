import SwiftUI
import SetbeamCore

/// Recovery belongs to the missing picture, so its explanation and next action stay together.
struct SourceRecoveryView: View {
    @ObservedObject var model: SessionModel
    @State private var showingDetails = false
    @AccessibilityFocusState private var recoveryHeadingFocused: Bool

    private var kind: InputKind { model.setup?.kind ?? .sample }
    private var needsWiFi: Bool { kind == .accsoon || kind == .network }
    private var retryIsPrimary: Bool {
        !model.permissionDenied && (model.error != nil || model.wirelessDiscoveryProblem != nil || !needsWiFi && kind != .incoming)
    }
    private var title: String {
        if model.permissionDenied { return model.recoveryTitle }
        if model.busy { return model.connectionStageTitle ?? model.recoveryTitle }
        if model.error != nil { return "Unable to open \(model.sourceLabel)" }
        if kind == .accsoon && !model.state.sourceAvailable { return "Waiting for \(model.sourceLabel)" }
        return model.recoveryTitle
    }
    private var detail: String {
        return model.recoveryDetail
    }
    private var retryDetail: String {
        if kind == .incoming { return "Waiting for incoming video" }
        if kind == .macWindow && model.windowPresence == .closed { return "Choose the window again to continue" }
        return kind == .accsoon ? "Looking for this transmitter automatically" : "Retrying this same source automatically"
    }

    var body: some View {
        if !model.permissionDenied && (kind == .accsoon || model.setup?.networkProfile == .pyroH) {
            TransmitterRecoveryView(model: model)
        } else {
            genericRecovery
        }
    }

    private var genericRecovery: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: model.permissionDenied ? "lock.display" : kind == .accsoon ? "antenna.radiowaves.left.and.right" : "cable.connector")
                        .font(.system(size: 36, weight: .regular)).foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($recoveryHeadingFocused)
                        Text(detail).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    actions
                    if model.busy {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.connectionStageTitle ?? "Opening the selected picture") }
                            .font(.caption).foregroundStyle(.secondary)
                    } else if model.state.monitoring && !model.permissionDenied && !windowClosed {
                        Label(retryDetail,
                              systemImage: needsWiFi ? "wifi" : "arrow.clockwise")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text(model.audiencePresentation.sourceRecoveryDetail).font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Connection details", isExpanded: $showingDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let error = model.error, !model.permissionDenied { Text(error).foregroundStyle(.primary) }
                            if let stage = model.connectionStageTitle { Text(stage) }
                            if model.lastFrameAt != nil { Text(model.frameAgeLabel) }
                            if !model.busy && !retryIsPrimary && !model.permissionDenied && !windowClosed { Button("Retry Now") { model.retry() } }
                            if needsWiFi && (model.error != nil || model.wirelessDiscoveryProblem != nil) {
                                Button("Open Wi-Fi Settings") { model.openWiFiSettings() }
                            }
                            if kind == .network { Button("Edit Stream Address…") { model.openNetworkSource() } }
                            if let previous = model.previousSourceName {
                                Button("Return to \(previous)") { model.returnToPreviousSource() }
                            }
                            if let saved = model.provenSetup, saved.id != model.setup?.id {
                                Button("Use Last Working Setup") { model.restore(saved) }
                            }
                        }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center).frame(maxWidth: 440)
                .padding(20).frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height))
            }
        }
        .task { if model.permissionDenied { recoveryHeadingFocused = true } }
        .background(MonitorStyle.stage)
        .accessibilityElement(children: .contain).accessibilityLabel("Source recovery")
    }

    @ViewBuilder private var actions: some View {
        if model.permissionDenied {
            SourcePermissionActions(model: model, offersSourceChooser: true)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { primaryAction; if !windowClosed { chooseSource } }
                VStack(spacing: 8) { primaryAction; if !windowClosed { chooseSource } }
            }.disabled(model.busy)
        }
    }
    private var windowClosed: Bool { kind == .macWindow && model.windowPresence == .closed }

    @ViewBuilder private var primaryAction: some View {
        if windowClosed {
            Button("Choose a Window…") { model.openSources(category: .windows) }.buttonStyle(.borderedProminent)
        } else if retryIsPrimary {
            Button("Retry Now") { model.retry() }.buttonStyle(.borderedProminent)
        } else if needsWiFi {
            Button("Open Wi-Fi Settings") { model.openWiFiSettings() }.buttonStyle(.borderedProminent)
        } else if kind == .incoming {
            Button("Open Accsoon SEE Setup…") { model.present(.incoming) }.buttonStyle(.borderedProminent)
        } else {
            Button("Retry Now") { model.retry() }.buttonStyle(.borderedProminent)
        }
    }
    private var chooseSource: some View {
        Button("Choose Another Source…") { model.openSources() }.buttonStyle(.bordered)
    }
}

struct SourcePermissionActions: View {
    @ObservedObject var model: SessionModel
    var offersSourceChooser = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { actions }.fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 8) { actions }
        }.disabled(model.busy)
    }

    @ViewBuilder private var actions: some View {
        if let request = model.deniedSourceRequest {
            Button("Open \(request.permission.title) Settings") { model.openPrivacySettings() }
                .accessibilityHint("Open Privacy & Security in System Settings")
            Button("Retry Now") { model.retry() }
                .accessibilityHint("Retry \(request.candidate.name)")
            if offersSourceChooser {
                Button("Choose Another Source…") { model.openSources() }
            }
        }
    }
}
