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

    func matches(_ listener: ViewerGateway.Binding, currentToken: String?) -> Bool {
        token == currentToken && address == listener.address && port == listener.port && listener.port != 0
    }

    func url(currentToken: String?, listener: ViewerGateway.Binding?) -> URL? {
        guard let listener, matches(listener, currentToken: currentToken) else { return nil }
        return URL(string: "http://\(address):\(listener.port)/s/\(token)/")
    }

    func invitation(currentToken: String?, listener: ViewerGateway.Binding?, localLabel: String?) -> ViewingInvitation? {
        guard !address.hasPrefix("127."), let listener, let ipURL = url(currentToken: currentToken, listener: listener) else { return nil }
        var localURL: URL?
        if let localLabel, var parts = URLComponents(url: ipURL, resolvingAgainstBaseURL: false) {
            parts.host = LocalAddressName.host(localLabel)
            localURL = parts.url
        }
        return ViewingInvitation(binding: listener.id, ipURL: ipURL, localURL: localURL)
    }
}
