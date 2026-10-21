import Foundation
import SetbeamCore

struct NetworkSourceChoice: Identifiable {
    let id: String
    let name: String
    let address: String
}

/// Discover only advertised RTSP services with an explicit stream path. Never guess a vendor endpoint.
@MainActor final class SourceBrowser: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    @Published var sources: [NetworkSourceChoice] = []
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var started = false
    func start() {
        guard !started else { return }; started = true
        browser.delegate = self; browser.searchForServices(ofType: "_rtsp._tcp.", inDomain: "local.")
    }
    func stop() { browser.stop(); services.forEach { $0.stop() }; services.removeAll(); sources.removeAll(); started = false }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service); service.delegate = self; service.resolve(withTimeout: 4)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        sources.removeAll { $0.id == service.name + service.domain }
        services.removeAll { $0 == service }
    }
    func netServiceDidResolveAddress(_ service: NetService) {
        guard let host = service.hostName, service.port > 0, let data = service.txtRecordData(),
              let pathData = NetService.dictionary(fromTXTRecord: data)["path"],
              let path = String(data: pathData, encoding: .utf8), path.hasPrefix("/"),
              !path.contains("?"), !path.contains("#") else { return }
        var components = URLComponents(); components.scheme = "rtsp"; components.host = host
        components.port = service.port; components.path = path
        guard let address = components.string, (try? VideoSource.network(address).validated()) != nil else { return }
        let id = service.name + service.domain
        sources.removeAll { $0.id == id }; sources.append(NetworkSourceChoice(id: id, name: service.name, address: address))
    }
}
