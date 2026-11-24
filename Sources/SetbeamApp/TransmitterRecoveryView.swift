import SwiftUI
import SetbeamCore

struct TransmitterRecoveryView: View {
    @ObservedObject var model: SessionModel
    @State private var details = false

    private var transmitterFound: Bool {
        if let id = model.setup?.wirelessUID, model.wirelessDevices.contains(where: { $0.id == id }) { return true }
        return model.state.sourceAvailable || [.connectingTransmitter, .waitingForPicture, .openingPreview].contains(model.connectionStage)
            && model.setup?.kind == .accsoon
    }
    private var wifiName: String { model.setup?.sourceWiFi.isEmpty == false ? model.setup?.sourceWiFi ?? "Transmitter Wi-Fi" : "Transmitter Wi-Fi" }
    private var wifiStatus: StepStatus {
        if transmitterFound { return .done }
        guard let onTarget = model.isOnSourceWiFi else { return .attention }
        return onTarget ? .done : .missing
    }
    private var connectionStatus: StepStatus {
        if model.error != nil || model.wirelessDiscoveryProblem != nil && wifiStatus == .done { return .attention }
        if model.busy || wifiStatus == .done { return .working }
        return .waiting
    }
    private var connectionLabel: String {
        if model.error != nil { return "Retry connection" }
        if needsSourcePicture { return "Waiting for source video" }
        if transmitterFound { return model.connectionStageTitle ?? "Waiting for picture" }
        return "Auto-connect"
    }

    private var needsSourcePicture: Bool {
        model.wirelessDevices.contains { $0.id == model.setup?.wirelessUID && !$0.videoAvailable }
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ScrollView {
                    recovery.frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
            footer
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain).accessibilityLabel("Transmitter recovery")
    }

    private var recovery: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40, weight: .light)).foregroundStyle(.white.opacity(0.89))
                .accessibilityHidden(true)
            checklist
            if let problem = model.pyroHRouteProblem {
                Text(problem).font(.callout).multilineTextAlignment(.center).frame(maxWidth: 440)
            } else if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else if needsSourcePicture {
                Text("Wake the computer or camera feeding the transmitter, or check its input cable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if wifiStatus != .done {
                    Button { model.openWiFiSettings() } label: { Label("Open Wi-Fi Settings", systemImage: "wifi") }
                        .buttonStyle(.borderedProminent).help("Join \(wifiName) in Wi-Fi Settings")
                } else {
                    Button { model.retry() } label: { Label("Retry Now", systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderedProminent).disabled(model.busy)
                }
                ChromeIconButton("Choose another source", symbol: "arrow.left.arrow.right") { model.openSources() }
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(model.busy)
            }
        }.padding(.vertical, 8).multilineTextAlignment(.center)
    }

    private var checklist: some View {
        HStack(alignment: .top, spacing: 0) {
            step("Power on", symbol: "power", status: transmitterFound ? .done : .unknown)
            connector
            step(wifiName, symbol: "wifi", status: wifiStatus)
            connector
            step(connectionLabel, symbol: "magnifyingglass", status: connectionStatus)
        }
    }

    private var connector: some View {
        Rectangle().fill(.white.opacity(0.18)).frame(width: 40, height: 2).padding(.top, 25)
            .accessibilityHidden(true)
    }

    private func step(_ title: String, symbol: String, status: StepStatus) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(status.highlighted ? SetbeamChrome.amber.opacity(0.16) : .white.opacity(0.08))
                Circle().strokeBorder(status.highlighted ? SetbeamChrome.amber : .white.opacity(0.16), lineWidth: 1)
                if status == .working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).font(.system(size: 23))
                        .foregroundStyle(status.highlighted ? SetbeamChrome.amberText : .white.opacity(status == .waiting ? 0.52 : 0.88))
                }
            }.frame(width: 52, height: 52)
                .overlay(alignment: .bottomTrailing) { stepBadge(status) }
            Text(title).font(.caption.weight(status.highlighted ? .semibold : .regular))
                .foregroundStyle(.white.opacity(status.highlighted ? 1 : 0.76)).lineLimit(2)
                .multilineTextAlignment(.center)
        }.frame(width: 128)
            .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(status.label)
    }

    @ViewBuilder private func stepBadge(_ status: StepStatus) -> some View {
        if let symbol = status.badge {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .foregroundStyle(status.highlighted ? .black : .white)
                .frame(width: 20, height: 20)
                .background(status.highlighted ? SetbeamChrome.amber : status == .done ? SetbeamChrome.greenText : Color(white: 0.23), in: Circle())
                .background(MonitorStyle.stage, in: Circle().inset(by: -2))
        }
    }

    private var footer: some View {
        HStack {
            Label(model.audiencePresentation.title, systemImage: model.audiencePresentation.symbol)
                .font(.caption).foregroundStyle(.white.opacity(0.62))
                .help(model.audiencePresentation.sourceRecoveryDetail)
            Spacer()
            ChromeIconButton("Connection details", symbol: "info.circle") { details.toggle() }
                .foregroundStyle(.white.opacity(0.62))
                .popover(isPresented: $details, arrowEdge: .top) { recoveryDetails }
        }
    }

    private var recoveryDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.recoveryTitle).font(.headline)
            Text(model.recoveryDetail).foregroundStyle(.secondary)
            if let problem = model.rejoinProblem { Text(problem).foregroundStyle(.secondary) }
            if let stage = model.connectionStageTitle { Text(stage).foregroundStyle(.secondary) }
            if model.lastFrameAt != nil { Text(model.frameAgeLabel).foregroundStyle(.secondary) }
            Divider()
            Text(model.audiencePresentation.sourceRecoveryDetail).foregroundStyle(.secondary)
            if wifiStatus != .done { Button("Retry Now") { model.retry() }.disabled(model.busy) }
            if model.setup?.kind == .network, model.setup?.networkProfile != .pyroH {
                Button("Edit Stream Address…") { model.openNetworkSource() }
            }
            if let previous = model.previousSourceName {
                Button("Return to \(previous)") { model.returnToPreviousSource() }.disabled(model.busy)
            }
            if let saved = model.provenSetup, saved.id != model.setup?.id {
                Button("Use Last Working Setup") { model.restore(saved) }.disabled(model.busy)
            }
        }.font(.callout).padding(16).frame(width: 320, alignment: .leading)
    }

    private enum StepStatus {
        case unknown, missing, attention, waiting, working, done

        var highlighted: Bool { self == .missing || self == .attention }
        var label: String {
            switch self {
            case .unknown: return "Unconfirmed"
            case .missing: return "Not joined"
            case .attention: return "Check this step"
            case .waiting: return "Waiting"
            case .working: return "Connecting"
            case .done: return "Confirmed"
            }
        }
        var badge: String? {
            switch self {
            case .unknown: return "questionmark"
            case .missing: return "xmark"
            case .attention: return "exclamationmark"
            case .done: return "checkmark"
            default: return nil
            }
        }
    }
}
