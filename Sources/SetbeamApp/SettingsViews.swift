import SwiftUI
import AppKit
import SetbeamCore

struct HardwareArtwork: View {
    let symbol: String
    var size: CGFloat = 44
    var body: some View {
        Group {
            if symbol == "accsoon.master" {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).stroke(lineWidth: 1.6).frame(width: size * 0.42, height: size * 0.48).offset(y: size * 0.07)
                    HStack(spacing: size * 0.07) { ForEach(0..<4) { _ in Capsule().frame(width: size * 0.035, height: size * 0.22) } }.offset(y: -size * 0.25)
                    RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.5)).frame(width: size * 0.24, height: size * 0.11).offset(y: size * 0.05)
                }
            } else if symbol == "hollyland.pyro" {
                // A drawn compact transmitter body with its status screen and HDMI input; not a product photo.
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.08).stroke(lineWidth: 1.6).frame(width: size * 0.6, height: size * 0.4)
                    RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.5)).frame(width: size * 0.22, height: size * 0.14).offset(x: -size * 0.1)
                    Circle().stroke(lineWidth: 1.4).frame(width: size * 0.1, height: size * 0.1).offset(x: size * 0.14)
                    RoundedRectangle(cornerRadius: 1).frame(width: size * 0.16, height: size * 0.05).offset(y: size * 0.22)
                }
            } else { Image(systemName: symbol).font(.system(size: size * 0.56, weight: .regular)) }
        }
            .foregroundStyle(.secondary).frame(width: size, height: size)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: size * 0.23))
            .accessibilityHidden(true)
    }
}

struct IncomingSetupView: View {
    @ObservedObject var model: SessionModel
    @State private var ssid = ""
    @State private var showDetails = true
    @State private var copied = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                HardwareArtwork(symbol: "antenna.radiowaves.left.and.right", size: 58)
                VStack(alignment: .leading, spacing: 5) { Text("CineView Master 4K").font(.title2.weight(.semibold)); Text("Connect through Accsoon SEE").font(.callout).foregroundStyle(.secondary) }
            }
            if model.localReady {
                Label("Picture confirmed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(model.audiencePresentation.incomingReadyDetail).font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    step("wifi", "Join the transmitter's Wi-Fi", "Power the transmitter and connect its HDMI or SDI input. Join the 5 GHz Wi-Fi shown on its display, usually Accsoon_ followed by the unit's four characters.")
                    TextField("Wi-Fi name", text: $ssid, prompt: Text("Optional. Remember the name for next time.")).textFieldStyle(.roundedBorder)
                    Button("Open Wi-Fi Settings") { model.openWiFiSettings() }.buttonStyle(.link)
                    step("play.rectangle", "Open your picture in Accsoon SEE", "Choose CineView Master 4K and start monitoring. A picture in SEE confirms the transmitter connection first.")
                    step("arrow.down.to.line", "Send the picture to Setbeam", "In SEE's Control Center, choose Push Stream, select RTMP, and use the connection details below. Then start streaming.")
                }
            }
            DisclosureGroup("Connection details for Accsoon SEE", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Paste these into Accsoon SEE. Keep the stream key private.").font(.caption).foregroundStyle(.secondary)
                    HStack { Text(model.incomingServer).font(.callout).textSelection(.enabled); Spacer(); Button(copied == "server" ? "Copied" : "Copy server") { copy(model.incomingServer, label: "server") } }
                    HStack { Text("Private stream key").font(.callout); Spacer(); Button(copied == "key" ? "Copied" : "Copy stream key") { copy(model.incomingStreamKey, label: "key") } }
                    if IncomingDestination.isLocalOnly(model.incomingServer) { Text("The destination currently works on this Mac only. Join the transmitter's network to receive a stream from another device.").font(.caption).foregroundStyle(.secondary) }
                }.padding(.top, 10)
            }
            Text("This is a candidate connection route. Receiving sample video does not establish CineView hardware compatibility.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose another source") { model.openSources() }
                Spacer(); Button("Done") { model.rememberSourceWiFi(ssid); model.sheet = nil }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 550).onAppear { ssid = model.setup?.sourceWiFi ?? "" }
    }
    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 25)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.callout.weight(.medium)); Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func copy(_ value: String, label: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string); copied = label
    }
}

struct AboutView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                Image(nsImage: AppAssets.icon ?? NSApplication.shared.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                Text("Setbeam").font(.title2.weight(.semibold))
            }
            Text("Monitor and share video feeds.")
            Text("Developer build. Physical hardware compatibility remains under test.").font(.caption).foregroundStyle(.secondary)
            Text("Based on Holly Share by Faini Made. Includes MediaMTX, FFmpeg, and Opus. Bundled notices include licenses, versions, build information, and sources.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Button("Open source notices") { NSWorkspace.shared.open(AppAssets.root.appendingPathComponent("Licenses")) }; Spacer(); Button("Done") { model.sheet = nil }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 420)
    }
}

/// The name the viewing link uses now, with the IP address link as an explicit fallback.
struct InvitationAddressView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        let status = model.localAddressStatus
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: status.attention ? "exclamationmark.triangle" : "link").foregroundStyle(status.attention ? .orange : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.localViewerURL?.host ?? "IP address \(model.viewerAddress)").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Text(model.localViewerURL == nil || status.attention ? status.text.unbrokenHyphens
                         : model.shortAddressHost != nil ? "Type this address to ask to join."
                         : "Send the whole viewing link. The name alone doesn't open the feed.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
                if model.shortAddressEnabled, model.shortAddressHost == nil, model.state.sharing, model.shortAddressStatus.attention {
                    Label(model.shortAddressStatus.text.unbrokenHyphens, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension String {
    /// Keeps names such as `stage-a-2.local` on one line inside wrapped sentences.
    var unbrokenHyphens: String { replacingOccurrences(of: "-", with: "\u{2011}") }
}
