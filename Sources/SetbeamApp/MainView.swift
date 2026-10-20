import SwiftUI
import AppKit
import SetbeamCore

struct MainView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 21) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.title.isEmpty ? "Feed" : model.title).font(.system(size: 23, weight: .semibold)).lineLimit(1)
                        Button { model.loadPrivateSettings(); model.sheet = .connection } label: {
                            HStack(spacing: 5) { Text(model.sourceLabel).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)) }.font(.caption).foregroundStyle(.secondary)
                        }.buttonStyle(.plain).help("Source and viewing network")
                    }
                    Spacer(minLength: 16)
                    VStack(alignment: .trailing, spacing: 7) {
                        HStack(spacing: 6) {
                            if model.busy { ProgressView().controlSize(.mini) } else { Circle().fill(statusColor).frame(width: 6, height: 6) }
                            Text(model.statusLabel).font(.caption).foregroundStyle(statusColor)
                        }
                        Button { model.sheet = .viewers } label: { Label("\(model.viewers.count) \(model.viewers.count == 1 ? "viewer" : "viewers")", systemImage: "person.2.fill").font(.caption).foregroundStyle(.secondary) }.buttonStyle(.plain)
                    }
                }
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        ZStack(alignment: .topLeading) {
                            PlayerView(player: model.localPlayer)
                            VStack {
                                HStack { Label(model.source == .sample ? "Sample feed" : "Local preview", systemImage: "circle.fill").font(.system(size: 10)).labelStyle(.titleAndIcon).padding(.horizontal, 7).padding(.vertical, 4).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5)); Spacer() }
                                Spacer()
                                HStack(alignment: .bottom) {
                                    if !model.state.sourceAvailable && model.state.monitoring { Text("Waiting for source video").font(.caption2).padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)) }
                                    else if model.state.holding { Text("Audience on hold. Your preview stays live.").font(.caption2).foregroundStyle(.primary).padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)) }
                                    Spacer()
                                    Button { model.localMuted.toggle() } label: { Image(systemName: model.localMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.caption).frame(width: 27, height: 27) }.buttonStyle(.plain).background(.thinMaterial, in: Circle()).help(model.localMuted ? "Enable local sound" : "Mute local preview")
                                }
                            }.padding(10).foregroundStyle(.white)
                        }.aspectRatio(16.0 / 9, contentMode: .fit).background(.black).clipShape(RoundedRectangle(cornerRadius: 9))
                        HStack {
                            Button { model.togglePiP() } label: { Label(model.pipVisible ? "Hide floating preview" : "Pop out preview", systemImage: "pip.enter") }.controlSize(.small).disabled(model.preview == nil)
                            Spacer()
                            Button("Save frame") { model.saveFrame() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).disabled(!model.state.sourceAvailable)
                        }
                        Button { model.sheet = .viewers } label: {
                            Label(connectionLabel, systemImage: model.verifiedViewers > 0 ? "checkmark.circle.fill" : "circle.dashed").font(.caption2).foregroundStyle(.secondary)
                        }.buttonStyle(.plain).padding(.top, 3)
                        if let message = model.error {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message).font(.caption).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                                    HStack { Button("Connection settings") { model.loadPrivateSettings(); model.sheet = .connection }; Button("Copy diagnostics") { model.diagnostics() } }.buttonStyle(.link).font(.caption2)
                                }
                                Spacer()
                                Button { model.error = nil } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain).foregroundStyle(.secondary)
                            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }.frame(maxWidth: .infinity)
                    VStack(spacing: 12) {
                        Text(model.state.sharing ? "Scan to watch" : "Share this feed").font(.system(size: 14, weight: .semibold))
                        if model.state.sharing, let url = model.viewerURL {
                            QRView(payload: url.absoluteString, size: 156)
                            Text(model.wifiSSID.isEmpty ? "Viewers join the same network as this Mac." : "On \(model.wifiSSID)?\nScan with your phone to watch.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            Button { model.copyLink() } label: { Label("Copy link", systemImage: "link").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.regular)
                            Button("Show join codes") { model.sheet = .join }.buttonStyle(.link).font(.caption2)
                        } else {
                            Image(systemName: "qrcode").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary).frame(width: 156, height: 156).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                            Text("Your preview stays private until you start sharing.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button { model.startSharing() } label: { Text("Start sharing").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(!model.state.monitoring || model.busy).keyboardShortcut(.return, modifiers: .command)
                        }
                        if model.viewerAddress == "127.0.0.1" { Text("This Mac only. Choose a LAN in connection settings for phones.").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    }.frame(width: 184).padding(.top, 2)
                }
            }.padding(24)
            Spacer(minLength: 10)
            Divider()
            HStack {
                Button { model.loadPrivateSettings(); model.sheet = .connection } label: { Label(model.viewerNetworkLabel, systemImage: "wifi").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }.buttonStyle(.plain)
                Spacer(minLength: 10)
                if model.state.sharing {
                    Button { model.toggleHold() } label: { Label(model.state.holding ? "Resume sharing" : "Hold audience", systemImage: model.state.holding ? "play.fill" : "pause.fill") }.controlSize(.small).disabled(model.busy)
                    Button("Stop sharing") { model.stopSharing() }.buttonStyle(.plain).foregroundStyle(.secondary).font(.caption).disabled(model.busy)
                }
            }.padding(.horizontal, 24).padding(.vertical, 13).background(.bar)
        }.frame(minWidth: 740, idealWidth: 820, minHeight: 500)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { model.loadPrivateSettings(); model.sheet = .connection } label: { Image(systemName: "ellipsis") }.help("Source and connection settings") } }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .connection: ConnectionView(model: model)
            case .join: JoinCodesView(model: model)
            case .viewers: ViewerStatusView(model: model)
            case .about: AboutView(model: model)
            }
        }
        .onAppear { model.launch() }
    }
    private var statusColor: Color { model.state.holding || !model.state.sourceAvailable ? .orange : model.state.sharing ? .green : .secondary }
    private var connectionLabel: String {
        if model.verifiedViewers > 0 { return "Playback confirmed on \(model.verifiedViewers) \(model.verifiedViewers == 1 ? "viewer" : "viewers")" }
        if model.state.sharing { return "Waiting for a viewer to confirm playback" }
        return model.nativePreviewPlaying ? "Local preview playing" : model.state.sourceAvailable ? "Feed received; connecting local preview" : "Waiting for source video"
    }
}

struct QRView: View {
    let payload: String
    let size: CGFloat
    @State private var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage: image).resizable().interpolation(.none).scaledToFit() } else { ProgressView() } }
            .frame(width: size - 32, height: size - 32).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 10))
            .task(id: payload) { image = QRCode.image(payload) }
            .accessibilityLabel("QR code")
    }
}
