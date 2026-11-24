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

/// One app-attributed capture of a display or a single window. All native windows read the relay, never another SCStream.
public final class MacScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.setbeam.screen")
    private var stream: SCStream?
    private var encoder: ScreenEncoder?
    private var writer: VideoPipeWriter?
    private var pixel: CVPixelBuffer?
    private var timer: DispatchSourceTimer?
    private var active = false
    private var cursorSource: PresenterCursorSource?
    private var cursorHighlightEnabled = false
    private var cursorFrame: PresenterCursorFrame?
    private var highlightedPixel: CVPixelBuffer?
    private var cursorCompositor: PresenterCursorHighlight?
    private var encoderTick: UInt64 = 0
    private var windowValidation: (tick: UInt64, frame: PresenterCursorFrame, pixel: CVPixelBuffer)?

    public static func requestPermission() -> Bool { CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() }

    public func start(displayUUID: String, output: FileHandle, frameRate: VideoFrameRate = .source) async throws {
        prepareOutput(output)
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
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = true
        try await begin(filter: filter, configuration: configuration, width: width, height: height,
                        fps: frameRate.captureRate(for: selected.frameRate),
                        cursorSource: .display(display.displayID, uuid: selected.id, excluded: Set(excluded.map(\.processID))))
    }

    /// Captures only the exact window, wherever it moves, never the desktop around it. Its pixel
    /// size at start sets the stream size; a later resize is fitted inside without cropping.
    public func start(window identity: MacWindowIdentity, output: FileHandle, frameRate: VideoFrameRate = .source) async throws {
        prepareOutput(output)
        guard CGPreflightScreenCaptureAccess() else { throw SetbeamError.unavailable("Allow Setbeam in Screen Recording, then retry.") }
        // Setbeam's own windows would mirror themselves; the chooser never lists them.
        guard identity.processID != getpid() else { throw SetbeamError.invalidSource("Choose another application's window.") }
        try MacWindowLocator.require(identity)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        // Re-check after the await: the owner must still be the same process.
        try MacWindowLocator.require(identity)
        guard let window = content.windows.first(where: { $0.windowID == identity.windowID && $0.owningApplication?.processID == identity.processID }) else {
            throw SetbeamError.unavailable(MacWindowLocator.closedMessage)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(max(1, filter.pointPixelScale))
        let (width, height) = MacDisplay.dimensions(width: max(2, Int((filter.contentRect.width * scale).rounded())),
                                                    height: max(2, Int((filter.contentRect.height * scale).rounded())))
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = true
        configuration.scalesToFit = true; configuration.preservesAspectRatio = true
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true; configuration.ignoreGlobalClipSingleWindow = true
        try await begin(filter: filter, configuration: configuration, width: width, height: height,
                        fps: frameRate.captureRate(for: MacWindow.nativeFrameRate), cursorSource: .window(identity))
    }

    func setPresenterCursorHighlight(_ enabled: Bool) {
        queue.sync {
            cursorHighlightEnabled = enabled
            clearCursorFrame()
            windowValidation = nil
            if !enabled { cursorCompositor = nil }
        }
    }

    private func clearCursorFrame() {
        cursorFrame = nil
        highlightedPixel = nil
    }

    private func prepareOutput(_ output: FileHandle) {
        writer = VideoPipeWriter(output: output, queue: queue) { [weak self] in
            self?.active = false; self?.pixel = nil
            self?.clearCursorFrame()
        }
    }

    private func begin(filter: SCContentFilter, configuration: SCStreamConfiguration, width: Int, height: Int, fps: Int,
                       cursorSource: PresenterCursorSource) async throws {
        configuration.width = width; configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = 3; configuration.capturesAudio = false
        encoder = try ScreenEncoder(width: width, height: height, fps: fps, queue: queue) { [weak self] bytes in
            guard let self, self.active else { return }
            self.writer?.append(bytes)
        }
        let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
        stream = capture
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            self.cursorSource = cursorSource
            active = true
            let clock = DispatchSource.makeTimerSource(queue: queue)
            clock.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
            clock.setEventHandler { [weak self] in self?.encodeLatestFrame() }
            timer = clock; clock.resume()
        }
        try await capture.startCapture()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard active, type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let frame = attachments.first, let status = frame[.status] as? Int else { clearCursorFrame(); return }
        if status == SCFrameStatus.idle.rawValue { return }
        clearCursorFrame()
        // A minimized, hidden, or closed window reports suspended once and then sends nothing.
        // Stop repeating its last picture so monitoring and viewers see a waiting state.
        if case .window? = cursorSource, [SCFrameStatus.suspended, .blank, .stopped].map(\.rawValue).contains(status) {
            pixel = nil
            return
        }
        guard status == SCFrameStatus.complete.rawValue, let image = sampleBuffer.imageBuffer else { return }
        pixel = image
        if cursorHighlightEnabled { cursorFrame = cursorSource?.sample(frame, image: image) }
    }

    private func encodeLatestFrame() {
        guard active, let pixel else { return }
        encoderTick &+= 1
        guard let cursorFrame, let cursorSource else { encoder?.encode(pixel); return }
        switch cursorSource {
        case .display:
            // Revalidate even when the encoder repeats an idle capture.
            guard cursorSource.permitsDisplayRing(on: cursorFrame) else {
                clearCursorFrame(); encoder?.encode(pixel); return
            }
            if highlightedPixel == nil { highlightedPixel = highlight(cursorFrame, on: pixel) }
            encoder?.encode(highlightedPixel ?? pixel)
        case .window(let identity):
            // Main-actor hit testing must not block the capture queue. If it spans
            // a later encoding tick, encode normally and discard the late result.
            guard windowValidation == nil else { encoder?.encode(pixel); return }
            let tick = encoderTick
            windowValidation = (tick, cursorFrame, pixel)
            Task { @MainActor [weak self] in
                let hit = PresenterCursorSource.windowCursorHit(identity, for: cursorFrame)
                self?.queue.async { [weak self] in self?.finishWindowValidation(tick, hit: hit) }
            }
        }
    }

    private func finishWindowValidation(_ tick: UInt64, hit: CGPoint?) {
        guard let pending = windowValidation, pending.tick == tick else { return }
        windowValidation = nil
        guard active, pixel != nil, tick == encoderTick else { return }
        guard let hit, let pointer = CGEvent(source: nil)?.location,
              abs(hit.x - pointer.x) <= 4, abs(hit.y - pointer.y) <= 4,
              pending.frame.acceptsCurrentCursor(pointer, now: CMClockGetTime(CMClockGetHostTimeClock())) else {
            encoder?.encode(pending.pixel); return
        }
        encoder?.encode(highlight(pending.frame, on: pending.pixel))
    }

    private func highlight(_ frame: PresenterCursorFrame, on pixel: CVPixelBuffer) -> CVPixelBuffer {
        if cursorCompositor == nil {
            cursorCompositor = PresenterCursorHighlight(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
        }
        return cursorCompositor?.draw(frame, on: pixel) ?? pixel
    }
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            self?.active = false; self?.pixel = nil; self?.clearCursorFrame(); self?.writer?.close()
        }
    }
    public func stop() {
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        queue.sync {
            active = false; timer?.cancel(); timer = nil; pixel = nil
            clearCursorFrame(); cursorSource = nil; cursorCompositor = nil
            windowValidation = nil
            writer?.close(); writer = nil; encoder?.invalidate(); encoder = nil
        }
    }
    deinit { stop() }
}
