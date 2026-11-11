import AppKit
import Combine
import SwiftUI
import SetbeamCore

/// On-demand viewer actions are separate from the picture and never activate a background app.
@MainActor final class FloatingViewerPanel: NSPanel {
    private weak var anchor: NSWindow?
    private weak var model: SessionModel?
    private let dismiss: () -> Void
    private var observation: AnyCancellable?
    private var outsideClick: Any?
    private var localClick: Any?
    private var keyboardRequested = false
    private var contentHeight: CGFloat?

    init(model: SessionModel, anchor: NSWindow, dismiss: @escaping () -> Void) {
        self.model = model; self.anchor = anchor; self.dismiss = dismiss
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Setbeam Preview Viewers"
        level = .floating; isFloatingPanel = true; hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear; isOpaque = false; hasShadow = true
        becomesKeyOnlyIfNeeded = true; allowsToolTipsWhenApplicationIsInactive = true
        contentView = ViewerHostingView(rootView: FloatingViewerList(model: model, dismiss: dismiss, measured: { [weak self] height in
            guard let self, height > 0, self.contentHeight != height else { return }
            self.contentHeight = height; self.position()
        }))
        observation = model.objectWillChange.sink { [weak self, weak model] _ in
            DispatchQueue.main.async {
                guard let self, let model else { return }
                if model.state.sharing { self.position() } else { self.dismiss() }
            }
        }
    }
    override var canBecomeKey: Bool { keyboardRequested }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss() }

    func present() {
        guard let anchor else { return }
        position(); anchor.addChildWindow(self, ordered: .above); orderFrontRegardless()
        if anchor.isKeyWindow { keyboardRequested = true; makeKeyAndOrderFront(nil); makeFirstResponder(contentView); selectNextKeyView(nil) }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self, event.window !== self.anchor { self.dismiss() }
            }
            return event
        }
    }
    func position() {
        guard let anchor, let model else { return }
        let screen = anchor.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor.frame
        let natural = contentHeight.map { $0 + 36 } ?? CGFloat(120 + model.pendingViewers.count * 80 + model.admittedViewers.count * 56)
        let height = min(min(400, screen.height - 16), max(120, natural))
        let width: CGFloat = 320
        let below = anchor.frame.minY - height - 8
        let y = below >= screen.minY ? below : min(screen.maxY - height, anchor.frame.maxY + 8)
        let x = min(max(anchor.frame.maxX - width, screen.minX), screen.maxX - width)
        let next = NSRect(x: x, y: max(screen.minY, y), width: width, height: height)
        if next != frame { setFrame(next, display: isVisible) }
    }
    func retire() {
        observation = nil
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }; outsideClick = nil
        if let localClick { NSEvent.removeMonitor(localClick) }; localClick = nil
        anchor?.removeChildWindow(self); orderOut(nil); close(); contentView = nil
    }
}

@MainActor private final class ViewerHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
}

private struct FloatingViewerList: View {
    @ObservedObject var model: SessionModel
    let dismiss: () -> Void
    let measured: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Viewers").font(.headline)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("Close viewer actions").accessibilityLabel("Close viewer actions")
            }.padding(.horizontal, 16).padding(.top, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.pendingViewers.isEmpty {
                        Text("\(model.pendingViewers.count) asking to join").font(.headline)
                        ForEach(model.pendingViewers) { viewer in row(viewer, pending: true) }
                        Divider()
                    }
                    Text("\(model.admittedViewers.count) joined").font(.headline)
                    ForEach(model.admittedViewers) { viewer in row(viewer, pending: false) }
                    Text("Names are chosen by viewers and are not verified.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(16)
                    .background(GeometryReader { geometry in Color.clear.preference(key: ViewerContentHeight.self, value: geometry.size.height) })
            }
        }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
            .onPreferenceChange(ViewerContentHeight.self, perform: measured)
            .accessibilityElement(children: .contain).accessibilityLabel("Floating preview viewer actions")
    }
    private func row(_ viewer: ViewerActivity, pending: Bool) -> some View {
        let reference = JoinRequest(viewer, link: model.viewingLink)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewer.displayName).lineLimit(1).help(viewer.displayName)
                Text("Session \(viewer.number)").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if pending {
                Button("Admit") { if model.answer(reference, admit: true), model.pendingViewers.isEmpty { dismiss() } }.buttonStyle(CardButtonStyle(prominent: true))
                    .accessibilityLabel("Admit \(viewer.displayName), session \(viewer.number)")
                Button("Decline") { if model.answer(reference, admit: false), model.pendingViewers.isEmpty { dismiss() } }.buttonStyle(CardButtonStyle(prominent: false))
                    .accessibilityLabel("Decline \(viewer.displayName), session \(viewer.number)")
            } else if model.viewerApproval {
                Button("Remove") { model.removeViewer(reference) }.buttonStyle(CardButtonStyle(prominent: false))
                    .accessibilityLabel("Remove \(viewer.displayName), session \(viewer.number)")
            }
        }
    }
}

private struct ViewerContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
