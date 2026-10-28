import SwiftUI

struct MonitorJoinCodesPanel: View {
    static let width: CGFloat = 232
    static let spacing: CGFloat = 20
    static let extraWidth = width + spacing

    @ObservedObject var model: SessionModel
    let editWiFi: () -> Void

    var body: some View {
        if !model.canInviteOtherDevices {
            ViewingNetworkRequiredView(model: model).frame(maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                let sectionHeight = (geometry.size.height - 16) / 2
                let codeSize = floor(min(Self.width, max(64, sectionHeight - 74)))
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Text("1. Join Wi-Fi").font(.headline)
                        if model.wifiSSID.isEmpty {
                            placeholder("wifi", text: "Add your viewing Wi-Fi", size: codeSize)
                        } else {
                            QRView(payload: QRCode.wifi(ssid: model.wifiSSID, password: model.wifiPassword), size: codeSize)
                                .accessibilityLabel("Wi-Fi join QR code for \(model.wifiSSID)")
                        }
                        Button(action: editWiFi) {
                            HStack(spacing: 5) {
                                Text(model.wifiSSID.isEmpty ? "Add Wi-Fi…" : model.wifiSSID).lineLimit(1).truncationMode(.middle)
                                if !model.wifiSSID.isEmpty { Image(systemName: "pencil").font(.caption2) }
                            }
                        }.buttonStyle(.link).font(.caption)
                            .help(model.wifiSSID.isEmpty ? "Add the Wi-Fi name and password for viewers" : "Edit viewing Wi-Fi")
                            .accessibilityLabel(model.wifiSSID.isEmpty ? "Add viewing Wi-Fi" : "Edit viewing Wi-Fi. \(model.wifiSSID)")
                            .frame(height: 28)
                    }.frame(maxWidth: .infinity).frame(height: sectionHeight)

                    VStack(spacing: 8) {
                        Text("2. Watch the feed").font(.headline)
                        if model.state.sharing, let url = model.viewerURL {
                            QRView(payload: url.absoluteString, size: codeSize)
                                .accessibilityLabel("Viewing QR code. Join the viewing Wi-Fi, then scan to watch.")
                        } else {
                            placeholder("lock", text: "Sharing is off", size: codeSize)
                        }
                        if model.state.sharing {
                            VStack(spacing: 2) {
                                Button(action: model.copyLink) {
                                    Label(model.copiedLink ? "Link copied" : "Copy viewing link", systemImage: model.copiedLink ? "checkmark" : "link")
                                }.buttonStyle(.link).font(.caption).disabled(model.viewerURL == nil)
                                    .help(model.viewingInstructions)
                            }.frame(height: 28)
                        } else {
                            Text("Start sharing to invite viewers").font(.caption).foregroundStyle(.secondary)
                                .frame(height: 28)
                        }
                    }.frame(maxWidth: .infinity).frame(height: sectionHeight)
                }
            }.accessibilityElement(children: .contain).accessibilityLabel("Join codes")
        }
    }

    private func placeholder(_ symbol: String, text: String, size: CGFloat) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(12).frame(width: size, height: size)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ViewingNetworkRequiredView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock").font(.title2).foregroundStyle(.secondary)
            Text("Viewing is limited to this Mac").font(.headline)
            Text("Choose a network to invite phones and other computers.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Choose viewing network…") { model.openAdvanced(section: .network) }
                .buttonStyle(.borderedProminent)
            Text("Your local monitor continues.").font(.caption).foregroundStyle(.secondary)
        }.multilineTextAlignment(.center).padding(.vertical, 16)
    }
}
