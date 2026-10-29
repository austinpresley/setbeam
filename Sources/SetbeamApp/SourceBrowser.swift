import Foundation
import SetbeamCore

struct NetworkSourceChoice: Identifiable {
    let id: String
    let name: String
    let address: String
}

enum PyroHSearchState { case looking, found, noWiFi, unavailable, monitoring }

/// Bonjour uses advertised paths. Pyro H separately probes only the upstream launcher's scoped /live route.
@MainActor final class SourceBrowser: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    @Published var sources: [NetworkSourceChoice] = []
    @Published private(set) var pyroHSources: [PyroHSource] = []
    @Published private(set) var pyroHSearchState = PyroHSearchState.looking
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var started = false
    private var pyroHTask: Task<Void, Never>?
    private var generation = UUID()
    private let pyroHNetworks: @Sendable () -> [PyroHNetwork]
    private let pyroHPorts: [UInt16]
    private let pyroHProbe: @Sendable ([PyroHNetwork], [UInt16]) async -> [PyroHSource]

    init(pyroHNetworks: @escaping @Sendable () -> [PyroHNetwork] = { PyroHNetwork.connected() },
         pyroHPorts: [UInt16] = PyroHDiscovery.ports,
         pyroHProbe: @escaping @Sendable ([PyroHNetwork], [UInt16]) async -> [PyroHSource] = { await PyroHDiscovery.scan(networks: $0, ports: $1) }) {
        self.pyroHNetworks = pyroHNetworks; self.pyroHPorts = pyroHPorts; self.pyroHProbe = pyroHProbe
        super.init()
    }

    func start(pyroHScanAllowed: @escaping @MainActor () -> Bool = { true }) {
        guard !started else { return }; started = true
        browser.delegate = self; browser.searchForServices(ofType: "_rtsp._tcp.", inDomain: "local.")
        generation = UUID(); let current = generation
        pyroHTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.started, self.generation == current else { return }
                if !pyroHScanAllowed() {
                    self.pyroHSources = []; self.pyroHSearchState = .monitoring
                } else {
                    let networks = self.pyroHNetworks()
                    self.pyroHSearchState = networks.isEmpty ? .noWiFi : .looking
                    let found = networks.isEmpty ? [] : await self.pyroHProbe(networks, self.pyroHPorts)
                    guard !Task.isCancelled, self.started, self.generation == current else { return }
                    if !pyroHScanAllowed() { self.pyroHSources = []; self.pyroHSearchState = .monitoring }
                    else {
                        let connected = Set(self.pyroHNetworks())
                        self.pyroHSources = found.filter { connected.contains($0.network) }
                        self.pyroHSearchState = connected.isEmpty ? .noWiFi : self.pyroHSources.isEmpty ? .unavailable : .found
                    }
                }
                do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { return }
            }
        }
    }
    @discardableResult func stop() -> Task<Void, Never>? {
        let pending = pyroHTask
        started = false; generation = UUID(); pyroHTask?.cancel(); pyroHTask = nil; pyroHSources = []
        browser.stop(); services.forEach { $0.stop() }; services.removeAll(); sources.removeAll()
        return pending
    }
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
