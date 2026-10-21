import Foundation

public enum MediaTracks {
    /// Track presence is observable. It does not establish audible sound or A/V timing.
    public static func hasAudio(_ tracks: [String]) -> Bool {
        tracks.contains { track in
            let name = track.lowercased()
            return ["opus", "mpeg4audio", "aac", "mpeg1audio", "mpeg4audiolatm", "g711", "g722", "lpcm", "ac3", "speex"].contains(name)
        }
    }
}

public struct SetupCheck: Equatable, Sendable {
    public let picture: Bool
    public let viewingAddress: Bool
    public let otherDevicePlaying: Bool
    public let audio: Bool
    public var passed: Bool { picture && viewingAddress && otherDevicePlaying && audio }
    public init(picture: Bool, viewingAddress: Bool, otherDevicePlaying: Bool,
                expectsAudio: Bool, outgoingAudio: Bool, soundConfirmed: Bool) {
        self.picture = picture; self.viewingAddress = viewingAddress; self.otherDevicePlaying = otherDevicePlaying
        audio = !expectsAudio || outgoingAudio && soundConfirmed
    }
}
