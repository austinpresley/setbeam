import SwiftUI
import AppKit
import SetbeamCore

/// One request to join as the operator saw it. Its viewing link and session number identify it, and its
/// join time tells it apart from a later request that reuses the number.
struct JoinRequest: Identifiable, Equatable {
    let link: Int
    let number: Int
    let joinedAt: Date
    let name: String
    let label: String
    let color: PointerColor
    let shortAddress: Bool
    var id: String { "\(link)-\(number)" }

    init(_ viewer: ViewerActivity, link: Int) {
        self.link = link; number = viewer.number; joinedAt = viewer.joinedAt; name = viewer.displayName
        label = viewer.label; color = viewer.color; shortAddress = viewer.shortAddress
    }
    /// The same request if it is still waiting on the current link. Anything else is a stale card.
    func current(in viewers: [ViewerActivity], link current: Int, admission: ViewerAdmission = .pending) -> ViewerActivity? {
        guard link == current else { return nil }
        return viewers.first { $0.number == number && $0.admission == admission && $0.joinedAt == joinedAt }
    }
}

/// Which requests are waiting and which are new. Heartbeats, a reloaded waiting tab, and list refreshes
/// never announce a request again. A new viewing link starts over.
struct JoinRequestTracker {
    private(set) var link: Int?
    private var announced: Set<Int> = []
    private(set) var pending: [JoinRequest] = []

    /// Returns the requests to announce now.
    mutating func observe(link: Int, active: Bool, viewers: [ViewerActivity]) -> [JoinRequest] {
        if link != self.link { self.link = link; announced = [] }
        pending = active ? viewers.filter { $0.admission == .pending }.sorted { $0.number < $1.number }.map { JoinRequest($0, link: link) } : []
        let fresh = pending.filter { !announced.contains($0.number) }
        announced.formUnion(fresh.map(\.number))
        return fresh
    }
}

/// Announces requests to join with a card in the screen corner that keeps other apps in front.
///
/// The card is a convenience: every request also stays in the sharing bar, Viewers, the
/// floating preview's controls, the menu bar, and the Dock badge until it is answered. It hides itself
/// after a while, when dismissed, when nothing is waiting, and at Stop.
@MainActor final class JoinRequestCenter: ObservableObject {
    weak var model: SessionModel?
    @Published private(set) var requests: [JoinRequest] = []
    @Published private(set) var isShowing = false
    /// Requests announced since launch. Diagnostics only.
    private(set) var alerts = 0
    static let visibleFor: TimeInterval = 20
    private var tracker = JoinRequestTracker()
    private var panel: JoinRequestPanel?
    private var hideTask: Task<Void, Never>?
    private var hovering = false
    private var attention: Int?

    /// Unit tests have no running application, so they never show windows or touch the Dock.
    private var presents: Bool { NSApp != nil && NSApp.isRunning }

    func observe(link: Int, active: Bool, viewers: [ViewerActivity]) {
        let fresh = tracker.observe(link: link, active: active, viewers: viewers)
        if tracker.pending != requests { requests = tracker.pending; panel?.fit() }
        updateBadge()
        guard !requests.isEmpty else { hide(); endAttention(); return }
        if !fresh.isEmpty { announce(fresh) }
    }

    private func announce(_ fresh: [JoinRequest]) {
        alerts += fresh.count
        SessionLog.shared.record("viewer.request.alert", ["count": fresh.count, "shortAddress": fresh.filter(\.shortAddress).count])
        guard presents else { return }
        // The Viewers panel already lists every request while its window is in front.
        if !ViewerRequestPresentation.isVisible(appActive: NSApp.isActive, section: model?.sharingSection,
            detached: model?.sharingInWindow == true,
            keyIsMonitor: NSApp.keyWindow != nil && NSApp.keyWindow === model?.monitorWindow,
            keyIsSharing: NSApp.keyWindow != nil && NSApp.keyWindow === model?.sharingWindow,
            hasSheet: model?.sheet != nil) { show() }
        let words = fresh.count == 1 ? "\(fresh[0].name) asks to join" : "\(fresh.count) viewers ask to join"
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        // One Dock bounce. It never brings Setbeam forward.
        if !NSApp.isActive, attention == nil { attention = NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Shows the card again, for example from the menu bar or the floating preview.
    func show() {
        guard presents, !requests.isEmpty else { return }
        if panel == nil { panel = JoinRequestPanel(center: self) }
        panel?.present(on: Self.screen())
        isShowing = true
        scheduleHide()
    }
    func dismiss() {
        SessionLog.shared.record("viewer.request.card", ["action": "dismiss"])
        hide()
    }
    func hoverChanged(_ inside: Bool) { hovering = inside; if inside { hideTask?.cancel() } else { scheduleHide() } }
    func answer(_ request: JoinRequest, admit: Bool) {
        if model?.answer(request, admit: admit) != true {
            // Already decided, lapsed, or from an earlier link: refresh the card rather than act.
            SessionLog.shared.record("viewer.request.stale", ["admit": admit])
            if let model { observe(link: model.viewingLink, active: model.state.sharing && model.viewerApproval, viewers: model.viewers) }
        }
    }
    func reviewAll() {
        hide()
        guard let model else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !model.sharingInWindow && model.sheet == nil { model.monitorWindow?.makeKeyAndOrderFront(nil) }
        model.showSharing(.viewers)
    }
    func close() { hide(); panel?.close(); panel = nil; requests = []; updateBadge(); endAttention() }

    private func hide() {
        hideTask?.cancel(); hideTask = nil
        guard isShowing else { return }
        isShowing = false; panel?.orderOut(nil)
    }
    private func scheduleHide() {
        hideTask?.cancel()
        guard !hovering else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.visibleFor * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }
    private func updateBadge() {
        guard presents else { return }
        let label = requests.isEmpty ? nil : "\(requests.count)"
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }
    private func endAttention() {
        if let attention, presents { NSApp.cancelUserAttentionRequest(attention) }
        attention = nil
    }

    /// The screen the operator is watching: the main window's while Setbeam is in front, otherwise
    /// the floating preview's, then the main window's, then the main screen.
    private static func screen() -> NSScreen? {
        let shown = NSApp.windows.filter { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
        let main = shown.first { $0.canBecomeMain }, floating = shown.first { $0.title == "Setbeam Preview" }
        return (NSApp.isActive ? main?.screen : nil) ?? floating?.screen ?? main?.screen ?? NSScreen.main
    }
}

/// A borderless card that floats above other apps and the floating preview without taking focus.
@MainActor private final class JoinRequestPanel: NSPanel {
    private let host: FirstClickHostingView<JoinRequestCard>
    private static let margin: CGFloat = 12

    init(center: JoinRequestCenter) {
        host = FirstClickHostingView(rootView: JoinRequestCard(center: center))
        super.init(contentRect: CGRect(x: 0, y: 0, width: JoinRequestCard.width, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        title = "Setbeam Join Requests"
        level = .statusBar; isFloatingPanel = true; hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear; isOpaque = false; hasShadow = true
        // Full names and routes in tooltips, while another app stays in front.
        allowsToolTipsWhenApplicationIsInactive = true
        contentView = host
        setAccessibilityLabel("Join requests")
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(on screen: NSScreen?) {
        let area = screen?.visibleFrame ?? self.screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let size = host.fittingSize
        setFrame(CGRect(x: area.maxX - size.width - Self.margin, y: area.maxY - size.height - Self.margin,
                        width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }
    /// Keeps the top edge in place as rows come and go.
    func fit() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            let size = self.host.fittingSize, top = self.frame.maxY
            self.setFrame(CGRect(x: self.frame.maxX - size.width, y: top - size.height, width: size.width, height: size.height), display: true)
        }
    }
}

/// Buttons answer the first click, so the card works while another app stays in front.
@MainActor private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct JoinRequestCard: View {
    static let width: CGFloat = 352
    static let rowsShown = 3
    @ObservedObject var center: JoinRequestCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "person.badge.clock").font(.title3).foregroundStyle(Color.accentColor).frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(center.requests.count == 1 ? "Asking to join" : "\(center.requests.count) asking to join").font(.headline)
                    let title = center.model?.title ?? "Setbeam"
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(title)
                }
                Spacer(minLength: 8)
                Button { center.dismiss() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Hide. Requests stay in Viewers until you answer them.")
                    .accessibilityLabel("Hide join requests")
            }
            ForEach(center.requests.prefix(Self.rowsShown)) { request in row(request) }
            HStack(alignment: .firstTextBaseline) {
                Text("Names are chosen by viewers and are not verified.").font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                let more = center.requests.count - Self.rowsShown
                Button(more > 0 ? "\(more) more…" : "Review…") { center.reviewAll() }.buttonStyle(.link).font(.caption)
                    .help("Open Viewers")
                    .accessibilityLabel(more > 0 ? "Review \(more) more requests in Viewers" : "Review in Viewers")
            }
        }
        .padding(14).frame(width: Self.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
        .onHover { center.hoverChanged($0) }
        .accessibilityElement(children: .contain).accessibilityLabel("Join requests")
    }

    private func row(_ request: JoinRequest) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(Color(red: request.color.rgb.red, green: request.color.rgb.green, blue: request.color.rgb.blue))
                .frame(width: 10, height: 10).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                let route = route(request), device = "Session \(request.number) · \(request.label.replacingOccurrences(of: " browser", with: ""))"
                Text(request.name).fontWeight(.medium).lineLimit(1).truncationMode(.tail).help(request.name)
                Text(route).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(route)
                Text(device).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(device)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            Button("Decline") { center.answer(request, admit: false) }.buttonStyle(CardButtonStyle(prominent: false))
                .accessibilityLabel("Decline \(request.name), session \(request.number)")
            Button("Admit") { center.answer(request, admit: true) }.buttonStyle(CardButtonStyle(prominent: true))
                .accessibilityLabel("Admit \(request.name), session \(request.number)")
        }
    }

    private func route(_ request: JoinRequest) -> String {
        request.shortAddress ? "Typed \(center.model?.shortAddressHost ?? "the local address")" : "Opened the viewing link"
    }
}

/// Small push buttons for the card. System bordered buttons draw dimmed while Setbeam is in the
/// background, which is when the card matters most, so the card draws its own.
struct CardButtonStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View { CardButton(configuration: configuration, prominent: prominent) }
}

private struct CardButton: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.self) private var environment
    @State private var hovering = false

    var body: some View {
        let dark = environment.colorScheme == .dark
        let palette = prominent ? CardButtonPalette.prominent(accent: .init(Color.accentColor.resolve(in: environment))) : .secondary(dark: dark)
        let phase: CardButtonPalette.Phase = configuration.isPressed ? .pressed : hovering ? .hover : .rest
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label.font(.callout.weight(prominent ? .semibold : .regular))
            .foregroundStyle(palette.text.color)
            .padding(.horizontal, 10).frame(minWidth: 64, minHeight: 24)
            .background(palette.fill(phase).color, in: shape)
            .overlay { if phase != .rest { shape.strokeBorder(palette.text.color.opacity(0.3)) } }
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}

/// Text and fill for the card's buttons, readable on every accent color in both modes.
///
/// Admit fills with the accent, deepened (white text) or lightened (dark text) until the label reaches
/// `target`. Hover and press move the fill further from the text, so they only raise contrast.
struct CardButtonPalette: Equatable {
    /// An sRGB color, each component from 0 to 1.
    struct RGB: Equatable {
        var red, green, blue: Double
        init(_ red: Double, _ green: Double, _ blue: Double) { self.red = red; self.green = green; self.blue = blue }
        init(_ color: Color.Resolved) { self.init(Double(color.red), Double(color.green), Double(color.blue)) }
        var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
        static let white = RGB(1, 1, 1), ink = RGB(0.07, 0.07, 0.08)
        func mixed(with other: RGB, _ amount: Double) -> RGB {
            RGB(red + (other.red - red) * amount, green + (other.green - green) * amount, blue + (other.blue - blue) * amount)
        }
        /// WCAG relative luminance.
        var luminance: Double {
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }
    enum Phase: CaseIterable { case rest, hover, pressed }

    /// Small custom text aims for 7:1. 4.5:1 is the floor.
    static let target = 7.0
    let text: RGB
    let restFill: RGB

    func fill(_ phase: Phase) -> RGB {
        let away = text.luminance > 0.5 ? RGB(0, 0, 0) : RGB(1, 1, 1)
        return restFill.mixed(with: away, [Phase.rest: 0, .hover: 0.15, .pressed: 0.3][phase]!)
    }
    func contrast(_ phase: Phase) -> Double { Self.contrast(text, fill(phase)) }

    static func contrast(_ first: RGB, _ second: RGB) -> Double {
        let (light, dark) = (max(first.luminance, second.luminance), min(first.luminance, second.luminance))
        return (light + 0.05) / (dark + 0.05)
    }

    /// White on deep and mid accents such as blue, red, and graphite. Dark text on light accents such
    /// as yellow, orange, and green, where deepening the fill far enough for white would turn it brown.
    static func prominent(accent: RGB) -> CardButtonPalette {
        let text = contrast(.white, accent) >= 3 ? RGB.white : .ink
        let away = text == .white ? RGB(0, 0, 0) : RGB(1, 1, 1)
        let amount = stride(from: 0.0, through: 1, by: 0.01).first { contrast(text, accent.mixed(with: away, $0)) >= target } ?? 1
        return CardButtonPalette(text: text, restFill: accent.mixed(with: away, amount))
    }
    /// Decline: a neutral fill that stands apart from the card's material in either mode.
    static func secondary(dark: Bool) -> CardButtonPalette {
        dark ? CardButtonPalette(text: RGB(0.96, 0.96, 0.97), restFill: RGB(0.32, 0.32, 0.33))
             : CardButtonPalette(text: RGB(0.11, 0.11, 0.12), restFill: RGB(0.86, 0.86, 0.87))
    }
}
