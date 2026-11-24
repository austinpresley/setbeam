import Foundation
import SetbeamCore

/// Both URL forms refer to the same listener and sharing token.
struct ViewingInvitation: Equatable {
    let binding: UUID
    let ipURL: URL
    let localURL: URL?

    var preferredURL: URL { localURL ?? ipURL }
}

struct ViewingGatewayBinding: Equatable {
    let id = UUID()
    let address: String
    let token: String
    private(set) var port: UInt16?

    init(address: String, token: String) {
        self.address = address
        self.token = token
    }

    mutating func confirm(id: UUID, port: UInt16, currentToken: String?) -> Bool {
        guard self.id == id, self.token == currentToken, port != 0 else { return false }
        self.port = port
        return true
    }

    func url(currentToken: String?, listenerReady: Bool) -> URL? {
        guard listenerReady, token == currentToken, let port, port != 0 else { return nil }
        return URL(string: "http://\(address):\(port)/s/\(token)/")
    }

    func invitation(currentToken: String?, listenerReady: Bool, localLabel: String?) -> ViewingInvitation? {
        guard !address.hasPrefix("127."), let ipURL = url(currentToken: currentToken, listenerReady: listenerReady) else { return nil }
        var localURL: URL?
        if let localLabel, var parts = URLComponents(url: ipURL, resolvingAgainstBaseURL: false) {
            parts.host = LocalAddressName.host(localLabel)
            localURL = parts.url
        }
        return ViewingInvitation(binding: id, ipURL: ipURL, localURL: localURL)
    }
}
