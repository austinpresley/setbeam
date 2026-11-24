import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import Darwin
import os

/// Quartz screen coordinates and ScreenCaptureKit's top-left content rectangle for one picture.
struct PresenterCursorFrame: Sendable {
    let screen: CGRect
    let content: CGRect
    let cursor: CGPoint
    let isWindow: Bool
    let displayTime: CMTime
    static let windowCornerInset: CGFloat = 24

    init?(screen: CGRect, contentInPoints: CGRect, scale: CGFloat, imageSize: CGSize, cursor: CGPoint,
          isWindow: Bool = false, displayTime: CMTime = .invalid) {
        guard Self.valid(screen), Self.valid(contentInPoints), (1...4).contains(scale),
              screen.contains(cursor) else { return nil }
        let pixels = contentInPoints.applying(CGAffineTransform(scaleX: scale, y: scale))
        let image = CGRect(origin: .zero, size: imageSize)
        let clip = pixels.intersection(image)
        guard Self.valid(clip), Self.sameBounds(clip, pixels) else { return nil }
        // Some fit sizes round by a pixel. Reject unexpected cropping or scaling.
        let heightError = abs(pixels.height - screen.height * (pixels.width / screen.width))
        let widthError = abs(pixels.width - screen.width * (pixels.height / screen.height))
        guard min(widthError, heightError) <= 2 else { return nil }
        self.screen = screen
        content = clip
        self.cursor = cursor
        self.isWindow = isWindow
        self.displayTime = displayTime
    }

    var center: CGPoint {
        CGPoint(x: content.minX + (cursor.x - screen.minX) * content.width / screen.width,
                y: content.minY + (cursor.y - screen.minY) * content.height / screen.height)
    }

    func acceptsCurrentCursor(_ point: CGPoint, now: CMTime) -> Bool {
        // A fresh picture can carry a moving cursor. Reusing an older picture is
        // safe only while the cursor is still at that picture's point.
        screen.contains(point) && (Self.isRecent(displayTime, now: now) ||
            (abs(cursor.x - point.x) <= 1 && abs(cursor.y - point.y) <= 1))
    }

    static func isRecent(_ displayTime: CMTime, now: CMTime) -> Bool {
        (0...0.1).contains((now - displayTime).seconds)
    }

    static func awayFromCorners(_ point: CGPoint, in bounds: CGRect, dx: CGFloat, dy: CGFloat) -> Bool {
        (point.x >= bounds.minX + dx && point.x < bounds.maxX - dx) ||
            (point.y >= bounds.minY + dy && point.y < bounds.maxY - dy)
    }

    static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.maxX.isFinite && rect.minY.isFinite && rect.maxY.isFinite &&
            rect.size.width > 0 && rect.size.height > 0
    }

    static func sameBounds(_ a: CGRect, _ b: CGRect) -> Bool {
        valid(a) && valid(b) && abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 &&
            abs(a.maxX - b.maxX) <= 1 && abs(a.maxY - b.maxY) <= 1
    }
}

/// Shared display pointers are click-through Setbeam windows. Their full display
/// bounds must not suppress the ring over the underlying captured application.
public enum SharedPointerCaptureExclusion {
    private static let windows = OSAllocatedUnfairLock(initialState: Set<CGWindowID>())

    public static func setWindow(_ id: CGWindowID, visible: Bool) {
        windows.withLock { ids in
            if visible { ids.insert(id) } else { ids.remove(id) }
        }
    }

    static var windowIDs: Set<CGWindowID> { windows.withLock { $0 } }
}

enum PresenterCursorSource: Sendable {
    case display(CGDirectDisplayID, uuid: String, excluded: Set<pid_t>)
    case window(MacWindowIdentity)

    struct Window {
        let id: CGWindowID
        let owner: pid_t
        let bounds: CGRect
        let alpha: Double
        let layer: Int

        init(id: CGWindowID, owner: pid_t, bounds: CGRect, alpha: Double = 1, layer: Int = 0) {
            self.id = id
            self.owner = owner
            self.bounds = bounds
            self.alpha = alpha
            self.layer = layer
        }

        init?(_ info: [String: Any]) {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = PresenterCursorSource.rect(info[kCGWindowBounds as String]),
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  let layer = info[kCGWindowLayer as String] as? Int else { return nil }
            self.init(id: id, owner: owner, bounds: bounds, alpha: alpha, layer: layer)
        }
    }

    func sample(_ attachments: [SCStreamFrameInfo: Any], image: CVPixelBuffer) -> PresenterCursorFrame? {
        // A cursor sampled long after the frame can belong to a different picture. Keep
        // the same time tolerance at 1 fps, where the operator can pause over a detail.
        guard let displayTime = attachments[.displayTime] as? UInt64, displayTime > 0,
              let content = Self.rect(attachments[.contentRect]),
              let scale = attachments[.scaleFactor] as? CGFloat else { return nil }
        if #available(macOS 14.2, *), let overlay = attachments[.presenterOverlayContentRect] {
            guard let rect = Self.rect(overlay), rect.isEmpty else { return nil }
        }
        let frameTime = CMClockMakeHostTimeFromSystemUnits(displayTime)
        guard PresenterCursorFrame.isRecent(frameTime, now: CMClockGetTime(CMClockGetHostTimeClock())),
              let cursor = CGEvent(source: nil)?.location else { return nil }
        let screen: CGRect?, isWindow: Bool
        switch self {
        case .display(let id, _, _): screen = CGDisplayBounds(id); isWindow = false
        case .window: screen = Self.rect(attachments[.screenRect]); isWindow = true
        }
        guard let screen else { return nil }
        return PresenterCursorFrame(screen: screen, contentInPoints: content, scale: scale,
                                    imageSize: CVImageBufferGetEncodedSize(image), cursor: cursor, isWindow: isWindow,
                                    displayTime: frameTime)
    }

    func permitsDisplayRing(on frame: PresenterCursorFrame) -> Bool {
        let clock = CMClockGetHostTimeClock()
        guard case .display(let id, let uuid, _) = self,
              CGDisplayIsActive(id) != 0, MacDisplay.identity(id)?.caseInsensitiveCompare(uuid) == .orderedSame,
              PresenterCursorFrame.sameBounds(frame.screen, CGDisplayBounds(id)),
              let cursor = CGEvent(source: nil)?.location, frame.acceptsCurrentCursor(cursor, now: CMClockGetTime(clock)),
              let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
        let windows = rows.compactMap(Window.init)
        guard rows.count == windows.count, let current = CGEvent(source: nil)?.location,
              abs(cursor.x - current.x) <= 4, abs(cursor.y - current.y) <= 4 else { return false }
        let now = CMClockGetTime(clock)
        let pointerOverlays = SharedPointerCaptureExclusion.windowIDs
        return ownsDisplayCursor(frame, at: cursor, windows: windows, pointerOverlays: pointerOverlays, now: now) &&
            ownsDisplayCursor(frame, at: current, windows: windows, pointerOverlays: pointerOverlays, now: now)
    }

    @MainActor static func windowCursorHit(_ identity: MacWindowIdentity, for frame: PresenterCursorFrame) -> CGPoint? {
        guard let event = CGEvent(source: nil),
              MacProcess.startTime(identity.processID) == identity.processStart,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, identity.windowID) as? [[String: Any]],
              let target = rows.compactMap(Window.init).first(where: { $0.id == identity.windowID }) else { return nil }
        let current = event.location, unflipped = event.unflippedLocation
        // AppKit hit testing ignores transparent and click-through layers. Window bounds
        // alone also include cursor sprites and fullscreen utilities over the picture.
        let captured = CGPoint(x: unflipped.x + frame.cursor.x - current.x,
                               y: unflipped.y - (frame.cursor.y - current.y))
        let window = Int(identity.windowID)
        let hit = NSWindow.windowNumber(at: unflipped, belowWindowWithWindowNumber: 0)
        let captureHit = NSWindow.windowNumber(at: captured, belowWindowWithWindowNumber: 0)
        guard ownsWindowCursor(identity, frame: frame, at: current, in: target, hits: (hit, captureHit),
                               now: CMClockGetTime(CMClockGetHostTimeClock())) else { return nil }
        return current
    }

    static func ownsWindowCursor(_ identity: MacWindowIdentity, frame: PresenterCursorFrame, at cursor: CGPoint,
                                 in window: Window, hits: (Int, Int), now: CMTime = .invalid) -> Bool {
        let expected = Int(identity.windowID)
        guard hits.0 == expected, hits.1 == expected, frame.acceptsCurrentCursor(cursor, now: now),
              window.id == identity.windowID, window.owner == identity.processID,
              window.layer == 0, window.alpha == 1, PresenterCursorFrame.sameBounds(frame.screen, window.bounds) else { return false }
        let inset = PresenterCursorFrame.windowCornerInset
        return [frame.cursor, cursor].allSatisfy { point in
            window.bounds.insetBy(dx: 1, dy: 1).contains(point) &&
                PresenterCursorFrame.awayFromCorners(point, in: window.bounds, dx: inset, dy: inset)
        }
    }

    func ownsDisplayCursor(_ frame: PresenterCursorFrame, at cursor: CGPoint, windows: [Window], pointerOverlays: Set<CGWindowID> = [], now: CMTime = .invalid) -> Bool {
        guard case .display(_, _, let excluded) = self, frame.acceptsCurrentCursor(cursor, now: now) else { return false }
        return !windows.contains {
            excluded.contains($0.owner) && $0.alpha != 0 &&
                !($0.owner == getpid() && pointerOverlays.contains($0.id)) &&
                (!PresenterCursorFrame.valid($0.bounds) || $0.bounds.contains(frame.cursor) || $0.bounds.contains(cursor))
        }
    }

    private static func rect(_ value: Any?) -> CGRect? {
        if let dict = value as? [String: Any] { return CGRect(dictionaryRepresentation: dict as CFDictionary) }
        if let value = value as? NSValue, strcmp(value.objCType, NSValue(rect: .zero).objCType) == 0 { return value.rectValue }
        return nil
    }
}

/// A bounded NV12 copy for frames that actually show a ring. The original remains available
/// for the next frame, even if the cursor leaves while ScreenCaptureKit is idle.
final class PresenterCursorHighlight {
    private let pool: CVPixelBufferPool?
    private let allocation = [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary

    init(width: Int, height: Int) {
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes, &pool)
        self.pool = pool
    }

    func draw(_ frame: PresenterCursorFrame, on source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool, CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, allocation, &buffer) == kCVReturnSuccess,
              let buffer, CVPixelBufferGetWidth(buffer) == CVPixelBufferGetWidth(source),
              CVPixelBufferGetHeight(buffer) == CVPixelBufferGetHeight(source),
              CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let width = CVPixelBufferGetWidth(source)
        for plane in 0..<2 {
            guard let input = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let output = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return nil }
            let inputStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let outputStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(source, plane) {
                memcpy(output.advanced(by: row * outputStride), input.advanced(by: row * inputStride), width)
            }
        }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let clip = frame.content.intersection(CGRect(x: 0, y: 0, width: width, height: CVPixelBufferGetHeight(buffer)))
        guard PresenterCursorFrame.valid(clip), clip.contains(frame.center) else { return nil }
        Self.drawRing(frame, clip: clip, luma: luma, stride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
        CVBufferRemoveAllAttachments(buffer)
        CVBufferPropagateAttachments(source, buffer)
        return buffer
    }

    private static func drawRing(_ frame: PresenterCursorFrame, clip: CGRect, luma: UnsafeMutablePointer<UInt8>, stride: Int) {
        let center = frame.center
        let radius = max(12, min(52, min(clip.width, clip.height) * 0.026))
        let minX = Int(ceil(max(clip.minX, center.x - radius)))
        let maxX = Int(floor(min(clip.maxX, center.x + radius)))
        let minY = Int(ceil(max(clip.minY, center.y - radius)))
        let maxY = Int(floor(min(clip.maxY, center.y + radius)))
        guard minX < maxX, minY < maxY else { return }
        let inner = pow(radius * 0.62, 2), whiteStart = pow(radius * 0.72, 2), whiteEnd = pow(radius * 0.9, 2)
        let outer = radius * radius
        let corner = PresenterCursorFrame.windowCornerInset
        let cornerX = corner * frame.content.width / frame.screen.width
        let cornerY = corner * frame.content.height / frame.screen.height
        // Two levels of video-range luma give the ring a visible edge on light or dark
        // pictures. Chroma and the pixels around the cursor hotspot stay intact.
        for y in minY..<maxY {
            let dy = CGFloat(y) + 0.5 - center.y
            for x in minX..<maxX {
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                let dx = point.x - center.x
                let distance = dx * dx + dy * dy
                if distance >= inner && distance <= outer &&
                    (!frame.isWindow || PresenterCursorFrame.awayFromCorners(point, in: clip, dx: cornerX, dy: cornerY)) {
                    luma[y * stride + x] = distance >= whiteStart && distance <= whiteEnd ? 235 : 16
                }
            }
        }
    }
}
