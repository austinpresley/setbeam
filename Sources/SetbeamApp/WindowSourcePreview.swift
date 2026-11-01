import AppKit
import ScreenCaptureKit
import SwiftUI
import SetbeamCore

/// Lists shareable windows and keeps small, transient pictures of the ones on screen in the chooser.
/// Requires an existing Screen Recording grant; it never asks for one. One screenshot runs at a time,
/// the monitored window reuses the existing feed, and closing the chooser discards everything.
@MainActor final class WindowSourcePreviews: ObservableObject {
    @Published private(set) var windows: [MacWindow] = []
    @Published private(set) var images: [MacWindowIdentity: CGImage] = [:]
    @Published private(set) var unavailable: Set<MacWindowIdentity> = []
    @Published private(set) var loaded = false
    @Published private(set) var listFailed = false
    private(set) var icons: [Int32: NSImage] = [:]
    private var handles: [MacWindowIdentity: SCWindow] = [:]
    private var visible: Set<MacWindowIdentity> = []
    private var generation = 0
    /// Bounds each refresh pass; rows scrolled out of view are skipped.
    static let picturesPerPass = 9
    private let list: @MainActor () async throws -> [(window: MacWindow, handle: SCWindow?)]
    private let capture: @MainActor (MacWindow, SCWindow?) async throws -> CGImage

    init(list: @escaping @MainActor () async throws -> [(window: MacWindow, handle: SCWindow?)] = { try await MacWindow.shareable().map { ($0.window, $0.handle) } },
         capture: @escaping @MainActor (MacWindow, SCWindow?) async throws -> CGImage = WindowSourcePreviews.picture) {
        self.list = list; self.capture = capture
    }

    func refresh(permitted: Bool, monitored: MacWindowIdentity?) async {
        guard permitted else { clear(); return }
        let token = generation
        let found: [(window: MacWindow, handle: SCWindow?)]
        do { found = try await list() } catch {
            guard !Task.isCancelled, token == generation else { return }
            windows = []; images = [:]; handles = [:]; unavailable = []; loaded = true; listFailed = true; return
        }
        guard !Task.isCancelled, token == generation else { return }
        let ids = Set(found.map(\.window.identity))
        windows = found.map(\.window); loaded = true; listFailed = false
        handles = Dictionary(found.compactMap { item in item.handle.map { (item.window.identity, $0) } }, uniquingKeysWith: { first, _ in first })
        images = images.filter { ids.contains($0.key) && $0.key != monitored }
        unavailable.formIntersection(ids); visible.formIntersection(ids)
        for window in windows where icons[window.identity.processID] == nil {
            icons[window.identity.processID] = NSRunningApplication(processIdentifier: window.identity.processID)?.icon
        }
        icons = icons.filter { pid, _ in windows.contains { $0.identity.processID == pid } }
        // Before rows report their visibility, the first rows are the ones on screen.
        let wanted = windows.filter { $0.identity != monitored && (visible.isEmpty || visible.contains($0.identity)) }.prefix(Self.picturesPerPass)
        for window in wanted {
            guard !Task.isCancelled, token == generation else { return }
            do {
                let image = try await capture(window, handles[window.identity])
                guard !Task.isCancelled, token == generation, windows.contains(window) else { return }
                images[window.identity] = image; unavailable.remove(window.identity)
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                images[window.identity] = nil; unavailable.insert(window.identity)
            }
        }
    }

    func appeared(_ id: MacWindowIdentity) { visible.insert(id) }
    func disappeared(_ id: MacWindowIdentity) { visible.remove(id) }

    /// Invalidates any screenshot still in flight so its result is discarded.
    func clear() {
        generation += 1
        windows = []; images = [:]; unavailable = []; handles = [:]; visible = []; icons = [:]; loaded = false; listFailed = false
    }

    /// Fits the whole window into twice the thumbnail frame, without its shadow or the desktop.
    static func picture(of window: MacWindow, handle: SCWindow?) async throws -> CGImage {
        guard let handle else { throw SetbeamError.unavailable(MacWindowLocator.closedMessage) }
        let filter = SCContentFilter(desktopIndependentWindow: handle)
        let size = filter.contentRect.size
        guard size.width > 0, size.height > 0 else { throw SetbeamError.unavailable(MacWindowLocator.hiddenMessage) }
        let scale = min(2 * WindowSourceThumbnail.size.width / size.width, 2 * WindowSourceThumbnail.size.height / size.height, CGFloat(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(size.width * scale)); configuration.height = max(2, Int(size.height * scale))
        configuration.scalesToFit = true; configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true; configuration.ignoreGlobalClipSingleWindow = true
        configuration.showsCursor = false; configuration.capturesAudio = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

struct WindowSourceThumbnail: View {
    static let size = CGSize(width: 140, height: 84)
    @ObservedObject var previews: WindowSourcePreviews
    @ObservedObject var player: NativePreview
    let window: MacWindow
    let monitored: Bool
    let pictureReady: Bool

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if monitored, pictureReady, let picture = player.picture {
                PictureView(picture: picture)
            } else if !monitored, let image = previews.images[window.identity] {
                Image(decorative: image, scale: 2).resizable().scaledToFit()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "macwindow").font(.title3)
                    Text(monitored || previews.unavailable.contains(window.identity) ? "No preview" : "Loading…").font(.caption2)
                }.foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1), lineWidth: 1) }
        .overlay(alignment: .bottomTrailing) {
            if let icon = previews.icons[window.identity.processID] {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20).shadow(radius: 1).padding(4)
            }
        }
        .accessibilityHidden(true)
    }
}
