import SwiftUI

struct SourceStartView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 16) {
                ForEach(SourceCategory.allCases) { category in
                    Button { model.openSources(category: category) } label: {
                        VStack(spacing: 12) {
                            Image(systemName: category.symbol)
                                .symbolRenderingMode(.monochrome)
                                .font(.system(size: 40, weight: .light))
                                .frame(width: 52, height: 48)
                            Text(category.tileName).font(.system(size: 14, weight: .medium))
                        }.frame(maxWidth: 148, minHeight: 140).frame(minWidth: 100)
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(SourceTileStyle())
                        .help(category.name).accessibilityLabel(category.tileName)
                }
            }
            HStack(spacing: 8) {
                if let saved = model.provenSetup, saved.kind != .sample {
                    Button { model.restore(saved) } label: {
                        SetbeamChipLabel(saved.name, symbol: "clock")
                    }.buttonStyle(.plain).help("Reconnect to \(saved.name)")
                        .accessibilityLabel("Reconnect to \(saved.name)")
                }
                Button { model.openSample() } label: { SetbeamChipLabel("Sample", symbol: "play.rectangle") }
                    .buttonStyle(.plain).help("Monitor labeled sample media").accessibilityLabel("Play sample media")
            }
        }.padding(16).disabled(model.busy)
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
                            in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
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
