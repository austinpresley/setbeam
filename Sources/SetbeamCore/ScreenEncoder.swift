import CoreMedia
import Foundation
import VideoToolbox

/// Keeps every picture within what VideoPipeWriter and MediaMTX accept, 8 MiB each. An oversized picture
/// is withheld with the pictures that depend on it, and the encoder restarts with a higher minimum QP so
/// its next keyframe fits. VideoToolbox's data-rate limits do not bound a single keyframe. The floor steps
/// back down only when a keyframe is small enough that the lower floor still leaves room.
struct KeyframeBudget: Equatable {
    static let limit = 6 * 1024 * 1024
    static let firstFloor = 20, step = 6, highestFloor = 51
    enum Action: Equatable { case send, withhold, restart(minimumQP: Int?, sending: Bool) }
    private(set) var minimumQP: Int?
    private(set) var awaitingKeyframe = false

    mutating func observe(bytes: Int, keyframe: Bool) -> Action {
        if bytes > Self.limit {
            awaitingKeyframe = true
            minimumQP = min(Self.highestFloor, minimumQP.map { $0 + Self.step } ?? Self.firstFloor)
            return .restart(minimumQP: minimumQP, sending: false)
        }
        if awaitingKeyframe {
            guard keyframe else { return .withhold }
            awaitingKeyframe = false
        }
        // One step changes a detailed keyframe by roughly a quarter, so half the limit leaves room.
        if keyframe, let floor = minimumQP, bytes * 2 <= Self.limit {
            minimumQP = floor - Self.step >= Self.firstFloor ? floor - Self.step : nil
            return .restart(minimumQP: minimumQP, sending: true)
        }
        return .send
    }
}

/// The monitoring-quality VideoToolbox encode of screen pictures into the Annex B access units the
/// screen pipe carries. Every keyframe repeats its parameter sets so a reader can join at any keyframe.
/// `encode` and `invalidate` run on the supplied queue; access units are delivered on that queue.
final class ScreenEncoder: @unchecked Sendable {
    private let width: Int, height: Int, fps: Int
    private let queue: DispatchQueue
    private let deliver: (Data) -> Void
    private var session: VTCompressionSession?
    private var generation = 1
    private var budget = KeyframeBudget()
    private var frame: Int64 = 0

    init(width: Int, height: Int, fps: Int, queue: DispatchQueue, deliver: @escaping (Data) -> Void) throws {
        self.width = width; self.height = height; self.fps = fps; self.queue = queue; self.deliver = deliver
        session = try makeSession(minimumQP: nil)
    }

    func encode(_ pixel: CVPixelBuffer) {
        guard let session else { return }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixel, presentationTimeStamp: CMTime(value: frame, timescale: Int32(fps)),
            duration: CMTime(value: 1, timescale: Int32(fps)), frameProperties: nil,
            sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: generation), infoFlagsOut: nil)
        frame += 1
    }
    /// Waits for pictures already submitted. Tests and shutdown use it; capture does not.
    func flush() { if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) } }
    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }
    deinit { invalidate() }

    private func makeSession(minimumQP: Int?) throws -> VTCompressionSession {
        var created: VTCompressionSession?
        let result = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { context, source, status, _, sample in
                guard status == noErr, let context, let sample else { return }
                Unmanaged<ScreenEncoder>.fromOpaque(context).takeUnretainedValue().encoded(sample, generation: Int(bitPattern: source))
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &created)
        guard result == noErr, let created else { throw SetbeamError.runtime("Could not prepare screen encoding (\(result)).") }
        var properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue as CFTypeRef),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse as CFTypeRef),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel as CFTypeRef),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: max(40_000_000, width * height * fps / 3))),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps))
        ]
        if let minimumQP { properties.append((kVTCompressionPropertyKey_MinAllowedFrameQP, NSNumber(value: minimumQP))) }
        for (key, value) in properties {
            let status = VTSessionSetProperty(created, key: key, value: value)
            guard status == noErr else { VTCompressionSessionInvalidate(created); throw SetbeamError.runtime("Could not configure screen encoding (\(status)).") }
        }
        VTCompressionSessionPrepareToEncodeFrames(created)
        return created
    }

    private func encoded(_ sample: CMSampleBuffer, generation: Int) {
        guard let unit = Self.annexB(sample) else { return }
        queue.async { [weak self] in
            guard let self, self.session != nil, generation == self.generation else { return }
            switch self.budget.observe(bytes: unit.bytes.count, keyframe: unit.keyframe) {
            case .send: self.deliver(unit.bytes)
            case .withhold: break
            case .restart(let minimumQP, let sending):
                if sending { self.deliver(unit.bytes) }
                self.restart(minimumQP: minimumQP, after: unit.bytes.count)
            }
        }
    }
    /// A new session begins with a keyframe. Pictures still arriving from the old one are ignored.
    /// If VideoToolbox cannot restart, the stalled source enters the runtime's normal recovery.
    private func restart(minimumQP: Int?, after bytes: Int) {
        if let session { VTCompressionSessionInvalidate(session) }
        generation += 1
        session = try? makeSession(minimumQP: minimumQP)
        SessionLog.shared.record("screen.encoder", ["minimumQP": minimumQP ?? 0, "pictureBytes": bytes, "restarted": session != nil])
    }

    static func annexB(_ sample: CMSampleBuffer) -> (bytes: Data, keyframe: Bool)? {
        guard let format = sample.formatDescription, let block = sample.dataBuffer else { return nil }
        var bytes = Data()
        let start: [UInt8] = [0, 0, 0, 1]
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        // Repeat parameter sets so every keyframe is independently joinable.
        if keyframe {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?; var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    bytes.append(contentsOf: start); bytes.append(pointer, count: size)
                }
            }
        }
        var length = 0; var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { return nil }
        let data = Data(bytes: pointer, count: length)
        var offset = 0
        while offset + 4 <= data.count {
            let count = data[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }; offset += 4
            guard count > 0, offset + count <= data.count else { return nil }
            bytes.append(contentsOf: start); bytes.append(data[offset..<offset+count]); offset += count
        }
        return (bytes, keyframe)
    }
}
