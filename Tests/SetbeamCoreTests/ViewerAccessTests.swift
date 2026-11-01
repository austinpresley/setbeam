import XCTest
@testable import SetbeamCore

final class ViewerAccessLedgerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 5_000)

    private func joined(_ outcome: ViewerAccessLedger.JoinOutcome, file: StaticString = #filePath, line: UInt = #line) -> ViewerAccessLedger.Record? {
        if case .joined(let record) = outcome { return record }
        XCTFail("Expected a joined session", file: file, line: line); return nil
    }

    func testWithoutApprovalTheLinkAdmitsAndNamesStayOptionalLabels() throws {
        var ledger = ViewerAccessLedger()
        let first = try XCTUnwrap(joined(ledger.join(pass: nil, name: nil, color: nil, mobile: false, local: false, now: now)))
        let second = try XCTUnwrap(joined(ledger.join(pass: nil, name: "Sam", color: nil, mobile: true, local: false, now: now)))
        XCTAssertEqual(first.admission, .admitted); XCTAssertTrue(first.mediaReady); XCTAssertNil(first.reader)
        XCTAssertEqual([first.number, second.number], [1, 2])
        XCTAssertNotEqual(first.pass, second.pass)
        XCTAssertNotNil(ViewerAccessLedger.validPass(first.pass))
        XCTAssertTrue(ledger.readers.isEmpty, "Ordinary link sharing keeps its shared read credential")
        _ = ledger.heartbeat(first.pass, playing: true, health: .good, revision: 0, name: .some("Sam"), mobile: false, local: false, now: now)
        XCTAssertEqual(ledger.record(first.pass)?.name, "Sam")
        XCTAssertFalse(ledger.remove(number: 1), "Removal is not offered when the link alone admits viewers")
    }

    func testApprovalRequiresANameAndAnOperatorDecision() throws {
        var ledger = ViewerAccessLedger(); ledger.setApproval(true)
        guard case .nameRequired = ledger.join(pass: nil, name: nil, color: nil, mobile: false, local: false, now: now) else { return XCTFail() }
        let request = try XCTUnwrap(joined(ledger.join(pass: nil, name: "Sam", color: .pink, mobile: false, local: false, now: now)))
        XCTAssertEqual(request.admission, .pending); XCTAssertFalse(request.mediaReady)
        XCTAssertTrue(ledger.readers.isEmpty, "A waiting request has no media credential")
        XCTAssertTrue(ledger.approve(number: request.number))
        let admitted = try XCTUnwrap(ledger.record(request.pass))
        let reader = try XCTUnwrap(admitted.reader)
        XCTAssertFalse(admitted.mediaReady, "Not usable until the media server accepts it")
        XCTAssertEqual(ledger.readers, [reader])
        XCTAssertNotEqual(reader.user, "guest")
        XCTAssertTrue(ledger.confirm(readers: [reader]))
        XCTAssertTrue(ledger.record(request.pass)?.mediaReady == true)
        // The admitted name is the one the operator approved.
        _ = ledger.heartbeat(request.pass, playing: true, health: .good, revision: 0, name: .some("Director"), mobile: false, local: false, now: now)
        ledger.setName(request.pass, "Director")
        XCTAssertEqual(ledger.record(request.pass)?.name, "Sam")
        XCTAssertFalse(ledger.approve(number: request.number), "A decision is applied once")
    }

    func testRemovedAndDeclinedSessionsAreNeverSilentlyReadmitted() throws {
        var ledger = ViewerAccessLedger(); ledger.setApproval(true)
        let a = try XCTUnwrap(joined(ledger.join(pass: nil, name: "A", color: nil, mobile: false, local: false, now: now)))
        let b = try XCTUnwrap(joined(ledger.join(pass: nil, name: "B", color: nil, mobile: false, local: false, now: now)))
        ledger.approve(number: a.number); ledger.approve(number: b.number)
        let readerB = try XCTUnwrap(ledger.record(b.pass)?.reader)
        XCTAssertTrue(ledger.remove(number: a.number))
        XCTAssertEqual(ledger.readers, [readerB], "Only the removed session loses its credential")
        let again = try XCTUnwrap(joined(ledger.join(pass: a.pass, name: "A", color: nil, mobile: false, local: false, now: now)))
        XCTAssertEqual(again.admission, .removed, "Reloading the same tab keeps the removal")
        XCTAssertFalse(ledger.approve(number: a.number))
        let c = try XCTUnwrap(joined(ledger.join(pass: nil, name: "C", color: nil, mobile: false, local: false, now: now)))
        XCTAssertTrue(ledger.decline(number: c.number))
        XCTAssertEqual(try XCTUnwrap(joined(ledger.join(pass: c.pass, name: "C", color: nil, mobile: false, local: false, now: now))).admission, .declined)
        // A forged or forgotten pass is a new request that the operator must decide.
        let forged = String(repeating: "ab", count: 24)
        let fresh = try XCTUnwrap(joined(ledger.join(pass: forged, name: "A", color: nil, mobile: false, local: false, now: now)))
        XCTAssertEqual(fresh.admission, .pending); XCTAssertNotEqual(fresh.pass, forged)
        // Turning approval off keeps refusals.
        ledger.setApproval(false)
        XCTAssertEqual(ledger.record(a.pass)?.admission, .removed)
        XCTAssertEqual(ledger.record(c.pass)?.admission, .declined)
        XCTAssertEqual(ledger.record(fresh.pass)?.admission, .admitted)
    }

    func testTurningApprovalOnGivesAlreadyAdmittedViewersTheirOwnReaders() throws {
        var ledger = ViewerAccessLedger()
        let a = try XCTUnwrap(joined(ledger.join(pass: nil, name: nil, color: nil, mobile: false, local: false, now: now)))
        ledger.setApproval(true)
        // A session admitted unnamed before approval can set its first label once (A4).
        ledger.setName(a.pass, "Ana")
        ledger.setName(a.pass, "Director")
        XCTAssertEqual(ledger.record(a.pass)?.name, "Ana")
        let record = try XCTUnwrap(ledger.record(a.pass))
        XCTAssertEqual(record.admission, .admitted); XCTAssertNotNil(record.reader); XCTAssertFalse(record.mediaReady)
        XCTAssertTrue(ledger.remove(number: a.number), "Now individually removable")
    }

    func testRequestAndSessionCountsAreBounded() throws {
        var ledger = ViewerAccessLedger(); ledger.setApproval(true)
        for index in 0..<ViewerAccessLedger.maxPending {
            XCTAssertNotNil(joined(ledger.join(pass: nil, name: "R\(index)", color: nil, mobile: false, local: false, now: now)))
        }
        guard case .full = ledger.join(pass: nil, name: "Extra", color: nil, mobile: false, local: false, now: now) else { return XCTFail() }
        // Unanswered requests lapse once their pages stop asking.
        XCTAssertNotNil(joined(ledger.join(pass: nil, name: "Later", color: nil, mobile: false, local: false,
                                           now: now.addingTimeInterval(ViewerAccessLedger.pendingFor + 1))))

        var open = ViewerAccessLedger()
        for _ in 0..<ViewerAccessLedger.maxRecords { _ = open.join(pass: nil, name: nil, color: nil, mobile: false, local: false, now: now) }
        guard case .full = open.join(pass: nil, name: nil, color: nil, mobile: false, local: false, now: now) else { return XCTFail("Active sessions are never evicted") }
        XCTAssertNotNil(joined(open.join(pass: nil, name: nil, color: nil, mobile: false, local: false,
                                         now: now.addingTimeInterval(ViewerAccessLedger.visibleFor + 1))), "A stale session makes room")
    }

    func testOperatorRowsUseServerNumbersNotPasses() throws {
        var ledger = ViewerAccessLedger(); ledger.setApproval(true)
        let a = try XCTUnwrap(joined(ledger.join(pass: nil, name: "Sam", color: nil, mobile: false, local: true, now: now)))
        _ = ledger.join(pass: nil, name: "Sam", color: nil, mobile: false, local: false, now: now)
        let rows = ledger.activity(session: nil, now: now)
        XCTAssertEqual(rows.map(\.id), ["viewer-1", "viewer-2"])
        XCTAssertFalse(rows.contains { $0.id.contains(a.pass) })
        XCTAssertEqual(rows.map(\.admission), [.pending, .pending])
        XCTAssertEqual(rows.map(\.displayName), ["Sam", "Sam"]); XCTAssertNotEqual(rows[0].number, rows[1].number)
    }
}

/// Gateway behavior through real local HTTP and WebSocket connections.
final class ViewerAdmissionGatewayTests: XCTestCase {
    private var host: ViewerGateway!
    private var origin = ""
    private let token = "admission-test-token"
    private func session(revision: Int = 1, state: AudienceState = .live) -> ViewerSession {
        ViewerSession(token: token, title: "Studio", sample: true, state: state,
            playback: PlaybackDescriptor(origin: "http://127.0.0.1:8889", path: "live", user: "guest", password: "shared-guest-value"), revision: revision)
    }

    override func setUp() async throws {
        host = ViewerGateway(assets: [:])
        host.update(session())
        let port = try await host.start(address: "127.0.0.1")
        origin = "http://127.0.0.1:\(port)"
    }
    override func tearDown() { host.stop(); host = nil }

    @discardableResult
    private func call(_ path: String, _ body: [String: Any]? = nil, pass: String? = nil) async throws -> (status: Int, json: [String: Any]) {
        var request = URLRequest(url: URL(string: origin + "/s/\(token)/" + path)!)
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        if let pass { request.setValue(pass, forHTTPHeaderField: "X-Setbeam-Pass") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }
    private func join(_ name: String? = nil, pass: String? = nil) async throws -> (status: Int, json: [String: Any]) {
        var body: [String: Any] = ["mobile": false]; body["name"] = name; body["pass"] = pass
        return try await call("join", body)
    }

    func testOrdinaryLinkWatchingIsUnchangedWithoutApproval() async throws {
        let joined = try await join()
        XCTAssertEqual(joined.json["admission"] as? String, "admitted")
        XCTAssertEqual(joined.json["ready"] as? Bool, true)
        let config = try await call("config.json", pass: joined.json["pass"] as? String)
        XCTAssertEqual(config.status, 200)
        XCTAssertEqual(config.json["user"] as? String, "guest")
        XCTAssertEqual(config.json["pass"] as? String, "shared-guest-value")
        let state = try await call("state.json")
        XCTAssertEqual(state.json["approval"] as? Bool, false)
        XCTAssertNil(state.json["viewers"]); XCTAssertNil(state.json["names"])
    }

    func testApprovalGatesPlaybackAndRemovalRevokesOnlyThatSession() async throws {
        host.setAccess(approval: true, pointers: false)
        let unnamed = try await join()
        XCTAssertEqual(unnamed.status, 400)
        let a = try await join("Sam"), b = try await join("Sam")
        let passA = try XCTUnwrap(a.json["pass"] as? String), passB = try XCTUnwrap(b.json["pass"] as? String)
        XCTAssertEqual(a.json["admission"] as? String, "pending")
        // A waiting page cannot obtain playback details, with or without its pass.
        let pending = try await call("config.json", pass: passA)
        XCTAssertEqual(pending.status, 403); XCTAssertNil(pending.json["pass"])
        let awaited1 = try await call("config.json").status
        XCTAssertEqual(awaited1, 403)
        XCTAssertEqual(host.viewers.map(\.admission), [.pending, .pending])
        XCTAssertEqual(host.viewers.map(\.displayName), ["Sam", "Sam"], "Equal names remain two numbered sessions")

        XCTAssertTrue(host.approve(number: 1)); XCTAssertTrue(host.approve(number: 2))
        let awaited2 = try await call("config.json", pass: passA).status
        XCTAssertEqual(awaited2, 503, "Unusable until the media server accepts the reader")
        let readers = host.desiredReaders
        XCTAssertEqual(readers.count, 2)
        host.confirm(readers: readers)
        let configA = try await call("config.json", pass: passA), configB = try await call("config.json", pass: passB)
        let userA = try XCTUnwrap(configA.json["user"] as? String), userB = try XCTUnwrap(configB.json["user"] as? String)
        XCTAssertNotEqual(userA, "guest"); XCTAssertNotEqual(userA, userB)
        XCTAssertNotEqual(configA.json["pass"] as? String, "shared-guest-value")
        XCTAssertEqual(Set(readers.map(\.user)), [userA, userB])

        XCTAssertTrue(host.remove(number: 1))
        XCTAssertEqual(host.desiredReaders.map(\.user), [userB], "Removal revokes only that session's reader")
        let removed = try await call("config.json", pass: passA)
        XCTAssertEqual(removed.status, 403); XCTAssertEqual(removed.json["admission"] as? String, "removed")
        let awaited3 = try await call("heartbeat", ["pass": passA, "playing": true]).json["admission"] as? String
        XCTAssertEqual(awaited3, "removed")
        let awaited4 = try await join("Sam", pass: passA).json["admission"] as? String
        XCTAssertEqual(awaited4, "removed", "Reload does not readmit")
        let awaited5 = try await call("config.json", pass: passB).status
        XCTAssertEqual(awaited5, 200, "Other viewers continue")

        let forged = String(repeating: "cd", count: 24)
        let awaited6 = try await call("config.json", pass: forged).status
        XCTAssertEqual(awaited6, 403)
        let awaited7 = try await call("heartbeat", ["pass": forged, "playing": true]).json["admission"] as? String
        XCTAssertEqual(awaited7, "unknown")
        let awaited8 = try await call("heartbeat", ["id": "viewer-browser-01", "playing": true]).json["admission"] as? String
        XCTAssertEqual(awaited8, "unknown",
                       "A client-chosen ID is not an identity")
        XCTAssertEqual(host.viewers.map(\.number), [2])
    }

    func testANewViewingLinkForgetsEveryAdmission() async throws {
        host.setAccess(approval: true, pointers: true)
        let a = try await join("Sam")
        host.approve(number: 1); host.confirm(readers: host.desiredReaders)
        host.update(ViewerSession(token: "next-link", title: "Studio", sample: true, state: .live,
            playback: PlaybackDescriptor(origin: "http://127.0.0.1:8889", path: "live", user: "guest", password: "next"), revision: 2))
        XCTAssertTrue(host.desiredReaders.isEmpty)
        XCTAssertTrue(host.viewers.isEmpty)
        var request = URLRequest(url: URL(string: origin + "/s/next-link/config.json")!)
        request.setValue(a.json["pass"] as? String, forHTTPHeaderField: "X-Setbeam-Pass")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 403, "An old link's pass means nothing to a new link")
        XCTAssertTrue(host.approvalRequired, "The operator's approval choice stays")
    }

    func testOversizedAndMalformedRequestsAreRefused() async throws {
        let long = try await join(String(repeating: "N", count: 500))
        XCTAssertEqual((long.json["name"] as? String)?.count, 40)
        let markup = try await join("<img src=x onerror=alert(1)>\u{202e}")
        XCTAssertEqual(markup.json["name"] as? String, "<img src=x onerror=alert(1)>", "Stored as plain text; pages render it as text")
        let color = try await call("join", ["color": "javascript:alert(1)"])
        XCTAssertEqual(color.json["color"] as? String, PointerColor.fallback(for: 3).rawValue)
        var request = URLRequest(url: URL(string: origin + "/s/\(token)/join")!)
        request.httpMethod = "POST"; request.httpBody = Data("not json".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 400)
    }
}
