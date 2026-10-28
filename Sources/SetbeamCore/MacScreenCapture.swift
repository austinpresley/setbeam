import AppKit
import ScreenCaptureKit
import VideoToolbox
import Darwin

public struct MacDisplay: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let width: Int
    public let height: Int
    public let frameRate: Int

    public static func identity(_ display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
    public static func connected() -> [MacDisplay] {
        // AppKit display metadata belongs to the main thread, including runtime retries.
        guard Thread.isMainThread else { return DispatchQueue.main.sync { connected() } }
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let display = CGDirectDisplayID(number.uint32Value)
            guard let id = identity(display), let mode = CGDisplayCopyDisplayMode(display) else { return nil }
            return MacDisplay(id: id, name: screen.localizedName.isEmpty ? "Display" : screen.localizedName, width: mode.pixelWidth, height: mode.pixelHeight,
                              frameRate: max(1, min(60, Int((mode.refreshRate > 0 ? mode.refreshRate : 60).rounded()))))
        }
    }
    public static func resolve(_ id: String, in displays: [MacDisplay]) throws -> MacDisplay {
        guard let display = displays.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw SetbeamError.unavailable("Reconnect the selected display. Setbeam will wait for that same display.")
        }
        return display
    }
    public static func dimensions(width: Int, height: Int) -> (Int, Int) {
        let scale = min(1, min(3840.0 / Double(width), 2160.0 / Double(height)))
        return (max(2, Int(Double(width) * scale) / 2 * 2), max(2, Int(Double(height) * scale) / 2 * 2))
    }
}

/// One app-attributed capture. All native windows read the relay, never another SCStream.
public final class MacScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.setbeam.screen")
    private var stream: SCStream?
    private var encoder: ScreenEncoder?
    private var writer: VideoPipeWriter?
    private var pixel: CVPixelBuffer?
    private var timer: DispatchSourceTimer?
    private var active = false

    public static func requestPermission() -> Bool { CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() }

    public func start(displayUUID: String, output: FileHandle, frameRate: VideoFrameRate = .source) async throws {
        writer = VideoPipeWriter(output: output, queue: queue) { [weak self] in
            self?.active = false; self?.pixel = nil
        }
        guard CGPreflightScreenCaptureAccess() else { throw SetbeamError.unavailable("Allow Setbeam in Screen Recording, then retry.") }
        let selected = try MacDisplay.resolve(displayUUID, in: MacDisplay.connected())
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { MacDisplay.identity($0.displayID)?.caseInsensitiveCompare(displayUUID) == .orderedSame }) else {
            throw SetbeamError.unavailable("Reconnect the selected display. Setbeam will wait for that same display.")
        }
        let excluded = content.applications.filter { $0.processID == getpid() || $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        guard !excluded.isEmpty else {
            throw SetbeamError.unavailable("Setbeam could not exclude its own windows. Keep its main window open and retry.")
        }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let (width, height) = MacDisplay.dimensions(width: selected.width, height: selected.height)
        let fps = frameRate.captureRate(for: selected.frameRate)
        let configuration = SCStreamConfiguration()
        configuration.width = width; configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = 3; configuration.showsCursor = true; configuration.capturesAudio = false
        encoder = try ScreenEncoder(width: width, height: height, fps: fps, queue: queue) { [weak self] bytes in
            guard let self, self.active else { return }
            self.writer?.append(bytes)
        }
        let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
        stream = capture
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            active = true
            let clock = DispatchSource.makeTimerSource(queue: queue)
            clock.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
            clock.setEventHandler { [weak self] in
                guard let self, self.active, let pixel = self.pixel else { return }
                self.encoder?.encode(pixel)
            }
            timer = clock; clock.resume()
        }
        try await capture.startCapture()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard active, type == .screen, let image = sampleBuffer.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue else { return }
        pixel = image
    }
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in self?.active = false; self?.pixel = nil; self?.writer?.close() }
    }
    public func stop() {
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        queue.sync { active = false; timer?.cancel(); timer = nil; pixel = nil; writer?.close(); writer = nil; encoder?.invalidate(); encoder = nil }
    }
    deinit { stop() }
}
