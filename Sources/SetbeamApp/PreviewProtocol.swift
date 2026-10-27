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
    var seconds: Double { Double(timestamp) / 1_000_000 }
    var durationSeconds: Double { Double(duration) / 1_000_000 }
}

enum PreviewProtocolError: Error { case invalidHeader, invalidPayload, oversizedPacket }

/// Called on the one stdout pipe. Invalid or oversized data fails closed instead
/// of scanning arbitrary pixel bytes for another header.
final class PreviewPacketParser {
    private var buffer = Data()
    private(set) var failed = false
    static let maximumPayload = 8192 * 8192 * 3 / 2

    func consume(_ data: Data, receive: (PreviewPacket) -> Void) throws {
        guard !failed else { throw PreviewProtocolError.invalidHeader }
        do {
            // FileHandle supplies small chunks. Reject unreasonable callers before allocating.
            guard data.count <= Self.maximumPayload + 64, buffer.count + data.count <= Self.maximumPayload + 128 * 1024 else { throw PreviewProtocolError.oversizedPacket }
            buffer.append(data)
            var offset = 0
            while buffer.count - offset >= 64 {
                let header = buffer.dropFirst(offset).prefix(64)
                func u32(_ index: Int) -> UInt32 {
                    (0..<4).reduce(0) { $0 | UInt32(header[header.startIndex + index + $1]) << ($1 * 8) }
                }
                func i64(_ index: Int) -> Int64 {
                    Int64(bitPattern: (0..<8).reduce(UInt64(0)) { $0 | UInt64(header[header.startIndex + index + $1]) << ($1 * 8) })
                }
                guard Array(header.prefix(6)) == [83, 66, 80, 70, 1, 0], header[header.startIndex + 7] == 0,
                      let kind = PreviewPacket.Kind(rawValue: UInt16(header[header.startIndex + 6])) else { throw PreviewProtocolError.invalidHeader }
                let size = Int(u32(8)), width = Int(u32(32)), height = Int(u32(36))
                guard size <= Self.maximumPayload else { throw PreviewProtocolError.oversizedPacket }
                switch kind {
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
                guard buffer.count - offset >= size + 64 else { break }
                let packet = PreviewPacket(kind: kind, flags: u32(12), timestamp: i64(16), duration: i64(24),
                    width: width, height: height, channels: Int(u32(40)), sampleRate: Int(u32(44)),
                    aspectNumerator: Int(u32(48)), aspectDenominator: Int(u32(52)), matrix: u32(60),
                    payload: Data(buffer[(offset + 64)..<(offset + 64 + size)]))
                receive(packet); offset += 64 + size
            }
            if offset > 0 { buffer.removeSubrange(..<offset) }
        } catch { failed = true; buffer.removeAll(); throw error }
    }
}

/// Small, bounded queues favor current monitoring over replaying old pictures.
/// All callers hold the playback inbox lock; this type also makes the policy testable.
struct PreviewInbox {
    private(set) var video: [PreviewPacket] = []
    private(set) var audio: [PreviewPacket] = []
    private(set) var droppedVideo = 0
    private(set) var droppedAudio = 0
    private(set) var videoBytes = 0
    private(set) var hasAudio: Bool?
    private(set) var latestVideoTimestamp: Double?
    private(set) var decodedFrames = 0
    private(set) var sourceFrameDuration = 0.0
    private(set) var discontinuity = false
    static let maximumVideoFrames = 6
    static let maximumVideoBytes = 32 * 1024 * 1024
    static let maximumAudioSeconds = 0.4

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
                videoBytes -= video.removeFirst().payload.count; droppedVideo += 1
            }
        case .audio:
            audio.append(packet)
            while audio.count > 64 || audio.count > 1 && audio.last!.seconds + audio.last!.durationSeconds - audio.first!.seconds > Self.maximumAudioSeconds {
                audio.removeFirst(); droppedAudio += 1
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
    mutating func takeAudio(through seconds: Double, staleBefore: Double) -> [PreviewPacket] {
        var result: [PreviewPacket] = []
        while let first = audio.first, first.seconds <= seconds {
            audio.removeFirst()
            if first.seconds + first.durationSeconds < staleBefore { droppedAudio += 1 }
            else { result.append(first) }
        }
        return result
    }
    mutating func acknowledgeDiscontinuity() { discontinuity = false }
    mutating func clearMedia() {
        droppedVideo += video.count; droppedAudio += audio.count
        video.removeAll(); audio.removeAll(); videoBytes = 0
    }
}

enum PreviewPlaybackTiming {
    /// Playout delay must fit inside the queue at the incoming dimensions/cadence.
    /// Otherwise a full-resolution high-rate source could evict every frame before it is due.
    static func playoutDelay(for packet: PreviewPacket) -> Double {
        let memoryDepth = max(1, PreviewInbox.maximumVideoBytes / max(1, packet.payload.count))
        let depth = min(PreviewInbox.maximumVideoFrames, memoryDepth)
        return min(0.04, max(0, packet.durationSeconds) * Double(depth - 1) / 2)
    }
    static func arrivedTooLate(_ packet: PreviewPacket, clock: Double) -> Bool {
        clock - packet.seconds > max(0.06, packet.durationSeconds * 2)
    }
}
