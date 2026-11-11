import SwiftUI
import SetbeamCore

/// Recovery belongs to the missing picture, so its explanation and next action stay together.
struct SourceRecoveryView: View {
    @ObservedObject var model: SessionModel
    @State private var showingDetails = false

    private var kind: InputKind { model.setup?.kind ?? .sample }
    private var needsWiFi: Bool { kind == .accsoon || kind == .network }
    private var retryIsPrimary: Bool {
        !model.permissionDenied && (model.error != nil || model.wirelessDiscoveryProblem != nil || !needsWiFi && kind != .incoming)
    }
    private var title: String {
        if model.permissionDenied { return "Allow access to your selected input" }
        if model.busy { return model.connectionStageTitle ?? model.recoveryTitle }
        if model.error != nil { return "Unable to open \(model.sourceLabel)" }
        if kind == .accsoon && !model.state.sourceAvailable { return "Waiting for \(model.sourceLabel)" }
        return model.recoveryTitle
    }
    private var detail: String {
        if model.permissionDenied, let error = model.error { return error }
        return model.recoveryDetail
    }
    private var retryDetail: String {
        if kind == .incoming { return "Waiting for incoming video" }
        if kind == .macWindow && model.windowPresence == .closed { return "Choose the window again to continue" }
        return kind == .accsoon ? "Looking for this transmitter automatically" : "Retrying this same source automatically"
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: model.permissionDenied ? "lock.display" : kind == .accsoon ? "antenna.radiowaves.left.and.right" : "cable.connector")
                        .font(.system(size: 36, weight: .regular)).foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Text(detail).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    actions
                    if model.busy {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.connectionStageTitle ?? "Opening the selected picture") }
                            .font(.caption).foregroundStyle(.secondary)
                    } else if model.state.monitoring && !model.permissionDenied {
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
                            if !model.busy && !retryIsPrimary { Button("Retry Now") { model.retry() } }
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
        .background(MonitorStyle.stage)
        .accessibilityElement(children: .contain).accessibilityLabel("Source recovery")
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { primaryAction; chooseSource }
            VStack(spacing: 8) { primaryAction; chooseSource }
        }.disabled(model.busy)
    }
    @ViewBuilder private var primaryAction: some View {
        if model.permissionDenied {
            Button("Open Privacy Settings") { model.openPrivacySettings() }.buttonStyle(.borderedProminent)
        } else if retryIsPrimary {
            Button("Retry Now") { model.retry() }.buttonStyle(.borderedProminent)
        } else if needsWiFi {
            Button("Open Wi-Fi Settings") { model.openWiFiSettings() }.buttonStyle(.borderedProminent)
        } else if kind == .incoming {
            Button("Open Accsoon Setup…") { model.present(.incoming) }.buttonStyle(.borderedProminent)
        } else {
            Button("Retry Now") { model.retry() }.buttonStyle(.borderedProminent)
        }
    }
    private var chooseSource: some View {
        Button("Choose Another Source…") { model.openSources() }.buttonStyle(.bordered)
    }
}
