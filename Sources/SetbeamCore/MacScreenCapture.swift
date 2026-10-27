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
    private var encoder: VTCompressionSession?
    private var output: FileHandle?
    private var pending = Data()
    private var pixel: CVPixelBuffer?
    private var timer: DispatchSourceTimer?
    private var frame: Int64 = 0
    private var active = false

    public static func requestPermission() -> Bool { CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() }

    public func start(displayUUID: String, output: FileHandle) async throws {
        self.output = output
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
        let fps = selected.frameRate
        let configuration = SCStreamConfiguration()
        configuration.width = width; configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = 3; configuration.showsCursor = true; configuration.capturesAudio = false
        var compression: VTCompressionSession?
        let result = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { context, _, status, _, sample in
                guard status == noErr, let context, let sample else { return }
                Unmanaged<MacScreenCapture>.fromOpaque(context).takeUnretainedValue().encoded(sample)
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &compression)
        guard result == noErr, let compression else { throw SetbeamError.runtime("Could not prepare screen encoding (\(result)).") }
        encoder = compression
        for (key, value) in [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue as CFTypeRef),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse as CFTypeRef),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel as CFTypeRef),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: max(40_000_000, width * height * fps / 3))),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps))
        ] {
            let status = VTSessionSetProperty(compression, key: key, value: value)
            guard status == noErr else { throw SetbeamError.runtime("Could not configure screen encoding (\(status)).") }
        }
        VTCompressionSessionPrepareToEncodeFrames(compression)
        let fd = output.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
        stream = capture
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            active = true
            let clock = DispatchSource.makeTimerSource(queue: queue)
            clock.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
            clock.setEventHandler { [weak self] in
                guard let self, self.active, let pixel = self.pixel, let encoder = self.encoder else { return }
                VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixel, presentationTimeStamp: CMTime(value: self.frame, timescale: Int32(fps)), duration: CMTime(value: 1, timescale: Int32(fps)), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
                self.frame += 1
                self.drain()
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
        queue.async { [weak self] in self?.active = false; self?.pixel = nil; try? self?.output?.close() }
    }
    private func encoded(_ sample: CMSampleBuffer) {
        guard let format = sample.formatDescription, let block = sample.dataBuffer else { return }
        var bytes = Data()
        let start: [UInt8] = [0, 0, 0, 1]
        // Repeat parameter sets so every keyframe is independently joinable.
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        if attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?; var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    bytes.append(contentsOf: start); bytes.append(pointer, count: size)
                }
            }
        }
        var length = 0; var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { return }
        let data = Data(bytes: pointer, count: length)
        var offset = 0
        while offset + 4 <= data.count {
            let count = data[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }; offset += 4
            guard count > 0, offset + count <= data.count else { return }
            bytes.append(contentsOf: start); bytes.append(data[offset..<offset+count]); offset += count
        }
        queue.async { [weak self] in
            guard let self, self.active else { return }
            guard self.pending.count + bytes.count <= 8 * 1024 * 1024 else {
                self.active = false; self.pixel = nil; try? self.output?.close(); return
            }
            self.pending.append(bytes); self.drain()
        }
    }
    private func drain() {
        guard let output, active else { return }
        while !pending.isEmpty {
            let count = pending.withUnsafeBytes { Darwin.write(output.fileDescriptor, $0.baseAddress!, $0.count) }
            if count > 0 { pending.removeFirst(count) }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && errno == EAGAIN { return }
            else { active = false; pixel = nil; try? output.close(); return }
        }
    }
    public func stop() {
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        queue.sync { active = false; timer?.cancel(); timer = nil; pixel = nil; pending.removeAll(); try? output?.close(); output = nil }
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
    }
    deinit { stop() }
}
