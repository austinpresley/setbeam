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
                expectsAudio: Bool?, outgoingAudio: Bool, soundConfirmed: Bool) {
        self.picture = picture; self.viewingAddress = viewingAddress; self.otherDevicePlaying = otherDevicePlaying
        audio = expectsAudio == false || expectsAudio == true && outgoingAudio && soundConfirmed
    }
}


/// A sound check applies only to the live output and the other-device sessions being tested.
public struct SetupCheckOutput: Equatable, Sendable {
    private let link: Int
    private let revision: Int
    private let route: String
    private let viewers: Set<Int>

    public var viewerCount: Int { viewers.count }

    public init(link: Int, revision: Int, route: String, reports: [ViewerActivity]) {
        self.link = link
        self.revision = revision
        self.route = route
        viewers = Set(reports.filter {
            $0.admission == .admitted && !$0.onThisMac && $0.playing && $0.revision == revision
        }.map(\.number))
    }
}
