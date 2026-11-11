import AppKit
import Combine

/// The approved preview has no chrome at rest except an actionable audience count.
enum FloatingPreviewStyle {
    static let inset: CGFloat = 8
    static let corner: CGFloat = 12
    static let smallControl: CGFloat = 28
    static let centerControl: CGFloat = 48
    static let darkControlScrim: CGFloat = 0.5
    static let wash: CGFloat = 0.22
    static let holdSaturation: Double = 0.72
    static let fade: TimeInterval = 0.16
}

@MainActor final class FloatingPreviewControls: NSView {
    let center = PreviewActionButton(symbol: "pause.fill", centerAction: true)
    let close = PreviewActionButton(symbol: "xmark")
    let audience = PreviewActionButton(symbol: "person.2")
    private let wash = PreviewWashView()
    private weak var model: SessionModel?
    private var observation: AnyCancellable?
    private var hovered = false
    private var keyboard = false
    private var lastWashed = false
    var showViewers: (() -> Void)?
    var holdVisualChanged: ((Bool) -> Void)?
    private var lastState: FloatingPreviewState?
    private var visibilityChanged = true
    private var displayObservation: AnyCancellable?

    init(model: SessionModel, close: @escaping () -> Void) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(false)
        wash.alphaValue = 0; addSubview(wash)
        self.close.onPress = close
        self.close.setAccessibilityLabel("Close floating preview")
        self.close.toolTip = "Close this preview. Local monitoring and sharing continue."
        audience.onPress = { [weak self] in self?.showViewers?() }
        for button in [self.close, center, audience] { addSubview(button) }
        // Read after the publisher's will-change notification, so all related values are coherent.
        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        displayObservation = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification).sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.visibilityChanged = true
                self?.center.refreshAccessibilityAppearance()
                self?.refresh()
            }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for button in [close, center, audience] where !button.isHidden {
            let point = NSPoint(x: local.x - button.frame.minX, y: local.y - button.frame.minY)
            if button.containsControlPoint(point) { return button }
        }
        return nil
    }
    func cancelActions() { center.cancelDeferredPointerAction() }
    func setHover(_ value: Bool) { guard hovered != value else { return }; hovered = value; visibilityChanged = true; refresh() }
    func setKeyboard(_ value: Bool) { guard keyboard != value else { return }; keyboard = value; visibilityChanged = true; refresh() }

    func refresh() {
        guard let model else { return }
        let state = model.floatingPresentation
        guard state != lastState || visibilityChanged else { return }
        lastState = state; visibilityChanged = false
        if state.washed != lastWashed {
            let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduced ? 0 : FloatingPreviewStyle.fade
                wash.animator().alphaValue = state.washed ? 1 : 0
            }
            lastWashed = state.washed; holdVisualChanged?(state.washed)
        }
        close.isHidden = !(hovered || keyboard)
        center.isHidden = !state.centerVisible(hovered: hovered, keyboard: keyboard)
        center.isEnabled = state.enabled
        center.spinning = state.center == .pending
        center.symbol = state.symbol
        center.defersPointerResume = state.target == .resume
        let intended = state.target
        center.onPress = { [weak model] in
            guard let model, let intended else { return }
            let current = model.floatingPresentation
            guard current.enabled, current.target == intended else { return }
            model.setAudienceHold(intended.holding)
        }
        center.setAccessibilityLabel(state.label); center.toolTip = state.label
        center.setAccessibilityValue(state.washed ? "Viewers on Hold" : "")
        audience.isHidden = !state.audience.visible
        audience.symbol = state.audience.symbol
        audience.count = state.audience.count
        audience.light = state.audience.waiting > 0
        audience.setAccessibilityLabel(state.audience.label); audience.toolTip = state.audience.label
        needsLayout = true
    }
    override func layout() {
        super.layout()
        wash.frame = bounds
        let inset = FloatingPreviewStyle.inset, small = FloatingPreviewStyle.smallControl
        close.frame = NSRect(x: inset, y: inset, width: small, height: small)
        let countWidth: CGFloat = audience.count ?? 0 >= 10 ? 56 : 48
        audience.frame = NSRect(x: bounds.width - inset - countWidth, y: inset, width: countWidth, height: small)
        let size = FloatingPreviewStyle.centerControl
        let scale = window?.backingScaleFactor ?? 2
        // grid: ok geometric centering is pixel-aligned rather than tied to a leading column.
        let x = ((bounds.width - size) / 2 * scale).rounded() / scale
        let y = ((bounds.height - size) / 2 * scale).rounded() / scale
        center.frame = NSRect(x: x, y: y, width: size, height: size)
    }
}

@MainActor private final class PreviewWashView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(FloatingPreviewStyle.wash).setFill(); bounds.fill()
    }
}

/// Native buttons retain accessibility and deliberate keyboard navigation, but pointer use never
/// requests key status. The material is only behind a control, never across the source picture.
@MainActor final class PreviewActionButton: NSButton {
    var onPress: (() -> Void)?
    var defersPointerResume = false
    var symbol: String { didSet { guard symbol != oldValue else { return }; needsDisplay = true; face.needsDisplay = true } }
    var count: Int? { didSet { guard count != oldValue else { return }; needsDisplay = true; face.needsDisplay = true } }
    var light = false { didSet { guard light != oldValue else { return }; configureMaterial(); needsDisplay = true; face.needsDisplay = true } }
    var spinning = false { didSet { guard spinning != oldValue else { return }; updateSpinner(); needsDisplay = true; face.needsDisplay = true } }
    private let material = PreviewMaterialView()
    private let face = PreviewButtonFace()
    private let spinner = NSProgressIndicator()
    private let centerAction: Bool
    private var clickGate = FloatingClickGate()
    private var resumeTask: Task<Void, Never>?
    private var pointerResumePending = false
    private var showsSpinner: Bool { spinning || pointerResumePending }

    init(symbol: String, centerAction: Bool = false) {
        self.symbol = symbol; self.centerAction = centerAction
        super.init(frame: .zero)
        title = ""; isBordered = false; setButtonType(.momentaryChange)
        target = self; action = #selector(nativeAction(_:))
        focusRingType = .default
        material.state = .active; material.blendingMode = .withinWindow
        material.wantsLayer = true; addSubview(material)
        face.owner = self; addSubview(face)
        spinner.style = .spinning; spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false; spinner.setAccessibilityElement(false)
        addSubview(spinner)
        configureMaterial()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isEnabled: Bool { didSet { if isEnabled != oldValue { if !isEnabled { cancelPointerResume() }; needsDisplay = true; face.needsDisplay = true } } }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { containsControlPoint(convert(point, from: superview)) ? self : nil }
    func containsControlPoint(_ point: NSPoint) -> Bool {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).contains(point)
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill() }

    private func configureMaterial() {
        material.material = light ? .popover : .hudWindow
        material.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        spinner.appearance = material.appearance
    }
    func refreshAccessibilityAppearance() { updateSpinner(); needsDisplay = true; face.needsDisplay = true }
    private func updateSpinner() {
        if showsSpinner && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil) }
    }
    override func layout() {
        super.layout(); material.frame = bounds; face.frame = bounds; material.layer?.cornerRadius = bounds.height / 2
        material.layer?.masksToBounds = true
        spinner.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }
    override func draw(_ dirtyRect: NSRect) {}
    fileprivate func drawFace() {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if !light { NSColor.black.withAlphaComponent(FloatingPreviewStyle.darkControlScrim).setFill(); shape.fill() }
        (light ? NSColor.white.withAlphaComponent(isEnabled ? 0.75 : 0.3) : NSColor.white.withAlphaComponent(isEnabled ? 0.3 : 0.15)).setStroke()
        shape.lineWidth = 1; shape.stroke()
        if isHighlighted { NSColor.white.withAlphaComponent(0.14).setFill(); shape.fill() }
        guard !showsSpinner || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let foreground: NSColor = (light ? NSColor(calibratedWhite: 0.16, alpha: 1) : .white).withAlphaComponent(isEnabled || showsSpinner ? 1 : 0.4)
        let pointSize: CGFloat = centerAction ? 20 : count == nil ? 12 : 14
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: foreground))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let text = count.map(String.init) ?? ""
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: foreground]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let imageSize = image?.size ?? .zero
        let total = imageSize.width + (count == nil ? 0 : 4 + textSize.width)
        let x = (bounds.width - total) / 2
        image?.draw(in: NSRect(x: x, y: (bounds.height - imageSize.height) / 2, width: imageSize.width, height: imageSize.height))
        if count != nil { (text as NSString).draw(at: NSPoint(x: x + imageSize.width + 4, y: (bounds.height - textSize.height) / 2), withAttributes: attributes) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        let start = convert(event.locationInWindow, from: nil)
        let pressedAction = onPress
        var dragged = false
        isHighlighted = true; needsDisplay = true; face.needsDisplay = true
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            if hypot(point.x - start.x, point.y - start.y) > 4 { dragged = true }
            isHighlighted = !dragged && containsControlPoint(point); needsDisplay = true; face.needsDisplay = true
            if next.type == .leftMouseUp {
                isHighlighted = false; needsDisplay = true; face.needsDisplay = true
                if containsControlPoint(point) { activate(at: next.timestamp, count: event.clickCount, dragged: dragged, action: pressedAction, pointer: true) }
                break
            }
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        } else { super.keyDown(with: event) }
    }
    @objc private func nativeAction(_ sender: Any?) { activate(at: ProcessInfo.processInfo.systemUptime) }
    override func performClick(_ sender: Any?) { activate(at: ProcessInfo.processInfo.systemUptime) }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, !isHidden else { return false }
        performClick(nil); return true
    }
    private func activate(at time: TimeInterval, count: Int = 1, dragged: Bool = false, action: (() -> Void)? = nil, pointer: Bool = false) {
        if centerAction && count > 1 { cancelPointerResume(); return }
        guard isEnabled, !isHidden, !dragged else { return }
        if centerAction, !clickGate.accept(at: time, count: count, dragged: dragged, interval: NSEvent.doubleClickInterval) { return }
        let invoke = action ?? onPress
        if centerAction && pointer && defersPointerResume {
            cancelPointerResume(); pointerResumePending = true; refreshAccessibilityAppearance()
            resumeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(NSEvent.doubleClickInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.pointerResumePending = false; self.resumeTask = nil; self.refreshAccessibilityAppearance()
                guard self.isEnabled, !self.isHidden, self.window?.isVisible == true else { return }
                invoke?()
            }
        } else { invoke?() }
    }
    func cancelDeferredPointerAction() { cancelPointerResume() }
    private func cancelPointerResume() {
        resumeTask?.cancel(); resumeTask = nil; pointerResumePending = false
        refreshAccessibilityAppearance()
    }
}

@MainActor private final class PreviewMaterialView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class PreviewButtonFace: NSView {
    weak var owner: PreviewActionButton?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { owner?.drawFace() }
}
