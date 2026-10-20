import Foundation

public enum SetbeamError: LocalizedError, Equatable {
    case invalidSource(String)
    case unavailable(String)
    case runtime(String)
    public var errorDescription: String? {
        switch self {
        case .invalidSource(let message), .unavailable(let message), .runtime(let message): return message
        }
    }
}

public enum VideoSource: Equatable, Sendable {
    case sample
    case network(String)
    case capture(video: Int, audio: Int?)

    public var label: String {
        switch self {
        case .sample: return "Sample feed"
        case .network(let address): return Self.safeAddress(address)
        case .capture: return "USB / capture device"
        }
    }

    public func validated() throws -> VideoSource {
        switch self {
        case .sample: return self
        case .network(let address):
            guard !address.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let components = URLComponents(string: address),
                  ["rtsp", "rtsps"].contains(components.scheme?.lowercased() ?? ""),
                  let host = components.host, !host.isEmpty,
                  components.fragment == nil,
                  components.port.map({ (1...65535).contains($0) }) ?? true else {
                throw SetbeamError.invalidSource("Enter a complete RTSP stream address, including its stream path.")
            }
            return self
        case .capture(let video, let audio):
            guard video >= 0, audio.map({ $0 >= 0 }) ?? true else {
                throw SetbeamError.invalidSource("Choose a valid capture device index.")
            }
            return self
        }
    }

    public static func safeAddress(_ address: String) -> String {
        guard var components = URLComponents(string: address) else { return "Network stream" }
        components.user = nil; components.password = nil; components.query = nil; components.fragment = nil
        return components.string ?? "Network stream"
    }
}

public enum AudienceState: String, Codable, Sendable { case stopped, live, holding, reconnecting }

public struct SessionState: Equatable, Sendable {
    public private(set) var monitoring = false
    public private(set) var sharing = false
    public private(set) var holding = false
    public private(set) var sourceAvailable = false
    public init() {}
    public var audience: AudienceState {
        if !sharing { return .stopped }
        if holding { return .holding }
        return sourceAvailable ? .live : .reconnecting
    }
    public mutating func beginMonitoring() { monitoring = true; sourceAvailable = false }
    public mutating func updateSource(available: Bool) { sourceAvailable = monitoring && available }
    public mutating func startSharing() throws {
        guard monitoring else { throw SetbeamError.unavailable("Connect a source before sharing.") }
        sharing = true; holding = false
    }
    public mutating func setHold(_ value: Bool) throws {
        guard sharing else { throw SetbeamError.unavailable("Start sharing before holding the audience.") }
        holding = value
    }
    public mutating func stopSharing() { sharing = false; holding = false }
    public mutating func end() { self = SessionState() }
}

public struct PlaybackDescriptor: Equatable, Sendable {
    public let origin: String
    public let path: String
    public let user: String
    public let password: String
    public init(origin: String, path: String, user: String, password: String) {
        self.origin = origin; self.path = path; self.user = user; self.password = password
    }
    public var whepURL: String { "\(origin)/\(path)/whep" }
}

public enum Redaction {
    public static func text(_ value: String) -> String {
        var result = value
        let replacements = [
            (#"(rtsps?|https?)://[^\s/@]+:[^\s/@]+@"#, "$1://<credentials>@"),
            (#"(rtsps?|https?)://([^\s?]+)\?[^\s]+"#, "$1://$2?<redacted>"),
            (#"(?i)(authorization:\s*)([^\r\n]+)"#, "$1<redacted>")
        ]
        for (pattern, replacement) in replacements {
            if let expression = try? NSRegularExpression(pattern: pattern) {
                result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
            }
        }
        return result
    }
}
