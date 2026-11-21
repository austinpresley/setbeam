import AppKit
import SwiftUI

enum SetbeamChrome {
    static let toolbar = adaptive(0xebebeb, 0x2b2b2e)
    static let panel = adaptive(0xececec, 0x262628)
    static let raised = adaptive(0xffffff, 0x3a3a3e)
    static let line = adaptive(0xd4d4d6, 0x3d3d41)
    static let segment = adaptive(0xdcdcdf, 0x1d1d1f)
    static let artwork = adaptive(0xf3f3f5, 0x27272a)
    static let blue = Color(nsColor: color(0x0a6cff))
    static let blueText = adaptive(0x0a55c8, 0x82b6ff)
    static let red = Color(nsColor: color(0xd62f25))
    static let amber = Color(nsColor: color(0xff9f0a))
    static let onAmber = Color(nsColor: color(0x2b1a00))
    static let admit = Color(nsColor: color(0x22843a))
    static let amberText = adaptive(0x895200, 0xffb340)
    static let green = Color(nsColor: color(0x30c552))
    static let greenText = adaptive(0x246f39, 0x63dc83)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            color(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

struct ChromeIconButton: View {
    let title: String
    let symbol: String
    var size: CGFloat
    var height: CGFloat
    var iconSize: CGFloat
    var selected: Bool
    var badge: Int
    var badgeColor: Color
    var hint: String?
    let action: () -> Void

    init(_ title: String, symbol: String, size: CGFloat = 32, height: CGFloat = 28, iconSize: CGFloat = 16, selected: Bool = false,
         badge: Int = 0, badgeColor: Color = SetbeamChrome.red, hint: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.size = size; self.height = height; self.iconSize = iconSize
        self.selected = selected; self.badge = badge; self.badgeColor = badgeColor; self.hint = hint; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: iconSize))
                .frame(width: size, height: height).contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if badge > 0 { ChromeBadge(count: badge, color: badgeColor) }
                }
        }.buttonStyle(ChromeButtonStyle(selected: selected))
            .help(hint ?? title).accessibilityLabel(title)
            .accessibilityValue(badge == 0 ? "" : "\(badge)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ChromeButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        ChromeButtonBody(configuration: configuration, selected: selected)
    }

    private struct ChromeButtonBody: View {
        let configuration: Configuration
        let selected: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(.primary.opacity(selected || configuration.isPressed ? 0.11 : hovering && enabled ? 0.07 : 0),
                            in: RoundedRectangle(cornerRadius: 6))
                .opacity(enabled ? 1 : 0.38)
                .onHover { hovering = $0 }
        }
    }
}

struct ChromeBadge: View {
    let count: Int
    var color = SetbeamChrome.red
    var foreground = Color.white
    var body: some View {
        Text("\(min(99, count))").font(.system(size: 9, weight: .bold)).monospacedDigit()
            .foregroundStyle(foreground).padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
            .background(color, in: Capsule()).accessibilityHidden(true)
    }
}

struct SetbeamChip: View {
    let title: String
    let symbol: String
    let tint: Color

    init(_ title: String, symbol: String, tint: Color) {
        self.title = title; self.symbol = symbol; self.tint = tint
    }

    var body: some View {
        Label(title, systemImage: symbol).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            .foregroundStyle(tint).padding(.horizontal, 6).padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
