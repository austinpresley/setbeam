import Foundation

/// Bitrate ceiling for the browser audience. Every viewer receives its own WebRTC copy.
public enum AudienceQuality: String, CaseIterable, Sendable {
    case best, balanced, light

    public var kilobits: Int {
        switch self { case .best: return 12_000; case .balanced: return 6_000; case .light: return 3_000 }
    }
    public var title: String {
        switch self {
        case .best: return "Best (12 Mbps per viewer)"
        case .balanced: return "Balanced (6 Mbps per viewer)"
        case .light: return "Light (3 Mbps per viewer)"
        }
    }
}

/// Local monitoring keeps the received encoding whenever it can be relayed, so the operator
/// sees the source rather than a second generation. Only the audience output is normalized
/// for browsers. Raw capture input is encoded once, for fidelity, before the private relay.
public enum MediaOutputContract {
    public static func audienceVideoArguments(_ quality: AudienceQuality = .best) -> [String] {
        ["-vf", "scale=ceil(iw/2)*2:ceil(ih/2)*2,format=yuv420p",
         "-c:v", "h264_videotoolbox", "-realtime", "1", "-b:v", "\(quality.kilobits)k",
         "-bf", "0", "-g", "60", "-force_key_frames", "expr:gte(t,n_forced*1)",
         "-profile:v", "baseline", "-fps_mode", "passthrough"]
    }
    public static let monitoringVideoArguments = [
        "-vf", "scale=ceil(iw/2)*2:ceil(ih/2)*2,format=yuv420p",
        "-c:v", "h264_videotoolbox", "-realtime", "1", "-b:v", "40000k",
        "-bf", "0", "-g", "60", "-force_key_frames", "expr:gte(t,n_forced*1)",
        "-profile:v", "high", "-fps_mode", "passthrough"
    ]
    public static let audioArguments = ["-c:a", "libopus", "-b:a", "96k", "-ar", "48000", "-ac", "2"]
    /// Codecs the bundled decoder and the audience encoder both accept from the private relay.
    static let monitoringCodecs: Set<String> = ["H264", "H265", "M-JPEG"]

    /// MediaMTX's observed codec metadata, not process liveness, establishes this contract.
    public static func accepts(path: [String: Any]?) -> Bool {
        tracks(in: path) { codec, properties in
            guard codec == "H264", let profile = properties["profile"] as? String else { return false }
            return profile.lowercased().contains("baseline")
        }
    }

    /// The private relay carries one decodable picture with optional normalized sound.
    public static func acceptsMonitoring(path: [String: Any]?) -> Bool {
        tracks(in: path) { codec, _ in monitoringCodecs.contains(codec) }
    }

    private static func tracks(in path: [String: Any]?, video accepts: (String, [String: Any]) -> Bool) -> Bool {
        guard let tracks = path?["tracks2"] as? [[String: Any]], !tracks.isEmpty else { return false }
        var videoCount = 0
        for track in tracks {
            let codec = track["codec"] as? String ?? ""
            if codec == "Opus" { continue }
            guard let properties = track["codecProps"] as? [String: Any], accepts(codec, properties),
                  (properties["width"] as? Int ?? 0) > 0, (properties["height"] as? Int ?? 0) > 0 else { return false }
            videoCount += 1
        }
        return videoCount == 1
    }
}
