import XCTest
@testable import SetbeamCore

final class PointerPresenceTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private func presence(_ names: [String] = ["Sam"]) -> PointerPresence {
        var value = PointerPresence(revision: 3)
        for (index, name) in names.enumerated() { XCTAssertTrue(value.join(index + 1, name: name, color: .blue, now: start)) }
        return value
    }

    func testStationaryPointerFadesDespiteRepeatedIdenticalUpdates() {
        var value = presence()
        XCTAssertTrue(value.move(1, x: 0.4, y: 0.6, revision: 3, explicit: false, now: start))
        // A heartbeat-like sender repeats the same coordinates and tiny jitter for longer than the idle interval.
        for step in 1...45 {
            let jitter = step.isMultiple(of: 2) ? 0.0005 : 0
            _ = value.move(1, x: 0.4 + jitter, y: 0.6, revision: 3, explicit: false, now: start.addingTimeInterval(Double(step) / 10))
        }
        XCTAssertTrue(value.pointers(now: start.addingTimeInterval(3.9)).count == 1)
        XCTAssertTrue(value.pointers(now: start.addingTimeInterval(4.0)).isEmpty, "Unchanged coordinates must not keep a pointer visible")
        XCTAssertNil(value.nextExpiry(now: start.addingTimeInterval(4.1)))
        // Meaningful movement or an explicit tap brings it back.
        XCTAssertTrue(value.move(1, x: 0.45, y: 0.6, revision: 3, explicit: false, now: start.addingTimeInterval(5)))
        XCTAssertEqual(value.pointers(now: start.addingTimeInterval(5)).first?.remaining ?? 0, PointerPresence.idle, accuracy: 0.001)
        XCTAssertTrue(value.move(1, x: 0.45, y: 0.6, revision: 3, explicit: true, now: start.addingTimeInterval(9.5)))
        XCTAssertEqual(value.pointers(now: start.addingTimeInterval(9.5)).count, 1)
    }

    func testSlowContinuousMovementCountsOnceItCrossesTheThreshold() {
        var value = presence()
        _ = value.move(1, x: 0.5, y: 0.5, revision: 3, explicit: false, now: start)
        var x = 0.5
        for step in 1...38 { x += 0.0002; _ = value.move(1, x: x, y: 0.5, revision: 3, explicit: false, now: start.addingTimeInterval(Double(step) / 10)) }
        // 0.0076 total movement crossed the threshold twice, so the pointer stays visible past four seconds.
        XCTAssertEqual(value.pointers(now: start.addingTimeInterval(4.2)).count, 1)
    }

    func testInvalidStaleAndUnknownUpdatesAreDropped() {
        var value = presence()
        for (x, y) in [(Double.nan, 0.5), (.infinity, 0.5), (1.01, 0.5), (-0.01, 0.5), (0.5, 1.2)] {
            XCTAssertFalse(value.move(1, x: x, y: y, revision: 3, explicit: true, now: start))
        }
        XCTAssertFalse(value.move(1, x: 0.5, y: 0.5, revision: 2, explicit: true, now: start), "An old picture's coordinates are dropped")
        XCTAssertFalse(value.move(9, x: 0.5, y: 0.5, revision: 3, explicit: true, now: start), "Only participants can point")
        XCTAssertTrue(value.pointers(now: start).isEmpty)
        XCTAssertTrue(value.move(1, x: 0, y: 1, revision: 3, explicit: false, now: start), "Picture edges are inside the picture")
    }

    func testReplacementPictureClearsEveryPositionButKeepsParticipants() {
        var value = presence(["Sam", "Ana"])
        _ = value.move(1, x: 0.2, y: 0.2, revision: 3, explicit: false, now: start)
        _ = value.move(2, x: 0.8, y: 0.8, revision: 3, explicit: false, now: start)
        value.reset(revision: 4)
        XCTAssertTrue(value.pointers(now: start).isEmpty)
        XCTAssertEqual(value.participants, [1, 2])
        XCTAssertFalse(value.move(1, x: 0.3, y: 0.3, revision: 3, explicit: false, now: start))
        XCTAssertTrue(value.move(1, x: 0.3, y: 0.3, revision: 4, explicit: false, now: start))
        XCTAssertTrue(value.hide(1))
        XCTAssertTrue(value.pointers(now: start).isEmpty)
    }

    func testRateLimitDropsBurstsAndRefills() {
        var value = presence()
        var accepted = 0
        for step in 0..<100 where value.move(1, x: Double(step) / 100, y: 0.5, revision: 3, explicit: false, now: start) { accepted += 1 }
        XCTAssertEqual(accepted, Int(PointerPresence.burst))
        XCTAssertTrue(value.move(1, x: 0.9, y: 0.9, revision: 3, explicit: false, now: start.addingTimeInterval(0.1)))
    }

    func testDuplicateNamesAndColorsStaySeparateIdentities() {
        var value = PointerPresence(revision: 0)
        XCTAssertTrue(value.join(4, name: "Sam", color: .green, now: start))
        XCTAssertTrue(value.join(7, name: "sam", color: .green, now: start))
        XCTAssertTrue(value.join(9, name: "Ana", color: .green, now: start))
        for number in [4, 7, 9] { _ = value.move(number, x: 0.5, y: 0.5, revision: 0, explicit: false, now: start) }
        let pointers = value.pointers(now: start)
        XCTAssertEqual(pointers.map(\.number), [4, 7, 9])
        XCTAssertEqual(pointers.map(\.label), ["Sam · 4", "sam · 7", "Ana"])
        value.leave(7)
        XCTAssertEqual(value.pointers(now: start).map(\.label), ["Sam", "Ana"])
    }

    /// A tap in place re-arms the fade with the same remaining time a few seconds later. The
    /// native overlay must still be told, or it expires the pointer early (B4).
    func testNativeNotificationSeesATapInPlace() {
        var value = presence()
        _ = value.move(1, x: 0.5, y: 0.5, revision: 3, explicit: true, now: start)
        let first = value.pointers(now: start)
        XCTAssertTrue(ViewerGateway.samePointers(value.pointers(now: start.addingTimeInterval(1)), at: start.addingTimeInterval(1), first, at: start),
                      "Time passing alone is not a change")
        let later = start.addingTimeInterval(3)
        _ = value.move(1, x: 0.5, y: 0.5, revision: 3, explicit: true, now: later)
        XCTAssertEqual(value.pointers(now: later).first?.remaining, first.first?.remaining)
        XCTAssertFalse(ViewerGateway.samePointers(value.pointers(now: later), at: later, first, at: start))
    }

    func testParticipantLimit() {
        var value = PointerPresence(revision: 0)
        for number in 1...PointerPresence.maxParticipants { XCTAssertTrue(value.join(number, name: "P", color: .blue, now: start)) }
        XCTAssertFalse(value.join(99, name: "P", color: .blue, now: start))
        XCTAssertTrue(value.join(1, name: "Renamed", color: .pink, now: start), "An existing participant can update")
    }

    /// WCAG 2 relative luminance contrast between each pointer fill and its name text.
    func testPaletteNameTextIsReadable() {
        func luminance(_ rgb: (red: Double, green: Double, blue: Double)) -> Double {
            func channel(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(rgb.red) + 0.7152 * channel(rgb.green) + 0.0722 * channel(rgb.blue)
        }
        for color in PointerColor.allCases {
            let fill = luminance(color.rgb), text = color.darkText ? luminance((0.08, 0.08, 0.08)) : 1
            let ratio = (max(fill, text) + 0.05) / (min(fill, text) + 0.05)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, color.rawValue)
        }
        XCTAssertNil(PointerColor.validated("magenta")); XCTAssertNil(PointerColor.validated("<b>")); XCTAssertNil(PointerColor.validated(3))
        XCTAssertEqual(PointerColor.validated("pink"), .pink); XCTAssertEqual(PointerColor.validated("teal"), .teal)
        XCTAssertEqual(PointerColor.allCases.count, 12)
        // Sessions 1-6 keep the defaults they had before the palette grew.
        XCTAssertEqual((1...6).map(PointerColor.fallback(for:)), [.blue, .green, .orange, .pink, .purple, .yellow])
        XCTAssertEqual(Set((1...12).map(PointerColor.fallback(for:))).count, 12)
    }
}

final class WebSocketFrameTests: XCTestCase {
    private func masked(_ opcode: UInt8, _ payload: [UInt8], fin: Bool = true, mask: [UInt8] = [1, 2, 3, 4]) -> Data {
        var data = Data([(fin ? 0x80 : 0) | opcode])
        if payload.count < 126 { data.append(0x80 | UInt8(payload.count)) }
        else { data.append(0x80 | 126); data.append(UInt8(payload.count >> 8)); data.append(UInt8(payload.count & 0xff)) }
        data.append(contentsOf: mask)
        data.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return data
    }

    func testHandshakeKeyMatchesRFC6455Example() {
        XCTAssertEqual(WebSocketFrame.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        XCTAssertNil(WebSocketFrame.acceptKey(for: "short"))
    }

    func testParsesMaskedFramesAndKeepsPartialInput() throws {
        var buffer = masked(0x1, Array(#"{"t":"ping"}"#.utf8)) + masked(0x9, [7]) + masked(0x1, Array(String(repeating: "x", count: 300).utf8))
        let complete = buffer.count
        buffer.append(masked(0x1, Array("partial".utf8)).prefix(5))
        let frames = try WebSocketFrame.parse(&buffer, maxPayload: 512)
        XCTAssertEqual(frames, [.text(#"{"t":"ping"}"#), .ping(Data([7])), .text(String(repeating: "x", count: 300))])
        XCTAssertEqual(buffer.count, 5, "A partial frame waits for more input")
        XCTAssertGreaterThan(complete, 300)
    }

    func testRejectsUnmaskedFragmentedBinaryAndOversizedFrames() {
        func failure(_ data: Data, max: Int = 64) -> WebSocketFrame.Failure? {
            var buffer = data
            do { _ = try WebSocketFrame.parse(&buffer, maxPayload: max); return nil } catch { return error as? WebSocketFrame.Failure }
        }
        XCTAssertEqual(failure(Data([0x81, 0x02, 0x41, 0x42])), .protocolError, "Client frames must be masked")
        XCTAssertEqual(failure(masked(0x1, [0x41], fin: false)), .protocolError, "No fragmentation")
        XCTAssertEqual(failure(masked(0x2, [0x41])), .protocolError, "No binary frames")
        XCTAssertEqual(failure(masked(0x1, [0xff, 0xfe])), .protocolError, "Text must be UTF-8")
        XCTAssertEqual(failure(masked(0x1, Array(repeating: 0x41, count: 65))), .tooLarge)
        XCTAssertEqual(failure(Data([0x81, 0xff])), .tooLarge, "64-bit lengths are refused before buffering")
    }

    func testServerFramesAreUnmasked() {
        XCTAssertEqual(WebSocketFrame.encode(text: "hi"), Data([0x81, 0x02, 0x68, 0x69]))
        XCTAssertEqual(WebSocketFrame.encode(text: String(repeating: "a", count: 200)).prefix(4), Data([0x81, 126, 0, 200]))
    }
}
