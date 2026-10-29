import AppKit
import ScreenCaptureKit
import SwiftUI
import SetbeamCore

/// Small, transient chooser pictures. Never opens another stream for the monitored display.
@MainActor final class DisplaySourcePreviews: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    @Published private(set) var permissionGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var unavailable: Set<String> = []

    func refresh(displays: [MacDisplay], monitoredDisplayID: String?) async {
        permissionGranted = CGPreflightScreenCaptureAccess()
        images = images.filter { id, _ in displays.contains { $0.id == id } && id != monitoredDisplayID }
        unavailable = []
        guard permissionGranted else { images = [:]; return }
        let candidates = displays.filter { $0.id != monitoredDisplayID }
        guard !candidates.isEmpty else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            try Task.checkCancellation()
            let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            // Match the screen source's self-exclusion, including the chooser and floating window.
            guard !ownApplications.isEmpty else { images = [:]; unavailable = Set(candidates.map(\.id)); return }
            for candidate in candidates {
                try Task.checkCancellation()
                guard let display = content.displays.first(where: { MacDisplay.identity($0.displayID) == candidate.id }) else {
                    images[candidate.id] = nil; unavailable.insert(candidate.id); continue
                }
                let configuration = SCStreamConfiguration()
                let scale = min(240.0 / Double(candidate.width), 144.0 / Double(candidate.height))
                configuration.width = max(1, Int(Double(candidate.width) * scale))
                configuration.height = max(1, Int(Double(candidate.height) * scale))
                configuration.showsCursor = false
                configuration.capturesAudio = false
                let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
                do {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    try Task.checkCancellation()
                    images[candidate.id] = image
                } catch {
                    try Task.checkCancellation()
                    images[candidate.id] = nil; unavailable.insert(candidate.id)
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            images = [:]; unavailable = Set(candidates.map(\.id))
        }
    }

    func enable() {
        permissionGranted = MacScreenCapture.requestPermission()
        if !permissionGranted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func clear() { images = [:]; unavailable = [] }
}

struct DisplaySourceThumbnail: View {
    @ObservedObject var previews: DisplaySourcePreviews
    @ObservedObject var player: NativePreview
    let display: MacDisplay
    let monitored: Bool
    let pictureReady: Bool

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if monitored, pictureReady, let picture = player.picture {
                PictureView(picture: picture)
            } else if !monitored, let image = previews.images[display.id] {
                Image(decorative: image, scale: 2).resizable().scaledToFit()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: previews.permissionGranted ? "display" : "lock.display").font(.title3)
                    Text(!previews.permissionGranted ? "Preview off" : monitored || previews.unavailable.contains(display.id) ? "No preview" : "Loading…")
                        .font(.caption2)
                }.foregroundStyle(.secondary)
            }
        }
        .frame(width: 120, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}
