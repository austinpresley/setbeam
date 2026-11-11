import SwiftUI
import SetbeamCore

/// Transmitter models Setbeam has a connection route for. A card is a starting point, not a compatibility claim;
/// `docs/hardware-tests.md` records what each route has physically passed.
enum TransmitterModel: String, CaseIterable, Identifiable {
    case cineViewMaster4K, pyroH
    var id: String { rawValue }
    var brand: String { self == .cineViewMaster4K ? "Accsoon" : "Hollyland" }
    var name: String { self == .cineViewMaster4K ? "CineView Master 4K" : "Pyro H" }
    var artwork: String { self == .cineViewMaster4K ? "accsoon.master" : "hollyland.pyro" }
    /// The recorded physical evidence, in one line.
    var evidence: String {
        self == .cineViewMaster4K ? "Tested in Setbeam over direct Wi-Fi, firmware 3.30" : "Not yet tested with a physical Pyro H"
    }
}

/// One model card in Choose a source. Choosing it opens that model's guided connection.
struct TransmitterCard: View {
    let transmitter: TransmitterModel
    let status: String
    let found: Bool
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                HardwareArtwork(symbol: transmitter.artwork)
                VStack(alignment: .leading, spacing: 4) {
                    Text(transmitter.brand).font(.caption).foregroundStyle(.secondary)
                    Text(transmitter.name).font(.callout.weight(.medium)).foregroundStyle(.primary)
                    Label(status, systemImage: found ? "checkmark.circle" : "wifi").font(.caption)
                        .foregroundStyle(found ? Color.accentColor : .secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .help("Set up \(transmitter.brand) \(transmitter.name). \(transmitter.evidence).")
            .accessibilityLabel("Set up \(transmitter.brand) \(transmitter.name). \(status)")
    }
}

/// Guided connection for one transmitter model, shown inside Choose a source so discovery keeps running.
struct TransmitterGuideView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var browser: SourceBrowser
    let transmitter: TransmitterModel
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button(action: back) { Label("Wireless transmitters", systemImage: "chevron.left") }.buttonStyle(.link)
                .keyboardShortcut("[", modifiers: .command).help("Return to wireless transmitters (⌘[)")
            HStack(alignment: .center, spacing: 12) {
                HardwareArtwork(symbol: transmitter.artwork, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(transmitter.brand) \(transmitter.name)").font(.title3.weight(.semibold))
                    Text(transmitter.evidence).font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                step(1, "Connect the source", transmitter == .cineViewMaster4K
                     ? "Connect a computer display or camera to the transmitter's HDMI or SDI input, then power it on."
                     : "Connect a computer display or camera to the transmitter's HDMI input, then power it on.")
                if transmitter == .cineViewMaster4K {
                    step(2, "Join the transmitter's Wi-Fi", "Join the 5 GHz network shown on its display, usually Accsoon_ and four characters. Wi-Fi stays under your control.")
                } else {
                    step(2, "Join the transmitter's Wi-Fi", "Join the Pyro H transmitter's Wi-Fi on this Mac. Wi-Fi stays under your control.")
                    step(3, "Close other viewers", "Quit HollyView and other apps watching this transmitter. It may allow only one viewer at a time.")
                }
            }
            Button("Open Wi-Fi Settings") { model.openWiFiSettings() }.buttonStyle(.link)
            VStack(alignment: .leading, spacing: 8) {
                Text("On this Mac's Wi-Fi").font(.headline)
                if transmitter == .cineViewMaster4K { cineViewDevices } else { pyroHDevices }
            }
            if transmitter == .cineViewMaster4K {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Other route").font(.headline)
                    GuideRow(title: "Connect through Accsoon SEE", detail: "Send the picture from the SEE app to Setbeam. Not tested with hardware.",
                             symbol: "arrow.down.to.line") { model.prepareAccsoon() }
                }
            } else {
                Text("Setbeam reads the stream the Pyro H transmitter offers on its own Wi-Fi. Use Enter Stream Address in Choose a source for another address.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var cineViewDevices: some View {
        let recognized = model.wirelessDevices.filter(\.recognized)
        if let current = model.setup, current.kind == .accsoon, model.state.monitoring {
            GuideRow(title: current.deviceName ?? current.name, detail: "Current source", symbol: transmitter.artwork) { model.sheet = nil }
        }
        ForEach(recognized.filter { $0.id != model.setup?.wirelessUID || !model.state.monitoring }) { device in
            GuideRow(title: device.name, detail: device.videoAvailable ? "\(device.wifiName) · Ready to connect" : "\(device.wifiName) · Waiting for a source picture",
                     symbol: transmitter.artwork) { model.connectWireless(device) }
        }
        ForEach(model.wirelessDevices.filter { !$0.recognized }) { device in
            HStack(alignment: .top, spacing: 12) {
                HardwareArtwork(symbol: "antenna.radiowaves.left.and.right")
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.wifiName.isEmpty ? "Accsoon transmitter found" : device.wifiName).font(.callout.weight(.medium))
                    Text(device.productID == nil ? "Checking the transmitter model. You can choose another input while Setbeam checks." : "This transmitter model has not been verified. Choose a verified transmitter or a capture input.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.vertical, 8).accessibilityElement(children: .combine)
        }
        if model.wirelessDevices.isEmpty && !(model.setup?.kind == .accsoon && model.state.monitoring) {
            if let problem = model.wirelessDiscoveryProblem {
                Text(problem).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Looking for a CineView Master 4K…", systemImage: "antenna.radiowaves.left.and.right").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var pyroHDevices: some View {
        if let current = model.setup, current.networkProfile == .pyroH, model.state.monitoring {
            GuideRow(title: current.name, detail: "Current source", symbol: transmitter.artwork) { model.sheet = nil }
        } else {
            ForEach(browser.pyroHSources) { device in
                GuideRow(title: device.network.interface == "lo0" ? "Pyro H test stream" : "Hollyland Pyro H",
                         detail: "Compatible stream found · Confirm the transmitter model", symbol: transmitter.artwork) { model.connectPyroH(device) }
            }
            switch browser.pyroHSearchState {
            case .looking: Label("Looking for Pyro H…", systemImage: "antenna.radiowaves.left.and.right").font(.caption).foregroundStyle(.secondary)
            case .noWiFi: note("This Mac isn't on a Wi-Fi network yet. Join the transmitter's Wi-Fi to search.")
            case .unavailable: note("No Pyro H stream found on this Wi-Fi. Join the transmitter's Wi-Fi, close HollyView, and check that the transmitter is on. Setbeam keeps looking.")
            case .monitoring: note("Pyro H discovery pauses while a network source is monitored, because the transmitter may allow one viewer.")
            case .found: EmptyView()
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }
}

/// A connect action in a transmitter guide, styled like the rows in Choose a source.
private struct GuideRow: View {
    let title: String
    let detail: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                HardwareArtwork(symbol: symbol)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(12).contentShape(Rectangle())
        }.buttonStyle(.plain).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("\(title). \(detail)")
    }
}
