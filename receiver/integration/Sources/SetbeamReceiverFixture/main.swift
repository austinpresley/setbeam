import Foundation
import Darwin
import CryptoKit
import SetbeamCore

/// A bounded-lifetime, labeled Sample session for testing a native receiver against the real
/// SetbeamCore ViewerGateway, ShortAddressListener, and MediaRuntime.
///
/// It wires them the way SessionModel does: sharing under viewer approval, the short address open on
/// port 80 for the chosen viewing address, the gateway session republished from every runtime
/// snapshot, and admitted readers applied to the media server before the gateway confirms them.
/// No authorization or decoding is simulated. Nothing is advertised by mDNS; the receiver uses its
/// configured host.
///
/// Control: write `<runtime>/commands/<seq>.json` (`{"command":"admit","name":"Stage TV"}`), then read
/// `<runtime>/acks/<seq>.json`. `<runtime>/status.json` is rewritten about every 250 ms. Commands:
/// admit, decline, remove (by `name` or `number`), hold, resume, stop, start, newshare,
/// close-short / open-short, source-outage, server-outage, gateway-outage (`seconds`), chat (`text`),
/// pointers (`on`), quit.
/// Status and logs never contain the viewing code, the ask code, a pass, or a media credential.
struct Options {
    var repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var tools: URL?
    var fixtures: URL?
    var runtime: URL?
    var viewerAddress = ""
    var webPort: UInt16 = ShortAddressListener.webPort
    var lifetime: TimeInterval = 1800
    var title = "Receiver integration (Sample)"
    var label = "setbeam-tvtest"

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options(), index = 1
        func value() throws -> String {
            index += 1
            guard index < arguments.count else { throw SetbeamError.runtime("Missing value for \(arguments[index - 1]).") }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--repo": options.repo = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--tools": options.tools = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--fixtures": options.fixtures = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--runtime": options.runtime = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--viewer-address": options.viewerAddress = try value()
            case "--web-port": options.webPort = UInt16(try value()) ?? 0
            case "--lifetime": options.lifetime = TimeInterval(try value()) ?? 0
            case "--title": options.title = try value()
            case "--label": options.label = try value()
            default: throw SetbeamError.runtime("Unknown option \(arguments[index]).")
            }
            index += 1
        }
        guard options.lifetime > 0, options.lifetime <= 4 * 3600 else { throw SetbeamError.runtime("--lifetime must be 1...14400 seconds.") }
        guard options.webPort > 0 else { throw SetbeamError.runtime("--web-port must be a TCP port.") }
        guard options.runtime != nil else { throw SetbeamError.runtime("--runtime <ignored directory> is required.") }
        return options
    }
}

func log(_ text: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime, .withFractionalSeconds])
    FileHandle.standardOutput.write(Data("[\(stamp)] \(text)\n".utf8))
}

/// A short, non-reversible label for a secret path so status can show that it changed.
func fingerprint(_ value: String?) -> String? {
    guard let value else { return nil }
    return SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
}

final class Harness {
    let options: Options
    let runtime: MediaRuntime
    let gateway: ViewerGateway
    let listener: ShortAddressListener
    let host: String
    let commands: URL, acks: URL, statusFile: URL
    var gatewayPort: UInt16 = 0
    var shortAddressEnabled = true
    var appliedReaders: Set<ViewerReader> = []
    var lastServedPath: String?
    var events: [[String: Any]] = []
    var nextCommand = 1
    var quitting = false
    var gatewayDown = false
    var lastProblem: String?

    init(options: Options) throws {
        self.options = options
        let tools = options.tools ?? options.repo.appendingPathComponent("Vendor/bin", isDirectory: true)
        let fixtures = options.fixtures ?? options.repo.appendingPathComponent("Fixtures", isDirectory: true)
        let resources = options.repo.appendingPathComponent("Sources/SetbeamApp/Resources", isDirectory: true)
        let assets = Dictionary(uniqueKeysWithValues: try FileManager.default.contentsOfDirectory(atPath: resources.path).map {
            ($0, try Data(contentsOf: resources.appendingPathComponent($0)))
        })
        runtime = MediaRuntime(paths: RuntimePaths(tools: tools, fixtures: fixtures))
        gateway = ViewerGateway(assets: assets)
        listener = ShortAddressListener(port: options.webPort, retryDelay: 1)
        host = LocalAddressName.host(options.label)
        let root = options.runtime!
        commands = root.appendingPathComponent("commands", isDirectory: true)
        acks = root.appendingPathComponent("acks", isDirectory: true)
        statusFile = root.appendingPathComponent("status.json")
        for directory in [root, commands, acks] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    func event(_ name: String, _ detail: [String: Any] = [:]) {
        var item = detail; item["event"] = name; item["at"] = Date().timeIntervalSince1970
        events.append(item); if events.count > 200 { events.removeFirst(events.count - 200) }
        log("EVENT \(name) \(detail.isEmpty ? "" : String(describing: detail))")
    }

    func waitFor(_ what: String, seconds: TimeInterval = 30, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !(await condition()) {
            guard Date() < deadline else { throw SetbeamError.runtime("Timed out waiting for \(what).") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: Session wiring, as SessionModel does it

    func publishGatewayState() async {
        let snapshot = await runtime.snapshot()
        gateway.update(ViewerSession(token: snapshot.guestToken, title: options.title, sample: true, state: snapshot.session.audience,
                                     playback: snapshot.audience, revision: snapshot.audienceRevision))
        updateShortAddress(sharing: snapshot.session.sharing)
    }

    func updateShortAddress(sharing: Bool) {
        let open = shortAddressEnabled && sharing && gateway.approvalRequired && !gatewayDown
        gateway.setShortAddress(open: open)
        guard open, let path = gateway.shortAddressPath else {
            if lastServedPath != nil { listener.stop(); lastServedPath = nil; event("short.closed") }
            return
        }
        if path != lastServedPath {
            listener.serve(.init(address: options.viewerAddress, hosts: [host], port: gatewayPort, path: path))
            lastServedPath = path
            event("short.open", ["askPath": fingerprint(path) ?? ""])
        }
    }

    /// Applies admitted readers to the media server, then lets the gateway hand them out. An uncertain
    /// update ends sharing, exactly as the app does; local monitoring continues.
    func syncViewerAccess() async {
        let readers = gateway.desiredReaders
        guard readers != appliedReaders else { return }
        do {
            try await runtime.setViewerAccess(approval: true, readers: readers)
            appliedReaders = readers
            gateway.confirm(readers: readers)
        } catch {
            lastProblem = "viewer access could not be confirmed; sharing ended"
            event("access.failed")
            await endSharing()
        }
        await publishGatewayState()
    }

    func startSharing() async throws {
        _ = try await runtime.startSharing(approval: true)
        appliedReaders = []
        try await waitFor("the audience output", seconds: 45) { let s = await runtime.snapshot(); return s.audienceAvailable && s.sourceAvailable }
        await publishGatewayState()
        event("sharing.start", ["revision": await runtime.snapshot().audienceRevision])
    }

    func endSharing() async {
        listener.stop(); lastServedPath = nil
        await runtime.stopSharing()
        appliedReaders = []
        await publishGatewayState()
        event("sharing.stop")
    }

    func setUp() async throws {
        let available = NetworkAddress.available()
        guard let network = available.first(where: { $0.address == options.viewerAddress }) else {
            throw SetbeamError.runtime("--viewer-address must be one of this Mac's IPv4 addresses: \(available.map(\.address).joined(separator: ", "))")
        }
        // The app opens the short address only on a network others can join.
        guard network.interface != "lo0" else { throw SetbeamError.runtime("The short address is never offered on This Mac only (lo0).") }
        _ = try await runtime.prepare(source: .sample, viewerAddress: options.viewerAddress)
        try await waitFor("the sample source", seconds: 45) { await runtime.snapshot().sourceAvailable }
        gatewayPort = try await gateway.start(address: options.viewerAddress)
        gateway.setAccess(approval: true, pointers: false)
        try await runtime.setViewerAccess(approval: true, readers: [])
        try await startSharing()
        try await waitFor("the short-address listener", seconds: 10) { listener.state != .starting && listener.state != .stopped }
        if case .unavailable(let problem) = listener.state {
            throw SetbeamError.runtime("Port \(options.webPort) is unavailable (\(problem.rawValue)); choose another --web-port and configure the receiver for it.")
        }
        event("ready", ["viewerAddress": options.viewerAddress, "interface": network.interface, "webPort": Int(options.webPort),
                        "gatewayPort": Int(gatewayPort)])
    }

    // MARK: Commands

    func viewer(_ arguments: [String: Any], admission: ViewerAdmission?) throws -> ViewerActivity {
        let candidates = gateway.viewers.filter { admission == nil || $0.admission == admission }
        if let number = arguments["number"] as? Int, let match = candidates.first(where: { $0.number == number }) { return match }
        if let name = arguments["name"] as? String {
            let named = candidates.filter { $0.name == name }
            guard named.count == 1 else { throw SetbeamError.runtime("Expected one \(admission?.rawValue ?? "") viewer named \(name); found \(named.count).") }
            return named[0]
        }
        throw SetbeamError.runtime("No matching \(admission?.rawValue ?? "") viewer.")
    }

    func perform(_ command: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        switch command {
        case "admit":
            let target = try viewer(arguments, admission: .pending)
            guard gateway.approve(number: target.number) else { throw SetbeamError.runtime("Admit was refused for \(target.number).") }
            event("viewer.admit", ["number": target.number])
            await syncViewerAccess()
            return ["number": target.number]
        case "decline":
            let target = try viewer(arguments, admission: .pending)
            guard gateway.decline(number: target.number) else { throw SetbeamError.runtime("Decline was refused for \(target.number).") }
            event("viewer.decline", ["number": target.number])
            return ["number": target.number]
        case "remove":
            let target = try viewer(arguments, admission: .admitted)
            guard gateway.remove(number: target.number) else { throw SetbeamError.runtime("Remove was refused for \(target.number).") }
            event("viewer.remove", ["number": target.number])
            await syncViewerAccess()
            return ["number": target.number]
        case "hold", "resume":
            try await runtime.setHold(command == "hold")
            try await waitFor("the \(command) output", seconds: 30) {
                let s = await runtime.snapshot(); return s.session.holding == (command == "hold") && s.audienceAvailable
            }
            await publishGatewayState()
            event("audience.\(command)", ["revision": await runtime.snapshot().audienceRevision])
            return [:]
        case "stop":
            await endSharing()
            return [:]
        case "start":
            try await startSharing()
            return [:]
        case "newshare":
            let before = fingerprint(gateway.shortAddressPath)
            await endSharing()
            try await startSharing()
            return ["previousAskPath": before ?? "", "askPath": fingerprint(gateway.shortAddressPath) ?? ""]
        case "close-short", "open-short":
            shortAddressEnabled = command == "open-short"
            await publishGatewayState()
            return [:]
        case "source-outage", "server-outage":
            // Owned processes only, by the runtime's own PIDs: [media server, source, audience].
            let pids = await runtime.processIDs()
            guard pids.count == 3 else { throw SetbeamError.runtime("Expected server, source, and audience processes; found \(pids.count).") }
            let target = command == "source-outage" ? pids[1] : pids[0]
            let revision = await runtime.snapshot().audienceRevision
            kill(target, SIGKILL)
            event(command, ["revision": revision])
            try await waitFor("recovery after \(command)", seconds: 60) {
                let s = await runtime.snapshot(), current = await runtime.processIDs()
                return s.sourceAvailable && s.audienceAvailable && !current.contains(target)
            }
            await publishGatewayState()
            let after = await runtime.snapshot().audienceRevision
            event("\(command).recovered", ["revision": after])
            return ["revisionBefore": revision, "revisionAfter": after]
        case "gateway-outage":
            let seconds = min(max(arguments["seconds"] as? Double ?? 10, 1), 120)
            // As SessionModel recovers a lost viewing network: the same gateway (ledger, passes, ask path) is
            // restarted on the same port with gateway.start, never gateway.stop, which would retire the share.
            // While down it listens on loopback only, so the receiver's connections are refused.
            gatewayDown = true; listener.stop(); lastServedPath = nil
            _ = try await gateway.start(address: "127.0.0.1", port: gatewayPort)
            event("gateway.down", ["seconds": seconds])
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            gatewayPort = try await gateway.start(address: options.viewerAddress, port: gatewayPort)
            gatewayDown = false
            await publishGatewayState()
            event("gateway.up", ["gatewayPort": Int(gatewayPort)])
            return [:]
        case "chat":
            // An operator (DigiTech) message, as the Mac's Chat panel posts it.
            let text = arguments["text"] as? String ?? "Hello from the Mac"
            let token = await runtime.snapshot().guestToken
            try gateway.postChat(text: text, replyTo: nil, frame: nil, revision: 0, token: token, name: "DigiTech", color: .blue,
                                 requestID: UUID().uuidString)
            event("chat.post", ["lastID": gateway.chatMessages.last?.id ?? 0])
            return ["id": gateway.chatMessages.last?.id ?? 0]
        case "pointers":
            // Sharing Options' shared-pointer choice. Approval stays on.
            let on = arguments["on"] as? Bool ?? true
            gateway.setAccess(approval: true, pointers: on)
            event("pointers", ["on": on])
            return ["on": on]
        case "quit":
            quitting = true
            return [:]
        default:
            throw SetbeamError.runtime("Unknown command \(command).")
        }
    }

    func processCommands() async {
        while true {
            let file = commands.appendingPathComponent("\(nextCommand).json")
            guard let data = try? Data(contentsOf: file) else { return }
            var ack: [String: Any] = ["seq": nextCommand]
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let command = object["command"] as? String {
                log("COMMAND \(nextCommand) \(command)")
                do { ack["result"] = try await perform(command, object); ack["ok"] = true }
                catch { ack["ok"] = false; ack["error"] = error.localizedDescription; log("COMMAND \(nextCommand) failed: \(error.localizedDescription)") }
            } else {
                ack["ok"] = false; ack["error"] = "Malformed command file."
            }
            write(ack, to: acks.appendingPathComponent("\(nextCommand).json"))
            nextCommand += 1
            if quitting { return }
        }
    }

    // MARK: Status

    func write(_ object: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        _ = rename(temporary.path, url.path)
    }

    func writeStatus(started: Date) async {
        let s = await runtime.snapshot()
        let viewers: [[String: Any]] = gateway.viewers.map { v in
            ["number": v.number, "name": v.name ?? "", "admission": v.admission.rawValue, "playing": v.playing,
             "health": v.health.rawValue, "revision": v.revision, "shortAddress": v.shortAddress, "updatesMissing": v.updatesMissing,
             "lastSeenAgo": Date().timeIntervalSince(v.lastSeen), "label": v.label]
        }
        let processes = await runtime.processIDs()
        let listenerState: String
        switch listener.state {
        case .stopped: listenerState = "stopped"
        case .starting: listenerState = "starting"
        case .active: listenerState = "active"
        case .unavailable(let problem): listenerState = "unavailable:\(problem.rawValue)"
        }
        write([
            "pid": Int(getpid()), "uptime": Date().timeIntervalSince(started), "lifetime": options.lifetime,
            "viewerAddress": options.viewerAddress, "webPort": Int(options.webPort), "gatewayPort": Int(gatewayPort),
            "listener": listenerState, "askPath": fingerprint(gateway.shortAddressPath) ?? NSNull(), "link": fingerprint(s.guestToken) ?? "",
            "sharing": s.session.sharing, "holding": s.session.holding, "monitoring": s.session.monitoring, "audience": s.session.audience.rawValue,
            "sourceAvailable": s.sourceAvailable, "audienceAvailable": s.audienceAvailable, "revision": s.audienceRevision,
            "sourceFrameAge": s.lastFrameAt.map { Date().timeIntervalSince($0) } ?? NSNull(),
            "sourceHasAudio": s.sourceHasAudio, "audienceHasAudio": s.audienceHasAudio,
            "readers": appliedReaders.count, "viewers": viewers, "nextCommand": nextCommand, "events": events,
            "problem": lastProblem ?? NSNull(), "processes": processes.map(Int.init), "sample": true
        ], to: statusFile)
    }

    func shutdown() async {
        listener.stop(); gateway.stop()
        let pids = await runtime.processIDs()
        await runtime.shutdown()
        let survivors = pids.filter { kill($0, 0) == 0 }
        log(survivors.isEmpty ? "CLEANUP owned media processes exited" : "CLEANUP FAILED: \(survivors.count) owned media processes survived")
        try? FileManager.default.removeItem(at: statusFile)
    }
}

@main struct SetbeamReceiverFixture {
    static func main() async {
        let parent = getppid()
        var stop = false
        for value in [SIGINT, SIGTERM, SIGHUP] { signal(value, SIG_IGN) }
        let sources = [SIGINT, SIGTERM, SIGHUP].map { DispatchSource.makeSignalSource(signal: $0, queue: .main) }
        let signalled = ManagedFlag()
        for source in sources { source.setEventHandler { signalled.set() }; source.resume() }
        let options: Options
        do { options = try Options.parse(CommandLine.arguments) } catch { log("FAIL: \(error.localizedDescription)"); exit(2) }
        let harness: Harness
        do { harness = try Harness(options: options) } catch { log("FAIL: \(error.localizedDescription)"); exit(2) }
        SessionLog.shared.configure(directory: options.runtime!.appendingPathComponent("session-log", isDirectory: true))
        let started = Date()
        do {
            try await harness.setUp()
            log("READY Sample session sharing on \(options.viewerAddress); short address port \(options.webPort); lifetime \(Int(options.lifetime)) s")
            var lastSync = Date.distantPast
            while !stop {
                await harness.processCommands()
                if Date().timeIntervalSince(lastSync) > 0.25 {
                    await harness.publishGatewayState()
                    await harness.syncViewerAccess()
                    await harness.writeStatus(started: started)
                    lastSync = Date()
                }
                if harness.quitting { log("QUIT requested"); stop = true }
                if signalled.value { log("QUIT on signal"); stop = true }
                if getppid() != parent { log("QUIT: controller exited"); stop = true }
                if Date().timeIntervalSince(started) > options.lifetime { log("QUIT: lifetime reached"); stop = true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            await harness.shutdown()
            exit(0)
        } catch {
            log("FAIL: \(error.localizedDescription)")
            await harness.shutdown()
            exit(1)
        }
    }
}

final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
