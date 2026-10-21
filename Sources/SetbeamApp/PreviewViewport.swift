import Foundation

/// Picture-only inspection. The decoded feed and audience media are unchanged.
struct PreviewViewport {
    private(set) var scale: CGFloat = 1
    private(set) var offset = CGPoint.zero

    mutating func reset() { scale = 1; offset = .zero }

    func imageRect(source: CGSize, bounds: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let fit = min(bounds.width / source.width, bounds.height / source.height)
        let size = CGSize(width: source.width * fit * scale, height: source.height * fit * scale)
        return CGRect(x: bounds.midX - size.width / 2 + offset.x,
                      y: bounds.midY - size.height / 2 + offset.y, width: size.width, height: size.height)
    }

    mutating func zoom(by factor: CGFloat, at point: CGPoint, source: CGSize, bounds: CGRect) {
        guard factor.isFinite, factor > 0, bounds.width > 0, bounds.height > 0 else { return }
        let next = min(6, max(1, scale * factor)), ratio = next / scale
        let anchor = CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
        offset = CGPoint(x: anchor.x - (anchor.x - offset.x) * ratio,
                         y: anchor.y - (anchor.y - offset.y) * ratio)
        scale = next
        constrain(source: source, bounds: bounds)
    }

    mutating func pan(by delta: CGSize, source: CGSize, bounds: CGRect) {
        offset.x += delta.width; offset.y += delta.height
        constrain(source: source, bounds: bounds)
    }

    mutating func constrain(source: CGSize, bounds: CGRect) {
        let rect = imageRect(source: source, bounds: bounds)
        let limitX = max(0, (rect.width - bounds.width) / 2), limitY = max(0, (rect.height - bounds.height) / 2)
        offset.x = min(limitX, max(-limitX, offset.x)); offset.y = min(limitY, max(-limitY, offset.y))
        if scale == 1 { offset = .zero }
    }
}

/// Aspect-preserving edge resizing for the borderless picture window.
struct PreviewWindowResize {
    private let startFrame: CGRect
    private let startPointer: CGPoint
    private let horizontal: CGFloat
    private let vertical: CGFloat

    init?(frame: CGRect, pointer: CGPoint, localPoint: CGPoint, bounds: CGRect) {
        horizontal = localPoint.x < bounds.minX + 6 ? -1 : localPoint.x > bounds.maxX - 6 ? 1 : 0
        vertical = localPoint.y < bounds.minY + 6 ? 1 : localPoint.y > bounds.maxY - 6 ? -1 : 0
        guard horizontal != 0 || vertical != 0, frame.width > 0, frame.height > 0 else { return nil }
        startFrame = frame; startPointer = pointer
    }

    func frame(at pointer: CGPoint, minimum: CGSize) -> CGRect {
        let dx = (pointer.x - startPointer.x) * horizontal / startFrame.width
        let dy = (pointer.y - startPointer.y) * vertical / startFrame.height
        let change = horizontal == 0 ? dy : vertical == 0 ? dx : abs(dx) > abs(dy) ? dx : dy
        let minimumScale = max(minimum.width / startFrame.width, minimum.height / startFrame.height)
        let scale = max(minimumScale, 1 + change)
        let width = startFrame.width * scale, height = startFrame.height * scale
        let x = horizontal < 0 ? startFrame.maxX - width : horizontal > 0 ? startFrame.minX : startFrame.midX - width / 2
        let y = vertical < 0 ? startFrame.maxY - height : vertical > 0 ? startFrame.minY : startFrame.midY - height / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
