import SwiftUI
import SetbeamCore

/// The empty monitor offers the sources this Mac already sees, so the first click picks a picture
/// rather than a category. Display thumbnails appear only when Screen Recording is already allowed;
/// cameras and transmitters show device art, and no camera opens before it is chosen.
struct SourceStartView: View {
    @ObservedObject var model: SessionModel
    @StateObject private var displayPreviews = DisplaySourcePreviews()

    private static let maxTiles = 4

    var body: some View {
        VStack(spacing: 28) {
            HStack(spacing: 16) {
                ForEach(tiles) { tile in
                    Button(action: tile.action) { FoundSourceTile(tile: tile, previews: displayPreviews) }
                        .buttonStyle(SourceTileStyle())
                        .help(tile.help).accessibilityLabel(tile.accessibilityLabel)
                }
            }
            HStack(spacing: 10) {
                ForEach(SourceCategory.allCases) { category in
                    roundButton(category.name, symbol: category.symbol) { model.openSources(category: category) }
                }
                roundButton("Stream address", symbol: "link") { model.openNetworkSource() }
                Button { model.openSample() } label: { SetbeamChipLabel("Sample", symbol: "play.rectangle") }
                    .buttonStyle(.plain).padding(.leading, 6)
                    .help("Monitor labeled sample media").accessibilityLabel("Play sample media")
            }
        }.padding(16).disabled(model.busy)
            .task { model.refreshCaptureDevices() }
            .task(id: model.screenDisplays.map(\.id)) {
                while !Task.isCancelled {
                    await displayPreviews.refresh(displays: Array(model.screenDisplays.prefix(Self.maxTiles)), monitoredDisplayID: nil)
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                model.refreshCaptureDevices()
            }
            .onDisappear { displayPreviews.clear() }
    }

    private var saved: SourceSetup? {
        guard let saved = model.provenSetup, saved.kind != .sample else { return nil }
        return saved
    }

    private var tiles: [FoundSource] {
        var result: [FoundSource] = []
        let saved = saved
        // A saved display or camera is marked in place; other saved routes get their own first tile.
        if let saved, ![InputKind.macScreen, .capture].contains(saved.kind) {
            result.append(FoundSource(id: "saved", name: saved.name, symbol: Self.symbol(for: saved), artwork: Self.symbol(for: saved),
                                      last: true, help: "Reconnect to \(saved.name)") { model.restore(saved) })
        }
        for display in model.screenDisplays {
            let setup = SourceSetup(kind: .macScreen, name: "This Mac's screen · \(display.name)", videoID: display.id, deviceName: display.name)
            let last = saved.map { SourceChooserSelection.matches($0, setup) } ?? false
            result.append(FoundSource(id: "display-\(display.id)", name: display.name, symbol: "display", display: display, last: last,
                                      help: "Monitor \(display.name), the entire display. No audio.") {
                if let saved, last { model.restore(saved) } else { model.connect(setup) }
            })
        }
        for device in model.captureDevices where !device.audio {
            let setup = SourceSetup(kind: .capture, name: device.name, videoID: device.id, deviceName: device.name)
            let last = saved.map { $0.kind == .capture && $0.videoID == device.id } ?? false
            let art = device.builtIn ? "video" : "externaldrive.connected.to.line.below"
            result.append(FoundSource(id: "capture-\(device.id)", name: device.name, symbol: "video", artwork: art, last: last,
                                      help: "Monitor \(device.name)") {
                if let saved, last { model.restore(saved) } else { model.connect(setup) }
            })
        }
        // Keep the last working source in view even when more sources are connected.
        if let index = result.firstIndex(where: \.last), index >= Self.maxTiles {
            let tile = result.remove(at: index); result.insert(tile, at: 0)
        }
        return Array(result.prefix(Self.maxTiles))
    }

    private static func symbol(for setup: SourceSetup) -> String {
        switch setup.kind {
        case .accsoon, .network, .incoming: return "antenna.radiowaves.left.and.right"
        case .macWindow: return "macwindow"
        case .capture: return "video"
        case .macScreen: return "display"
        case .sample: return "play.rectangle"
        }
    }

    private func roundButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.white.opacity(0.88))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.08), in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.13), lineWidth: 1) }
                .contentShape(Circle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

struct FoundSource: Identifiable {
    let id: String
    let name: String
    let symbol: String
    var display: MacDisplay?
    var artwork: String?
    var last = false
    let help: String
    let action: () -> Void

    var accessibilityLabel: String { last ? "Reconnect to \(name), last working source" : "Monitor \(name)" }
}

private struct FoundSourceTile: View {
    let tile: FoundSource
    @ObservedObject var previews: DisplaySourcePreviews

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.white.opacity(0.06)
                if let display = tile.display, let image = previews.images[display.id] {
                    Image(decorative: image, scale: 2).resizable().scaledToFill()
                } else {
                    Image(systemName: tile.display == nil ? tile.artwork ?? tile.symbol : previews.permissionGranted ? "display" : "lock.display")
                        .font(.system(size: 38, weight: .light)).foregroundStyle(.white.opacity(0.7))
                }
            }.frame(width: 196, height: 112).clipped()
                .overlay(alignment: .topLeading) {
                    if tile.last {
                        Image(systemName: "clock").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 24, height: 24).background(.black.opacity(0.62), in: Circle())
                            .padding(8).help("Last working source")
                    }
                }
            HStack(spacing: 8) {
                Image(systemName: tile.symbol).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                Text(tile.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).frame(width: 196, height: 40)
        }.clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct SourceTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration)
    }

    private struct Tile: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var focused
        @State private var hovered = false
        var body: some View {
            configuration.label.foregroundStyle(.white.opacity(0.93))
                .background(.white.opacity(configuration.isPressed ? 0.16 : hovered ? 0.12 : 0.08),
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(hovered || focused ? SetbeamChrome.blue : .white.opacity(0.13), lineWidth: hovered || focused ? 2 : 1)
                }
                .onHover { hovered = $0 }
        }
    }
}

private struct SetbeamChipLabel: View {
    let title: String
    let symbol: String

    init(_ title: String, symbol: String) {
        self.title = title; self.symbol = symbol
    }

    var body: some View {
        Label(title, systemImage: symbol).font(.caption.weight(.medium)).lineLimit(1)
            .foregroundStyle(.white.opacity(0.88)).padding(.horizontal, 12).frame(height: 32)
            .background(.white.opacity(0.08), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.13), lineWidth: 1) }
    }
}
