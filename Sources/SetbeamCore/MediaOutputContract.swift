import Foundation

/// The one received relay is usable by both native monitoring and browser sharing.
/// Untrusted inputs are decoded once and normalized; only bundled, verified media is copied.
public enum MediaOutputContract {
    public static let videoArguments = [
        "-vf", "scale=ceil(iw/2)*2:ceil(ih/2)*2,format=yuv420p",
        "-c:v", "h264_videotoolbox", "-realtime", "1", "-b:v", "12000k",
        "-bf", "0", "-g", "60", "-force_key_frames", "expr:gte(t,n_forced*1)",
        "-profile:v", "baseline", "-fps_mode", "passthrough"
    ]
    public static let audioArguments = ["-c:a", "libopus", "-b:a", "96k", "-ar", "48000", "-ac", "2"]

    /// MediaMTX's observed codec metadata, not process liveness, establishes this contract.
    public static func accepts(path: [String: Any]?) -> Bool {
        guard let tracks = path?["tracks2"] as? [[String: Any]], !tracks.isEmpty else { return false }
        var videoCount = 0
        for track in tracks {
            switch track["codec"] as? String {
            case "H264":
                guard let properties = track["codecProps"] as? [String: Any],
                      let profile = properties["profile"] as? String,
                      profile.lowercased().contains("baseline"),
                      (properties["width"] as? Int ?? 0) > 0,
                      (properties["height"] as? Int ?? 0) > 0 else { return false }
                videoCount += 1
            case "Opus": break
            default: return false
            }
        }
        return videoCount == 1
    }
}
