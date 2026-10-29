import XCTest
import os
@testable import SetbeamCore
@testable import SetbeamApp

@MainActor final class PyroHBrowserTests: XCTestCase {
    private let network = PyroHNetwork(interface: "lo0", address: "127.0.0.1", router: "127.0.0.1")

    func testMonitoringNetworkSourceSuppressesProbesAndOtherSourceKindsAllowThem() async throws {
        var state = SessionState(); state.beginMonitoring()
        let suite = "Setbeam-pyro-ui-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SessionModel(initialState: state, preferences: defaults)
        model.setup = SourceSetup(kind: .network, name: "Network source")
        XCTAssertFalse(model.canDiscoverPyroH)
        model.setup?.networkProfile = .pyroH
        XCTAssertFalse(model.canDiscoverPyroH)
        let calls = OSAllocatedUnfairLock(initialState: 0), network = network
        let browser = SourceBrowser(pyroHNetworks: { [network] }, pyroHProbe: { _, _ in calls.withLock { $0 += 1 }; return [] })
        browser.start { model.canDiscoverPyroH }
        defer { browser.stop() }
        try await waitFor { browser.pyroHSearchState == .monitoring }
        XCTAssertEqual(calls.withLock { $0 }, 0)
        model.setup = SourceSetup(kind: .sample, name: "Sample feed")
        XCTAssertTrue(model.canDiscoverPyroH)
        model.setup = SourceSetup(kind: .capture, name: "Capture input", videoID: "test")
        XCTAssertTrue(model.canDiscoverPyroH)
        await model.shutdown()
    }

    func testClosingChooserCancelsAndRejectsLateDiscoveryResults() async throws {
        let gate = ProbeGate(), network = network
        let browser = SourceBrowser(pyroHNetworks: { [network] }, pyroHProbe: { _, _ in await gate.run() })
        browser.start()
        try await waitForAsync { await gate.started }
        let pending = browser.stop()
        XCTAssertTrue(browser.pyroHSources.isEmpty)
        await gate.finish([PyroHSource(network: network, port: 5554, hasAudio: true)])
        await pending?.value
        XCTAssertTrue(browser.pyroHSources.isEmpty)
    }

    func testNetworkChangeDuringProbeDiscardsTheOldRouter() async throws {
        let gate = ProbeGate(), network = network
        let routes = OSAllocatedUnfairLock(initialState: [network])
        let browser = SourceBrowser(pyroHNetworks: { routes.withLock { $0 } }, pyroHProbe: { _, _ in await gate.run() })
        browser.start()
        defer { browser.stop() }
        try await waitForAsync { await gate.started }
        routes.withLock { $0 = [] }
        await gate.finish([PyroHSource(network: network, port: 5554, hasAudio: false)])
        try await waitFor { browser.pyroHSearchState == .noWiFi }
        XCTAssertTrue(browser.pyroHSources.isEmpty)
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw SetbeamError.runtime("Pyro H browser did not reach its expected state.")
    }
    private func waitForAsync(_ predicate: () async -> Bool) async throws {
        for _ in 0..<100 { if await predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw SetbeamError.runtime("Pyro H probe did not start.")
    }
}

private actor ProbeGate {
    private var completion: CheckedContinuation<[PyroHSource], Never>?
    var started: Bool { completion != nil }
    func run() async -> [PyroHSource] { await withCheckedContinuation { completion = $0 } }
    func finish(_ sources: [PyroHSource]) { completion?.resume(returning: sources); completion = nil }
}
