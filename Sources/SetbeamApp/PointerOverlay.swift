import SwiftUI
import SetbeamCore

/// Participants' pointers for native monitoring. Each pointer expires locally from its own
/// remaining time, so a lost update or an idle sender never leaves a pointer on screen.
@MainActor final class PointerPresenceModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: Int
        let label: String
        let color: PointerColor
        let x: Double, y: Double
        let expiresAt: Date
    }
    @Published private(set) var items: [Item] = []
    private var expiry: Task<Void, Never>?

    func show(_ pointers: [SharedPointer], now: Date = Date()) {
        items = pointers.filter { $0.remaining > 0 }.map {
            Item(id: $0.number, label: $0.label, color: $0.color, x: $0.x, y: $0.y, expiresAt: now.addingTimeInterval($0.remaining))
        }
        scheduleExpiry(now: now)
    }
    func clear() { expiry?.cancel(); expiry = nil; if !items.isEmpty { items = [] } }

    func prune(now: Date = Date()) {
        let remaining = items.filter { $0.expiresAt > now }
        if remaining != items { items = remaining }
        scheduleExpiry(now: now)
    }
    private func scheduleExpiry(now: Date) {
        expiry?.cancel(); expiry = nil
        guard let next = items.map(\.expiresAt).min() else { return }
        let delay = max(0, next.timeIntervalSince(now))
        expiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000) + 1_000_000)
            guard !Task.isCancelled else { return }
            self?.prune()
        }
    }
}

/// Picture-relative mapping shared by the main monitor and floating preview.
enum PointerMapping {
    /// The aspect-fit picture inside `bounds`, matching AVSampleBufferDisplayLayer's resizeAspect.
    static func fit(_ source: CGSize, in bounds: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    /// A picture-relative position in a top-left-origin picture rectangle.
    static func point(x: Double, y: Double, in picture: CGRect) -> CGPoint {
        CGPoint(x: picture.minX + CGFloat(x) * picture.width, y: picture.minY + CGFloat(y) * picture.height)
    }
}

/// Draws participants' named pointers over a picture. It never takes mouse events, so window
/// movement, resizing, zoom, pan, and controls behave as before.
struct PointerOverlay: View {
    @ObservedObject var presence: PointerPresenceModel
    /// The decoded picture's size when the overlay covers a larger aspect-fit area; nil when the
    /// overlay already matches the picture rectangle exactly.
    var pictureSize: CGSize?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let picture = pictureSize.map { PointerMapping.fit($0, in: bounds) } ?? bounds
            ZStack(alignment: .topLeading) {
                ForEach(presence.items) { item in
                    let point = PointerMapping.point(x: item.x, y: item.y, in: picture)
                    PointerMark(label: item.label, color: item.color,
                                flipX: point.x > picture.maxX - 140, flipY: point.y > picture.maxY - 44)
                        .position(point)
                        // Appear at once when someone points; fade gently when they stop.
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: presence.items.map(\.id))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(presence.items.isEmpty)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presence.items.isEmpty ? "" : "Viewer pointers: " + presence.items.map(\.label).joined(separator: ", "))
    }
}

/// One cursor shape: an arrow whose tip is the shared point, with a colored name label.
struct PointerMark: View {
    let label: String
    let color: PointerColor
    var flipX = false
    var flipY = false

    var body: some View {
        let fill = Color(red: color.rgb.red, green: color.rgb.green, blue: color.rgb.blue)
        // The arrow is the layout base, so its tip stays on the shared point; the name label is an
        // overlay and can flip near the picture's edges without moving the arrow.
        PointerArrow().fill(fill)
            .overlay(PointerArrow().stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)))
            .frame(width: 16, height: 23)
            .shadow(color: .black.opacity(0.55), radius: 1.5, y: 0.5)
            .overlay(alignment: .topLeading) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                    .foregroundStyle(color.darkText ? Color(white: 0.08) : .white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(fill, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.85), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .alignmentGuide(.leading) { flipX ? $0.width + 4 : -12 }
                    .alignmentGuide(.top) { flipY ? $0.height + 4 : -20 }
            }
            .frame(width: 0, height: 0, alignment: .topLeading)
    }
}

struct PointerArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.63))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.58, y: rect.minY + rect.height * 0.67))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.39, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
