import AppKit
import Combine
import CoreImage
import SwiftUI

@MainActor final class FloatingPreviewWindow: NSObject, NSWindowDelegate {
    private weak var model: SessionModel?
    private var panel: PreviewPanel?
    private var picture: FloatingPicture?
    private var controls: FloatingPreviewControls?
    private var viewers: FloatingViewerPanel?
    private var sourceObservation: AnyCancellable?
    private weak var previousKey: NSWindow?

    init(model: SessionModel) { self.model = model }
    var keyboardActive: Bool { panel?.isKeyWindow == true }

    func show() {
        guard let model else { return }
        if panel == nil {
            let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
            let rect = CGRect(x: screen.maxX - 368, y: screen.minY + 80, width: 340, height: 192)
            let window = PreviewPanel(contentRect: rect)
            window.title = "Setbeam Preview"
            window.contentAspectRatio = NSSize(width: 16, height: 9)
            window.minSize = NSSize(width: 220, height: 124)
            window.delegate = self
            window.onClose = { [weak self] in self?.close() }
            window.onEscape = { [weak self] in self?.leaveKeyboard() }
            let view = FloatingPicture(model: model)
            let overlay = FloatingPreviewControls(model: model, close: { [weak self] in self?.close() })
            view.onHover = { [weak overlay] inside in overlay?.setHover(inside) }
            view.onAspect = { [weak self] size in self?.updateAspect(size) }
            view.onPictureInteraction = { [weak overlay] in overlay?.cancelActions() }
            view.onKeyboardExit = { [weak self] in self?.leaveKeyboard() }
            overlay.holdVisualChanged = { [weak view] held in view?.setHoldVisual(held) }
            view.setHoldVisual(model.floatingPresentation.washed)
            overlay.showViewers = { [weak self] in self?.toggleViewers() }
            overlay.frame = view.bounds; overlay.autoresizingMask = [.width, .height]
            view.addSubview(overlay)
            window.contentView = view
            panel = window; picture = view; controls = overlay
            // Pointer operations never request key status. Deliberate menu/keyboard entry does.
            view.nextKeyView = overlay.close; overlay.close.nextKeyView = overlay.center
            overlay.center.nextKeyView = overlay.audience; overlay.audience.nextKeyView = view
            _ = window.setFrameUsingName("SetbeamFloatingPreview")
            window.setFrameAutosaveName("SetbeamFloatingPreview")
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.setFrame(rect, display: false) }
            sourceObservation = model.$setup.removeDuplicates { $0?.id == $1?.id }.sink { [weak view] setup in
                view?.resetInspection()
                view?.setAccessibilityLabel(setup?.kind == .sample ? "Sample feed floating preview" : "Floating feed preview")
                view?.toolTip = setup?.kind == .sample ? "Sample media" : nil
            }
            view.refreshAspect()
        }
        model.floatingVisibilityChanged(true)
        panel?.orderFrontRegardless()
        if let picture, let panel {
            controls?.setHover(picture.bounds.contains(picture.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)))
        }
    }
    func close() {
        controls?.cancelActions(); closeViewers()
        if panel?.isKeyWindow == true { leaveKeyboard() }
        panel?.close()
    }
    func focusForKeyboard() {
        if NSApp.keyWindow !== panel { previousKey = NSApp.keyWindow }
        show(); panel?.keyboardRequested = true
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil); controls?.setKeyboard(true)
        if let picture { panel?.makeFirstResponder(picture) }
    }
    private func leaveKeyboard() {
        controls?.cancelActions(); closeViewers(); panel?.keyboardRequested = false; controls?.setKeyboard(false)
        if let previousKey, previousKey !== panel, previousKey.isVisible { previousKey.makeKeyAndOrderFront(nil) }
        else if let monitor = model?.monitorWindow, monitor.isVisible { monitor.makeKeyAndOrderFront(nil) }
        else { NSApp.deactivate() }
        previousKey = nil
    }

    private func toggleViewers() {
        if viewers != nil { closeViewers(); return }
        guard let model, let panel else { return }
        let popup = FloatingViewerPanel(model: model, anchor: panel, dismiss: { [weak self] in self?.closeViewers() })
        viewers = popup; popup.present()
    }
    private func closeViewers() {
        let restore = viewers?.isKeyWindow == true && NSApp.isActive
        viewers?.retire(); viewers = nil
        if restore {
            panel?.keyboardRequested = true; panel?.makeKeyAndOrderFront(nil)
            if let picture { panel?.makeFirstResponder(picture) }
        } else if panel?.isKeyWindow != true { panel?.keyboardRequested = false }
    }
    func windowWillClose(_ notification: Notification) {
        controls?.cancelActions(); closeViewers(); controls?.setKeyboard(false); model?.floatingVisibilityChanged(false)
    }
    func windowDidBecomeKey(_ notification: Notification) { controls?.setKeyboard(true) }
    func windowDidResignKey(_ notification: Notification) {
        controls?.setKeyboard(false)
        if viewers == nil { panel?.keyboardRequested = false }
    }
    func windowDidMove(_ notification: Notification) { viewers?.position() }
    func windowDidResize(_ notification: Notification) { viewers?.position() }
    func windowDidChangeScreen(_ notification: Notification) { viewers?.position() }

    private func updateAspect(_ size: NSSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        guard let fit = PreviewWindowLayout(source: size, frame: panel.frame, screen: screen) else { return }
        panel.contentAspectRatio = fit.aspect
        panel.minSize = fit.minimum
        if panel.frame != fit.frame { panel.setFrame(fit.frame, display: true) }
    }
}

@MainActor private final class PreviewPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onClose: (() -> Void)?
    var keyboardRequested = false
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating; isFloatingPanel = true; hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear; isOpaque = false; hasShadow = true; acceptsMouseMovedEvents = true
        autorecalculatesKeyViewLoop = false
        becomesKeyOnlyIfNeeded = true; allowsToolTipsWhenApplicationIsInactive = true
    }
    override var canBecomeKey: Bool { keyboardRequested }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func performClose(_ sender: Any?) { onClose?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command && event.charactersIgnoringModifiers == "w" {
            onClose?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor private final class FloatingPicture: NSView {
    var onHover: ((Bool) -> Void)?
    var onAspect: ((NSSize) -> Void)?
    var onKeyboardExit: (() -> Void)?
    var onPictureInteraction: (() -> Void)?
    private var picture: PreviewPicture?
    private let pictureView = PictureLayerView(gravity: .resize)
    private let imagePlane = PreviewImagePlane()
    private var heldVisual = false
    private var viewport = PreviewViewport()
    private var frames: AnyCancellable?
    private var tracking: NSTrackingArea?
    private var dragPoint: CGPoint?
    private var windowDrag: (pointer: CGPoint, origin: CGPoint)?
    private var windowResize: PreviewWindowResize?
    private let recovery: NSView
    /// Covers exactly the zoomed picture rectangle, so pointers follow zoom and pan.
    private let pointers: NSView

    init(model: SessionModel) {
        recovery = PassthroughHostingView(rootView: FloatingRecovery(model: model))
        pointers = PassthroughHostingView(rootView: FloatingPointers(model: model))
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = FloatingPreviewStyle.corner; layer?.masksToBounds = true
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("Floating feed preview")
        setAccessibilityHelp("Pinch or scroll to zoom. Drag a zoomed picture to pan. Double-click the picture outside the controls, or press 0, to restore the full picture. At full picture, drag to move the window.")
        imagePlane.wantsLayer = true; imagePlane.layer?.masksToBounds = true
        imagePlane.addSubview(pictureView); addSubview(imagePlane)
        addSubview(pointers)
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
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setHoldVisual(_ held: Bool) {
        guard held != heldVisual else { return }; heldVisual = held
        // A fixed, viewport-sized compositor filter. No second receive, decode or CPU frame copy.
        if held, let filter = CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: FloatingPreviewStyle.holdSaturation]) {
            imagePlane.contentFilters = [filter]
        } else {
            imagePlane.contentFilters = []
            imagePlane.layerUsesCoreImageFilters = false
        }
    }
    func refreshAspect() { if let picture { onAspect?(picture.size) } }
    func resetInspection() { viewport.reset(); inspectionChanged() }
    private func inspectionChanged() {
        layoutPicture(); window?.invalidateCursorRects(for: self)
        setAccessibilityValue(viewport.scale > 1.001 ? "Zoomed \(Int((viewport.scale * 100).rounded())) percent" : "Full picture")
    }
    override func draw(_ dirtyRect: NSRect) { NSColor.black.setFill(); bounds.fill() }
    /// The picture view occupies the zoomed image rectangle; this view's layer clips it.
    private func layoutPicture() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imagePlane.frame = bounds
        pictureView.frame = picture.map { viewport.imageRect(source: $0.size, bounds: bounds) } ?? .zero
        pointers.frame = pictureView.frame
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
    override func magnify(with event: NSEvent) { onPictureInteraction?(); zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) {
        onPictureInteraction?()
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
        onPictureInteraction?()
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
        if event.keyCode == 53 { onKeyboardExit?(); return }
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        }
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
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.55)
                    if !model.state.sharing { ProgressView().controlSize(.small) }
                    if geometry.size.height < 160 {
                        HStack {
                            Text(model.floatingRecoveryTitle).font(.caption2).lineLimit(1)
                                .help(model.floatingRecoveryTitle + ". " + model.frameAgeLabel)
                        }.foregroundStyle(.white).padding(.horizontal, 12).padding(.bottom, 12)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    } else {
                        VStack(spacing: 4) {
                            Text(model.floatingRecoveryTitle).font(.caption)
                            if model.lastFrameAt != nil { Text(model.frameAgeLabel).font(.caption2) }
                        }.foregroundStyle(.white).padding(.horizontal, 12)
                            .padding(.bottom, 12)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel(model.floatingRecoveryTitle + ". " + model.frameAgeLabel)
            }
        }
    }
}

private struct FloatingPointers: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        if model.showsPointers && model.localReady { PointerOverlay(presence: model.pointerPresence) }
    }
}

@MainActor private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class PreviewImagePlane: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
