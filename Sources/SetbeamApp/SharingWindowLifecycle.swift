import AppKit
import SwiftUI

/// Window.close does not reliably remove a SwiftUI Window's content. Observe the native lifetime.
struct SharingWindowLifecycle: NSViewRepresentable {
    let model: SessionModel
    func makeNSView(context: Context) -> NSView { Anchor(model: model) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Anchor: NSView {
        private weak var model: SessionModel?
        private weak var observedWindow: NSWindow?
        private var positioned = false
        init(model: SessionModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observedWindow { NotificationCenter.default.removeObserver(self, name: nil, object: observedWindow) }
            observedWindow = window
            model?.sharingWindow = window
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(closing), name: NSWindow.willCloseNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(presented), name: NSWindow.didBecomeKeyNotification, object: window)
            presented()
        }
        @objc private func presented() {
            guard let window else { return }
            guard let model, model.sharingSection != nil else {
                if window.isVisible { DispatchQueue.main.async { [weak window] in window?.close() } }
                return
            }
            if !positioned {
                positioned = true
                DispatchQueue.main.async { [weak window] in
                    window?.initialFirstResponder = nil
                    window?.makeFirstResponder(nil)
                }
                let main = model.monitorWindow?.frame ?? window.frame
                let screen = model.monitorWindow?.screen?.visibleFrame ?? window.screen?.visibleFrame ?? main
                var rect = window.frame
                rect.size.width = min(rect.width, screen.width)
                rect.size.height = min(rect.height, screen.height)
                let right = main.maxX + 12, left = main.minX - rect.width - 12
                rect.origin.x = right + rect.width <= screen.maxX ? right : left >= screen.minX ? left : screen.maxX - rect.width
                rect.origin.y = min(max(main.maxY - rect.height, screen.minY), screen.maxY - rect.height)
                window.setFrame(rect, display: false)
            }
        }
        @objc private func closing() {
            if model?.sharingInWindow == true { model?.closeSharing() }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

