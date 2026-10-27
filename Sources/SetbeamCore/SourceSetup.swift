import Foundation

public enum InputKind: String, Codable, Sendable { case sample, macScreen, capture, network, incoming, accsoon }

/// A remembered connection, independent of the session's audience and credentials.
public struct SourceSetup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: InputKind
    public var name: String
    public var videoID: String?
    public var audioID: String?
    public var deviceName: String?
    public var networkAddress: String
    public var sourceWiFi: String
    public var confirmedAt: Date?
    public var inputPort: UInt16 = 19350
    public var wirelessUID: UInt32?

    public init(id: UUID = UUID(), kind: InputKind, name: String, videoID: String? = nil,
                audioID: String? = nil, deviceName: String? = nil, networkAddress: String = "", sourceWiFi: String = "") {
        self.id = id; self.kind = kind; self.name = name; self.videoID = videoID; self.audioID = audioID
        self.deviceName = deviceName; self.networkAddress = VideoSource.safeAddress(networkAddress); self.sourceWiFi = sourceWiFi
    }
    public var credentialAccount: String { "source-\(id.uuidString)" }
    public func source(address: String? = nil) throws -> VideoSource {
        switch kind {
        case .macScreen:
            return try VideoSource.macScreen(displayUUID: videoID ?? "").validated()
        case .sample: return .sample
        case .capture:
            guard let videoID, !videoID.isEmpty else { throw SetbeamError.unavailable("Choose the capture device you want to use.") }
            return .captureDevice(videoID: videoID, audioID: audioID)
        case .network:
            guard let address, !address.isEmpty else { throw SetbeamError.unavailable("Reconnect this source to restore its saved address.") }
            return try VideoSource.network(address).validated()
        case .incoming:
            guard let address, !address.isEmpty else { throw SetbeamError.unavailable("Set up the incoming stream before connecting.") }
            return try VideoSource.incoming(port: inputPort, key: address).validated()
        case .accsoon:
            guard let wirelessUID else { throw SetbeamError.unavailable("Choose a discovered Accsoon transmitter.") }
            return try VideoSource.accsoon(uid: wirelessUID).validated()
        }
    }
}

/// A process starting is insufficient. Both reception and the native picture must stay fresh.
public struct SetupReadiness: Sendable {
    private var healthySince: Date?
    public init() {}
    public mutating func observe(sourceFresh: Bool, previewFresh: Bool, now: Date = Date()) -> Bool {
        guard sourceFresh && previewFresh else { healthySince = nil; return false }
        if healthySince == nil { healthySince = now }
        return now.timeIntervalSince(healthySince!) >= 2
    }
}

public final class ProvenSetupStore {
    private let defaults: UserDefaults
    private let key = "provenSetup.v1"
    public init(defaults: UserDefaults) { self.defaults = defaults }
    public var setup: SourceSetup? {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(SourceSetup.self, from: data), value.confirmedAt != nil else { return nil }
        return value
    }
    public func confirm(_ setup: SourceSetup, at date: Date = Date()) throws {
        var value = setup; value.confirmedAt = date
        value.networkAddress = VideoSource.safeAddress(value.networkAddress)
        defaults.set(try JSONEncoder().encode(value), forKey: key)
    }
    public func forget() { defaults.removeObject(forKey: key) }
}

public struct CaptureHardware: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let index: Int
    public let audio: Bool
    public let builtIn: Bool
    public init(id: String, name: String, index: Int, audio: Bool = false, builtIn: Bool = false) {
        self.id = id; self.name = name; self.index = index; self.audio = audio; self.builtIn = builtIn
    }
    public static func resolve(_ id: String, audio: Bool, in devices: [CaptureHardware]) throws -> Int {
        guard let device = devices.first(where: { $0.id == id && $0.audio == audio }) else {
            throw SetbeamError.unavailable(audio ? "Reconnect the selected sound input. Your saved video input has not changed." : "Reconnect your saved capture device. Setbeam will wait for that same device.")
        }
        return device.index
    }
}
