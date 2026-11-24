import Foundation

/// The separate decoder emits little-endian SBPF v1 records. Every packet retains
/// its source PTS in microseconds. Video is packed NV12, audio is 48 kHz stereo Float32.
struct PreviewPacket: Equatable {
    enum Kind: UInt16 { case video = 1, audio = 2, streams = 3 }
    let kind: Kind
    let flags: UInt32
    let timestamp: Int64
    let duration: Int64
    let width: Int
    let height: Int
    let channels: Int
    let sampleRate: Int
    let aspectNumerator: Int
    let aspectDenominator: Int
    let matrix: UInt32
    let payload: Data
    // SBPF v1 leaves these video flag bytes zero in older helpers.
    var colorPrimaries: UInt32 { (flags >> 8) & 0xff }
    var transferFunction: UInt32 { (flags >> 16) & 0xff }
    var seconds: Double { Double(timestamp) / 1_000_000 }
    var durationSeconds: Double { Double(duration) / 1_000_000 }
}

enum PreviewProtocolError: Error { case invalidHeader, invalidPayload, oversizedPacket }

/// Called on the one stdout pipe. Invalid or oversized data fails closed instead
/// of scanning arbitrary pixel bytes for another header.
final class PreviewPacketParser {
    private var header = Data()
    private var payload = Data()
    private var payloadSize: Int?
    private(set) var failed = false
    static let maximumPayload = 8192 * 8192 * 3 / 2

    func consume(_ data: Data, beganRecord: () -> Void = {}, receive: (PreviewPacket) -> Void) throws {
        guard !failed else { throw PreviewProtocolError.invalidHeader }
        do {
            guard data.count <= Self.maximumPayload + 64 else { throw PreviewProtocolError.oversizedPacket }
            var offset = data.startIndex
            while offset < data.endIndex {
                if payloadSize == nil {
                    if header.isEmpty { beganRecord() }
                    let count = min(64 - header.count, data.endIndex - offset)
                    header.append(data[offset..<(offset + count)])
                    offset += count
                    guard header.count == 64 else { return }
                    payloadSize = try validateHeader()
                }
                guard let size = payloadSize else { return }
                let count = min(size - payload.count, data.endIndex - offset)
                payload.append(data[offset..<(offset + count)])
                offset += count
                guard payload.count == size else { return }

                // Move the assembled payload into the packet. The next record starts with
                // empty storage even if a consumer still owns the previous packet.
                let packet = PreviewPacket(kind: try kind(), flags: u32(12), timestamp: i64(16), duration: i64(24),
                    width: Int(u32(32)), height: Int(u32(36)), channels: Int(u32(40)), sampleRate: Int(u32(44)),
                    aspectNumerator: Int(u32(48)), aspectDenominator: Int(u32(52)), matrix: u32(60), payload: payload)
                payload = Data()
                header.removeAll(keepingCapacity: true)
                payloadSize = nil
                receive(packet)
            }
        } catch {
            failed = true
            header = Data()
            payload = Data()
            payloadSize = nil
            throw error
        }
    }

    private func kind() throws -> PreviewPacket.Kind {
        guard let kind = PreviewPacket.Kind(rawValue: UInt16(header[6])) else { throw PreviewProtocolError.invalidHeader }
        return kind
    }

    private func validateHeader() throws -> Int {
        guard header.prefix(6).elementsEqual([83, 66, 80, 70, 1, 0]), header[7] == 0 else { throw PreviewProtocolError.invalidHeader }
        let size = Int(u32(8)), width = Int(u32(32)), height = Int(u32(36))
        guard size <= Self.maximumPayload else { throw PreviewProtocolError.oversizedPacket }
        switch try kind() {
        case .video:
            guard (2...8192).contains(width), (2...8192).contains(height), width % 2 == 0, height % 2 == 0,
                  size == width * height * 3 / 2, u32(56) == 1,
                  (1...65536).contains(u32(48)), (1...65536).contains(u32(52)) else { throw PreviewProtocolError.invalidPayload }
        case .audio:
            guard u32(40) == 2, u32(44) == 48_000, u32(56) == 2,
                  size > 0, size <= 48_000 * 8 / 2, size % 8 == 0 else { throw PreviewProtocolError.invalidPayload }
        case .streams:
            guard size == 0 else { throw PreviewProtocolError.invalidPayload }
        }
        return size
    }

    private func u32(_ index: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(header[index + $1]) << ($1 * 8) }
    }

    private func i64(_ index: Int) -> Int64 {
        Int64(bitPattern: (0..<8).reduce(UInt64(0)) { $0 | UInt64(header[index + $1]) << ($1 * 8) })
    }
}

/// Small, bounded queues favor current monitoring over replaying old pictures.
/// All callers hold the playback inbox lock; this type also makes the policy testable.
struct PreviewInbox {
    private(set) var video: [PreviewPacket] = []
    private(set) var audio: [PreviewPacket] = []
    private(set) var audioEpoch: UInt64 = 0
    private var audioHead: UInt64 = 0
    private var audioBytes = 0
    private(set) var droppedVideo = 0
    private(set) var droppedAudio = 0
    private(set) var videoBytes = 0
    private(set) var hasAudio: Bool?
    private(set) var latestVideoTimestamp: Double?
    private(set) var decodedFrames = 0
    private(set) var sourceFrameDuration = 0.0
    private(set) var discontinuity = false
    /// Capacity evicted a picture before the clock reached it, so the clock is behind arrivals.
    private(set) var overrun = false
    static let maximumVideoFrames = 6
    static let maximumVideoBytes = 32 * 1024 * 1024
    static let maximumAudioPackets = 64
    static let maximumAudioSeconds = 0.4
    static let maximumAudioBytes = 48_000 * 8 / 2

    mutating func append(_ packet: PreviewPacket) {
        switch packet.kind {
        case .streams: hasAudio = packet.flags & 1 != 0
        case .video:
            if let previous = latestVideoTimestamp, packet.seconds < previous - 0.5 || packet.seconds > previous + 2 {
                discontinuity = true; clearMedia()
            }
            latestVideoTimestamp = packet.seconds; decodedFrames += 1
            sourceFrameDuration = packet.durationSeconds
            video.append(packet); videoBytes += packet.payload.count
            while video.count > Self.maximumVideoFrames || video.count > 1 && videoBytes > Self.maximumVideoBytes {
                videoBytes -= video.removeFirst().payload.count; droppedVideo += 1; overrun = true
            }
        case .audio:
            audio.append(packet)
            audioBytes += packet.payload.count
            while audio.count > Self.maximumAudioPackets || audioBytes > Self.maximumAudioBytes ||
                audio.count > 1 && packet.seconds + packet.durationSeconds - audio.first!.seconds > Self.maximumAudioSeconds {
                removeAudioHead(dropped: true)
            }
        }
    }
    mutating func takeVideo(at seconds: Double) -> PreviewPacket? {
        var current: PreviewPacket?
        while let first = video.first, first.seconds <= seconds + 0.002 {
            if current != nil { droppedVideo += 1 }
            current = video.removeFirst(); videoBytes -= first.payload.count
        }
        return current
    }
    struct AudioOffer {
        fileprivate let head: UInt64
        let packet: PreviewPacket
    }

    mutating func offerAudio(through seconds: Double, staleBefore: Double) -> AudioOffer? {
        while let first = audio.first, first.seconds + first.durationSeconds < staleBefore {
            removeAudioHead(dropped: true)
        }
        guard let first = audio.first, first.seconds <= seconds else { return nil }
        return AudioOffer(head: audioHead, packet: first)
    }

    /// The producer can evict the head while the renderer builds a sample.
    mutating func finishAudio(_ offer: AudioOffer, staleBefore: Double, dropped: Bool = false) -> Bool {
        guard offer.head == audioHead, !audio.isEmpty else { return false }
        let stale = offer.packet.seconds + offer.packet.durationSeconds < staleBefore
        removeAudioHead(dropped: dropped || stale)
        return !dropped && !stale
    }

    private mutating func removeAudioHead(dropped: Bool) {
        audioBytes -= audio.removeFirst().payload.count
        audioHead &+= 1
        if dropped { droppedAudio += 1 }
    }

    mutating func invalidateAudio() {
        audioEpoch &+= 1
        audioHead &+= UInt64(audio.count)
        droppedAudio += audio.count
        audio.removeAll()
        audioBytes = 0
    }

    mutating func acknowledgeDiscontinuity() { discontinuity = false; overrun = false }
    mutating func clearMedia() {
        invalidateAudio()
        droppedVideo += video.count
        video.removeAll()
        videoBytes = 0
    }
}

enum PreviewPlaybackTiming {
    /// At 1 fps, allow several frame intervals of scheduling jitter before showing recovery.
    /// Keep the bound short enough that a frozen picture still becomes unavailable.
    static func freshnessInterval(sourceFPS: Double) -> Double {
        guard sourceFPS.isFinite, sourceFPS > 0 else { return 2 }
        return max(2, min(6, 3 / sourceFPS))
    }
    /// Playout delay must fit inside the queue at the incoming dimensions/cadence.
    /// Otherwise a full-resolution high-rate source could evict every frame before it is due.
    static func playoutDelay(for packet: PreviewPacket) -> Double {
        let memoryDepth = max(1, PreviewInbox.maximumVideoBytes / max(1, packet.payload.count))
        let depth = min(PreviewInbox.maximumVideoFrames, memoryDepth)
        return min(0.04, max(0, packet.durationSeconds) * Double(depth - 1) / 2)
    }
    /// A large jump or a suspended consumer restarts one shared clock for both media. So does a
    /// clock left behind by a late arrival: only two 4K pictures fit the queue, so waiting for them
    /// would evict every picture before it is due.
    static func needsAnchor(_ inbox: PreviewInbox, anchored: Bool, clock: Double) -> Bool {
        guard let first = inbox.video.first, let latest = inbox.video.last else { return false }
        return !anchored || inbox.discontinuity || inbox.overrun || first.seconds - clock > 0.25 || arrivedTooLate(latest, clock: clock)
    }
    static func arrivedTooLate(_ packet: PreviewPacket, clock: Double) -> Bool {
        clock - packet.seconds > max(0.06, packet.durationSeconds * 2)
    }
}
