import SwiftUI
import AppKit

struct PlayerView: View {
    @ObservedObject var player: NativePreview
    var body: some View {
        ZStack {
            Color(red: 0.12, green: 0.12, blue: 0.14)
            if let image = player.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).accessibilityLabel("Live feed preview")
            } else {
                ProgressView("Connecting to source").controlSize(.small).foregroundStyle(.secondary)
            }
        }.clipped()
    }
}

@MainActor final class FloatingPreviewWindow: NSObject, NSWindowDelegate {
    private weak var model: SessionModel?
    private var panel: NSPanel?
    init(model: SessionModel) { self.model = model }
    func show() {
        guard let model else { return }
        if panel == nil {
            let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
            let rect = CGRect(x: screen.maxX - 370, y: screen.minY + 30, width: 340, height: 191)
            let window = NSPanel(contentRect: rect, styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Setbeam Preview"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.level = .floating; window.isFloatingPanel = true; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentAspectRatio = NSSize(width: 16, height: 9); window.minSize = NSSize(width: 220, height: 124)
            window.contentView = NSHostingView(rootView: FloatingPlayer(model: model)); window.delegate = self
            window.setFrameAutosaveName("SetbeamFloatingPreview")
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.setFrame(rect, display: false) }
            panel = window
        }
        model.pipVisible = true; panel?.orderFrontRegardless()
    }
    func close() { panel?.close(); model?.pipVisible = false }
    func windowWillClose(_ notification: Notification) { model?.pipVisible = false }
}

private struct FloatingPlayer: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            PlayerView(player: model.localPlayer)
            VStack {
                HStack { Text(model.title).font(.caption).padding(.horizontal, 7).padding(.vertical, 4).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5)); Spacer() }.padding(.top, 29)
                Spacer()
                HStack { if !model.state.sourceAvailable { Text("Reconnecting").font(.caption).padding(6).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5)) }; Spacer(); Button { model.localMuted.toggle() } label: { Image(systemName: model.localMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").padding(6) }.buttonStyle(.plain).background(.ultraThinMaterial, in: Circle()).help(model.localMuted ? "Enable local sound" : "Mute local preview") }
            }.padding(9)
        }.background(.black)
    }
}
