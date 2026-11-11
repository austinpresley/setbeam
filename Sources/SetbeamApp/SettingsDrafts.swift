import Foundation
import SetbeamCore

struct SourceDetailsDraft: Equatable {
    var name: String
    var audioID: String
    var remember: Bool
    var screenRate: VideoFrameRate
    var rejoin: Bool
    var password: String
    var openNetwork: Bool

    func needsPassword(for setup: SourceSetup) -> Bool {
        setup.kind == .accsoon && !setup.sourceWiFi.isEmpty && rejoin && !openNetwork && password.isEmpty
    }
    func reconnects(_ setup: SourceSetup) -> Bool {
        setup.kind == .capture && audioID != (setup.audioID ?? "")
    }
    func plan(for setup: SourceSetup, current: Self) -> SourceDetailsPlan? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !needsPassword(for: setup) else { return nil }
        var source = setup
        source.name = title
        if setup.kind == .capture { source.audioID = audioID.isEmpty ? nil : audioID }
        let rejoinChange = setup.kind == .accsoon && !setup.sourceWiFi.isEmpty &&
            (rejoin != current.rejoin || password != current.password || openNetwork != current.openNetwork)
        return SourceDetailsPlan(source: source, remember: remember, reconnect: reconnects(setup),
            nameOrRememberChanged: name != current.name || remember != current.remember,
            captureRate: setup.kind.isMacCapture ? screenRate : nil,
            rejoin: rejoinChange ? .init(enabled: rejoin, password: password, openNetwork: openNetwork) : nil)
    }
}

struct SourceDetailsPlan {
    struct Rejoin: Equatable { let enabled: Bool; let password: String; let openNetwork: Bool }
    let source: SourceSetup
    let remember: Bool
    let reconnect: Bool
    let nameOrRememberChanged: Bool
    let captureRate: VideoFrameRate?
    let rejoin: Rejoin?
}

struct SharingOptionsDraft: Equatable {
    var address: String
    var network: String
    var quality: AudienceQuality
    var frameRate: VideoFrameRate
}

struct ViewingWiFiDraft: Equatable {
    var ssid: String
    var password: String
    var openNetwork = false
    var canSave: Bool { ssid.utf8.count <= 32 && (ssid.isEmpty || openNetwork || !password.isEmpty) }
}

