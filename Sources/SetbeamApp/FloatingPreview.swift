import AppKit
import Combine
import SwiftUI

@MainActor private final class FloatingInspection: ObservableObject {
    @Published var scale: CGFloat = 1
}

@MainActor final class FloatingPreviewWindow: NSObject, NSWindowDelegate {
    private weak var model: SessionModel?
    private var panel: PreviewPanel?
    private var controls: PreviewPanel?
    private var picture: FloatingPicture?
    private let inspection = FloatingInspection()
    private var hideTask: Task<Void, Never>?
    private var sourceObservation: AnyCancellable?

    init(model: SessionModel) { self.model = model }

    func show() {
        guard let model else { return }
        if panel == nil {
            let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
            let rect = CGRect(x: screen.maxX - 370, y: screen.minY + 80, width: 340, height: 191)
            let window = PreviewPanel(contentRect: rect)
            window.title = "Setbeam Preview"
            window.contentAspectRatio = NSSize(width: 16, height: 9)
            window.minSize = NSSize(width: 220, height: 124)
            window.delegate = self
            let view = FloatingPicture(model: model)
            view.onHover = { [weak self] inside in self?.hoverChanged(inside) }
            view.onScale = { [weak self] scale in self?.inspection.scale = scale }
            view.onAspect = { [weak self] size in self?.updateAspect(size) }
            window.contentView = view
            panel = window; picture = view
            _ = window.setFrameUsingName("SetbeamFloatingPreview")
            window.setFrameAutosaveName("SetbeamFloatingPreview")
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.setFrame(rect, display: false) }

            let accessory = PreviewPanel(contentRect: CGRect(x: 0, y: 0, width: rect.width, height: 52))
            accessory.title = "Setbeam Preview Controls"
            let toolbar = HoverHostingView(rootView: FloatingControls(model: model, inspection: inspection,
                close: { [weak self] in self?.close() }))
            toolbar.onHover = { [weak self] inside in self?.hoverChanged(inside) }
            accessory.contentView = toolbar; controls = accessory
            sourceObservation = model.$setup.removeDuplicates { $0?.id == $1?.id }.sink { [weak view] setup in
                view?.resetInspection()
                view?.setAccessibilityLabel(setup?.kind == .sample ? "Sample feed floating preview" : "Floating feed preview")
            }
            view.refreshAspect()
        }
        model.floatingVisibilityChanged(true)
        panel?.orderFrontRegardless()
        if let picture, let panel,
           picture.bounds.contains(picture.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)) { hoverChanged(true) }
    }

    func close() { hideControls(); panel?.close() }

    func windowWillClose(_ notification: Notification) {
        hideControls(); model?.floatingVisibilityChanged(false)
    }
    func windowDidMove(_ notification: Notification) { positionControls() }
    func windowDidResize(_ notification: Notification) { positionControls() }
    func windowDidChangeScreen(_ notification: Notification) { positionControls() }

    private func updateAspect(_ size: NSSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let oldTop = panel.frame.maxY, width = panel.frame.width
        panel.contentAspectRatio = size
        panel.minSize = NSSize(width: 220, height: max(80, 220 * size.height / size.width))
        let height = width * size.height / size.width
        if abs(panel.frame.height - height) > 1 {
            panel.setFrame(CGRect(x: panel.frame.minX, y: oldTop - height, width: width, height: height), display: true)
        }
    }

    private func hoverChanged(_ inside: Bool) {
        hideTask?.cancel()
        if inside {
            guard let panel, panel.isVisible, let controls else { return }
            positionControls()
            if controls.parent == nil { panel.addChildWindow(controls, ordered: .above) }
            controls.orderFrontRegardless()
        } else {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled, let self, let panel = self.panel, let controls = self.controls else { return }
                let mouse = NSEvent.mouseLocation
                // Keep the short crossing between picture and controls usable.
                if panel.frame.union(controls.frame).contains(mouse) { self.hoverChanged(false) }
                else if !controls.isKeyWindow { self.hideControls() }
            }
        }
    }

    private func hideControls() {
        hideTask?.cancel(); hideTask = nil
        if let controls { panel?.removeChildWindow(controls); controls.orderOut(nil) }
    }

    private func positionControls() {
        guard let panel, let controls else { return }
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let width = min(max(panel.frame.width, 220), screen.width)
        let x = min(max(panel.frame.minX, screen.minX), screen.maxX - width)
        let below = panel.frame.minY - 58
        let y = below >= screen.minY ? below : panel.frame.maxY + 6
        controls.setFrame(CGRect(x: x, y: y, width: width, height: 52), display: controls.isVisible)
    }
}

@MainActor private final class PreviewPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating; isFloatingPanel = true; hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear; isOpaque = false; hasShadow = true; acceptsMouseMovedEvents = true
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class FloatingPicture: NSView {
    var onHover: ((Bool) -> Void)?
    var onScale: ((CGFloat) -> Void)?
    var onAspect: ((NSSize) -> Void)?
    private var picture: PreviewPicture?
    private let pictureView = PictureLayerView(gravity: .resize)
    private var viewport = PreviewViewport()
    private var frames: AnyCancellable?
    private var tracking: NSTrackingArea?
    private var dragPoint: CGPoint?
    private var windowDrag: (pointer: CGPoint, origin: CGPoint)?
    private var windowResize: PreviewWindowResize?
    private let recovery: NSView

    init(model: SessionModel) {
        recovery = PassthroughHostingView(rootView: FloatingRecovery(model: model))
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 10; layer?.masksToBounds = true
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("Floating feed preview")
        setAccessibilityHelp("Pinch or scroll to zoom. Drag a zoomed picture to pan. Double-click or press 0 to restore the full picture. At full picture, drag to move the window.")
        addSubview(pictureView)
        recovery.frame = bounds; recovery.autoresizingMask = [.width, .height]; addSubview(recovery)
        frames = model.localPlayer.$picture.sink { [weak self] picture in
            guard let self else { return }
            let previous = self.picture?.size; self.picture = picture
            self.pictureView.show(picture)
            if let picture, picture.size != previous { self.resetInspection(); self.refreshAspect() }
            if picture == nil || picture?.size != previous { self.layoutPicture() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func refreshAspect() { if let picture { onAspect?(picture.size) } }
    func resetInspection() { viewport.reset(); inspectionChanged() }
    private func inspectionChanged() {
        onScale?(viewport.scale); layoutPicture(); window?.invalidateCursorRects(for: self)
        setAccessibilityValue(viewport.scale > 1.001 ? "Zoomed \(Int((viewport.scale * 100).rounded())) percent" : "Full picture")
    }
    override func draw(_ dirtyRect: NSRect) { NSColor.black.setFill(); bounds.fill() }
    /// The picture view occupies the zoomed image rectangle; this view's layer clips it.
    private func layoutPicture() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pictureView.frame = picture.map { viewport.imageRect(source: $0.size, bounds: bounds) } ?? .zero
        CATransaction.commit()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let picture { viewport.constrain(source: picture.size, bounds: bounds) }; layoutPicture()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next); tracking = next
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func resetCursorRects() {
        addCursorRect(bounds.insetBy(dx: 6, dy: 6), cursor: viewport.scale > 1.001 ? .openHand : .arrow)
        let w = bounds.width, h = bounds.height
        if #available(macOS 15.0, *) {
            let edges: [(CGRect, NSCursor.FrameResizePosition)] = [
                (CGRect(x: 6, y: 0, width: w - 12, height: 6), .top),
                (CGRect(x: 6, y: h - 6, width: w - 12, height: 6), .bottom),
                (CGRect(x: 0, y: 6, width: 6, height: h - 12), .left),
                (CGRect(x: w - 6, y: 6, width: 6, height: h - 12), .right),
                (CGRect(x: 0, y: 0, width: 6, height: 6), .topLeft),
                (CGRect(x: w - 6, y: 0, width: 6, height: 6), .topRight),
                (CGRect(x: 0, y: h - 6, width: 6, height: 6), .bottomLeft),
                (CGRect(x: w - 6, y: h - 6, width: 6, height: 6), .bottomRight)
            ]
            for (rect, position) in edges { addCursorRect(rect, cursor: .frameResize(position: position, directions: .all)) }
        } else {
            addCursorRect(CGRect(x: 0, y: 0, width: 6, height: h), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: w - 6, y: 0, width: 6, height: h), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: 6, y: 0, width: w - 12, height: 6), cursor: .resizeUpDown)
            addCursorRect(CGRect(x: 6, y: h - 6, width: w - 12, height: 6), cursor: .resizeUpDown)
        }
    }
    override func magnify(with event: NSEvent) { zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.008 : 0.12)
        zoom(by: exp(delta), at: convert(event.locationInWindow, from: nil))
    }
    private func zoom(by factor: CGFloat, at point: CGPoint) {
        guard let picture else { return }
        viewport.zoom(by: factor, at: point, source: picture.size, bounds: bounds)
        inspectionChanged(); onHover?(true)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { resetInspection(); return }
        if let window {
            windowResize = PreviewWindowResize(frame: window.frame, pointer: window.convertPoint(toScreen: event.locationInWindow),
                localPoint: convert(event.locationInWindow, from: nil), bounds: bounds)
            if windowResize != nil { return }
        }
        if viewport.scale > 1.001 { dragPoint = convert(event.locationInWindow, from: nil); NSCursor.closedHand.push() }
        else if let window {
            windowDrag = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if let resize = windowResize, let window {
            window.setFrame(resize.frame(at: window.convertPoint(toScreen: event.locationInWindow), minimum: window.minSize), display: true)
            return
        }
        if let start = windowDrag, let window {
            let pointer = window.convertPoint(toScreen: event.locationInWindow)
            window.setFrameOrigin(CGPoint(x: start.origin.x + pointer.x - start.pointer.x,
                                          y: start.origin.y + pointer.y - start.pointer.y))
            return
        }
        guard let previous = dragPoint, let picture else { return }
        let point = convert(event.locationInWindow, from: nil)
        viewport.pan(by: CGSize(width: point.x - previous.x, height: point.y - previous.y), source: picture.size, bounds: bounds)
        dragPoint = point; inspectionChanged()
    }
    override func mouseUp(with event: NSEvent) {
        windowDrag = nil; windowResize = nil
        if dragPoint != nil { dragPoint = nil; NSCursor.pop() }
    }
    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "0": resetInspection()
        case "+", "=": zoom(by: 1.2, at: CGPoint(x: bounds.midX, y: bounds.midY))
        case "-": zoom(by: 1 / 1.2, at: CGPoint(x: bounds.midX, y: bounds.midY))
        default:
            let delta: CGSize
            switch event.keyCode {
            case 123: delta = CGSize(width: 24, height: 0)
            case 124: delta = CGSize(width: -24, height: 0)
            case 125: delta = CGSize(width: 0, height: -24)
            case 126: delta = CGSize(width: 0, height: 24)
            default: super.keyDown(with: event); return
            }
            if let picture { viewport.pan(by: delta, source: picture.size, bounds: bounds); inspectionChanged() }
        }
    }
}

private struct FloatingRecovery: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        if !model.localReady {
            ZStack {
                Color.black.opacity(0.72)
                if let stage = model.connectionStage {
                    ConnectionProgressView(stage: stage, kind: model.setup?.kind ?? .sample, title: model.connectionStageTitle, compact: true)
                } else { Text(model.recoveryTitle).font(.caption).foregroundStyle(.white).multilineTextAlignment(.center).padding(12) }
            }
        }
    }
}

private struct FloatingControls: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var inspection: FloatingInspection
    let close: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.caption).lineLimit(1)
                Text(model.setup?.kind == .sample ? "Sample feed" : model.statusLabel).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if inspection.scale > 1.001 {
                Text("\(Int((inspection.scale * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).padding(.horizontal, 6).padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5)).fixedSize()
                    .help("Zoomed picture. Double-click the picture or press 0 to reset.")
                    .accessibilityLabel("Preview zoomed to \(Int((inspection.scale * 100).rounded())) percent")
            }
            Button { model.toggleLocalSound() } label: {
                Image(systemName: model.localMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 24, height: 28)
            }.help(model.localMuted ? "Enable local sound" : "Mute local sound")
                .accessibilityLabel(model.localMuted ? "Enable local sound" : "Mute local sound")
            Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 28) }
                .help("Close floating preview").accessibilityLabel("Close floating preview")
        }.buttonStyle(.plain).padding(.horizontal, 10).frame(height: 52).background(.regularMaterial)
    }
}

@MainActor private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    required init(rootView: Content) {
        super.init(rootView: rootView); wantsLayer = true; layer?.cornerRadius = 10; layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next); tracking = next
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
