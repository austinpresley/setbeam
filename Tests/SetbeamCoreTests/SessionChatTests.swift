import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SetbeamCore

final class SessionChatTests: XCTestCase {
    private let viewer = ChatAuthor(number: 1, name: "Sam", color: .teal)
    private let start = Date(timeIntervalSince1970: 1000)
    func testReactionsReplaceToggleAndProjectPerParticipant() throws {
        var chat = SessionChat()
        try chat.post(author: viewer, text: "Frame looks good", replyTo: nil, frame: nil, requestID: UUID().uuidString, now: start)
        try chat.react(id: 1, author: 1, reaction: .thumbsUp, now: start)
        XCTAssertTrue(chat.messages(for: 1)[0].ownMessage)
        XCTAssertFalse(chat.messages(for: 0)[0].ownMessage)
        XCTAssertEqual(chat.messages(for: 1)[0].reactions.first?.reaction, .thumbsUp)
        XCTAssertTrue(chat.messages(for: 1)[0].reactions.first!.selected)
        XCTAssertFalse(chat.messages(for: 0)[0].reactions.first!.selected)
        // Repeating an existing selection is idempotent, including the rate budget.
        for _ in 0..<20 { try chat.react(id: 1, author: 1, reaction: .thumbsUp, now: start) }
        try chat.react(id: 1, author: 1, reaction: .heart, now: start.addingTimeInterval(2))
        try chat.react(id: 1, author: 2, reaction: .heart, now: start)
        XCTAssertEqual(chat.messages(for: 1)[0].reactions.count, 1)
        XCTAssertEqual(chat.messages(for: 1)[0].likes, 2)
        try chat.react(id: 1, author: 1, reaction: nil, now: start.addingTimeInterval(3))
        XCTAssertEqual(chat.messages(for: 1)[0].likes, 1)
        XCTAssertFalse(chat.messages(for: 1)[0].liked)
        try chat.react(id: 1, author: 1, reaction: .sad, now: start.addingTimeInterval(4))
        try chat.like(id: 1, author: 1, liked: false, now: start.addingTimeInterval(5))
        XCTAssertEqual(chat.messages(for: 1)[0].reactions.first(where: { $0.selected })?.reaction, .sad)
        XCTAssertThrowsError(try chat.react(id: 999, author: 1, reaction: .laugh, now: start))
        chat.remove(1); XCTAssertTrue(chat.messages(for: 1).isEmpty)
    }
    func testReactionBudgetIsBoundedAndReplacementAtCapacityWorks() throws {
        var chat = SessionChat()
        try chat.post(author: viewer, text: "Review", replyTo: nil, frame: nil, requestID: UUID().uuidString, now: start)
        for author in 1...128 { try chat.react(id: 1, author: author, reaction: .heart, now: start) }
        XCTAssertThrowsError(try chat.react(id: 1, author: 129, reaction: .laugh, now: start))
        try chat.react(id: 1, author: 1, reaction: .emphasis, now: start.addingTimeInterval(2))
        XCTAssertEqual(chat.messages(for: 1)[0].reactions.reduce(0) { $0 + $1.count }, 128)
        try chat.react(id: 1, author: 1, reaction: nil, now: start.addingTimeInterval(3))
        try chat.react(id: 1, author: 129, reaction: .surprised, now: start.addingTimeInterval(3))
        XCTAssertEqual(chat.messages(for: 129)[0].reactions.first(where: { $0.selected })?.reaction, .surprised)
        chat.reset(); XCTAssertTrue(chat.messages(for: 129).isEmpty)
    }
    func testReactionBurstDoesNotConsumeMessageBudget() throws {
        var chat = SessionChat()
        try chat.post(author: viewer, text: "First", replyTo: nil, frame: nil, requestID: UUID().uuidString, now: start)
        for reaction in [ChatReaction.heart, .thumbsUp, .laugh, .sad] {
            try chat.react(id: 1, author: 1, reaction: reaction, now: start)
        }
        XCTAssertThrowsError(try chat.react(id: 1, author: 1, reaction: .emphasis, now: start))
        XCTAssertNoThrow(try chat.post(author: viewer, text: "Next message", replyTo: nil, frame: nil, requestID: UUID().uuidString, now: start))
    }
    func testPlainTextBoundsDedupRepliesAndLikeOwnership() throws {
        var chat = SessionChat()
        let id = UUID().uuidString
        try chat.post(author: viewer, text: "<b>literal</b>\u{202E}\u{0000}\nsecond line", replyTo: nil, frame: nil, requestID: id, now: start)
        try chat.post(author: viewer, text: "duplicate", replyTo: nil, frame: nil, requestID: id, now: start)
        XCTAssertEqual(chat.messages(for: 1).count, 1)
        XCTAssertEqual(chat.messages(for: 1)[0].text, "<b>literal</b>\nsecond line")
        for _ in 0..<3 { try chat.post(author: viewer, text: "burst", replyTo: nil, frame: nil, requestID: UUID().uuidString, now: start) }
        XCTAssertThrowsError(try chat.post(author: viewer, text: "flood", replyTo: nil, frame: nil, requestID: UUID().uuidString, now: start))
        try chat.post(author: .init(number: 0, name: "DigiTech", color: .orange), text: "reply", replyTo: 1, frame: nil, requestID: UUID().uuidString, now: start)
        XCTAssertTrue(chat.messages(for: 1).last!.operatorMessage)
        XCTAssertEqual(chat.messages(for: 1).last!.replyTo, 1)
        try chat.like(id: 1, author: 1, liked: true, now: start.addingTimeInterval(1))
        try chat.like(id: 1, author: 1, liked: true, now: start.addingTimeInterval(1))
        XCTAssertEqual(chat.messages(for: 1)[0].likes, 1)
        XCTAssertTrue(chat.messages(for: 1)[0].liked)
        XCTAssertFalse(chat.messages(for: 0)[0].liked)
        XCTAssertThrowsError(try chat.post(author: viewer, text: String(repeating: "a", count: 1201), replyTo: nil, frame: nil, requestID: UUID().uuidString, now: start.addingTimeInterval(3)))
        XCTAssertThrowsError(try chat.post(author: viewer, text: "", replyTo: nil, frame: nil, requestID: UUID().uuidString, now: start.addingTimeInterval(3)))
    }
    func testHistoryAndFrameMemoryAreBoundedAndReset() throws {
        var chat = SessionChat()
        for i in 0..<110 {
            try chat.post(author: viewer, text: "Message \(i)", replyTo: nil, frame: Data([1]), requestID: UUID().uuidString, now: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(chat.messages(for: 0).count, 100)
        XCTAssertEqual(chat.entries.filter { $0.frame != nil }.count, 8)
        XCTAssertNil(chat.frame(1))
        XCTAssertThrowsError(try chat.post(author: viewer, text: "reply", replyTo: 1, frame: nil, requestID: UUID().uuidString, now: start.addingTimeInterval(200)))
        chat.reset(); XCTAssertTrue(chat.messages(for: 0).isEmpty)
        for i in 0..<9 {
            try chat.post(author: viewer, text: "", replyTo: nil, frame: Data([1]), requestID: UUID().uuidString, now: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(chat.messages(for: 0).first?.text, "")
        XCTAssertEqual(chat.messages(for: 0).first?.hasFrame, false, "An evicted image-only message can be shown as unavailable")
        XCTAssertEqual(chat.messages(for: 0).filter(\.hasFrame).count, 8)
    }
    func testJPEGValidationAndMetadataStripping() throws {
        let jpeg = try Self.jpeg()
        let clean = try SessionChat.sanitizedFrame(jpeg)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(clean as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 64)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertThrowsError(try SessionChat.sanitizedFrame(Data("not jpeg".utf8)))
        XCTAssertThrowsError(try SessionChat.sanitizedFrame(Data(repeating: 1, count: 131_073)))
        XCTAssertThrowsError(try SessionChat.sanitizedFrame(Self.jpeg(width: 2000)))
    }
    static func jpeg(width: Int = 64) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: 64))
        let image = try XCTUnwrap(context.makeImage()), data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.5]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return data as Data
    }
}

final class ChatGatewayTests: XCTestCase {
    func testChatAuthorizationHoldRevisionRemovalAndLinkRotation() async throws {
        let host = ViewerGateway(assets: [:]), token = "chat-fixture-token"
        var session = ViewerSession(token: token, title: "Fixture", sample: true, state: .live,
                                    playback: PlaybackDescriptor(origin: "http://127.0.0.1:8889", path: "live", user: "guest", password: "fixture"), revision: 7)
        host.update(session); host.setChatFramePermission(true)
        let port = try await host.start(address: "127.0.0.1")
        defer { host.stop() }
        let base = "http://127.0.0.1:\(port)", path = "/s/\(token)/"
        func call(_ suffix: String, pass: String? = nil, body: [String: Any]? = nil, origin: String? = nil) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: base + path + suffix)!)
            if let pass { request.setValue(pass, forHTTPHeaderField: "X-Setbeam-Pass") }
            if let body {
                request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(origin ?? base, forHTTPHeaderField: "Origin")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (try XCTUnwrap(response as? HTTPURLResponse).statusCode, data)
        }
        let forbidden = try await call("chat"); XCTAssertEqual(forbidden.0, 403)
        host.setAccess(approval: true, pointers: false)
        let join = try await call("join", body: ["name": "Sam", "ask": true, "color": "teal"])
        let identity = try XCTUnwrap(JSONSerialization.jsonObject(with: join.1) as? [String: Any])
        let pass = try XCTUnwrap(identity["pass"] as? String), number = try XCTUnwrap(identity["number"] as? Int)
        let waiting = try await call("chat", pass: pass); XCTAssertEqual(waiting.0, 403)
        XCTAssertTrue(host.approve(number: number))
        let marker = "CHAT-PRIVATE-CONTENT-<b>literal</b>"
        var post: [String: Any] = ["action": "post", "text": marker, "requestID": UUID().uuidString]
        let crossOrigin = try await call("chat", pass: pass, body: post, origin: "http://other.invalid"); XCTAssertEqual(crossOrigin.0, 403)
        let sent = try await call("chat", pass: pass, body: post); XCTAssertEqual(sent.0, 200)
        let list = try await call("chat", pass: pass)
        let messages = try JSONDecoder().decode([ChatMessage].self, from: list.1)
        XCTAssertEqual(messages.first?.name, "Sam"); XCTAssertEqual(messages.first?.color, "teal"); XCTAssertFalse(messages.first!.operatorMessage)
        XCTAssertTrue(messages.first!.ownMessage)
        let reacted = try await call("chat", pass: pass, body: ["action": "react", "id": 1, "reaction": "laugh", "author": 0]); XCTAssertEqual(reacted.0, 200)
        let reactions = try await call("chat", pass: pass)
        let ownReaction = try JSONDecoder().decode([ChatMessage].self, from: reactions.1)[0].reactions.first
        XCTAssertEqual(ownReaction?.reaction, .laugh); XCTAssertEqual(ownReaction?.selected, true)
        XCTAssertEqual(host.chatMessages[0].reactions.first?.selected, false, "A viewer cannot react as the operator")
        let invalidReaction = try await call("chat", pass: pass, body: ["action": "react", "id": 1, "reaction": "<script>"]); XCTAssertEqual(invalidReaction.0, 400)
        let crossReaction = try await call("chat", pass: pass, body: ["action": "react", "id": 1, "reaction": "heart"], origin: "http://other.invalid"); XCTAssertEqual(crossReaction.0, 403)
        let clearedReaction = try await call("chat", pass: pass, body: ["action": "react", "id": 1, "reaction": NSNull()]); XCTAssertEqual(clearedReaction.0, 200)
        let state = try await call("state.json"); XCTAssertFalse(String(decoding: state.1, as: UTF8.self).contains(marker))
        let frame = try SessionChatTests.jpeg()
        post = ["action": "post", "text": "", "frame": frame.base64EncodedString(), "revision": 6, "requestID": UUID().uuidString]
        let stale = try await call("chat", pass: pass, body: post); XCTAssertEqual(stale.0, 400)
        session.state = .holding; host.update(session)
        post["revision"] = 7
        let hold = try await call("chat", pass: pass, body: post); XCTAssertEqual(hold.0, 400)
        session.state = .live; host.update(session); host.setChatFramePermission(true)
        try host.postChat(text: "Operator frame", replyTo: nil, frame: frame, revision: 7, token: token, name: "DigiTech", color: .orange, requestID: UUID().uuidString)
        XCTAssertTrue(host.chatMessages.last!.operatorMessage)
        let imageID = host.chatMessages.last!.id
        let image = try await call("chat/frame/\(imageID)", pass: pass); XCTAssertEqual(image.0, 200)
        host.setChatFramePermission(false)
        XCTAssertThrowsError(try host.postChat(text: "Late frame", replyTo: nil, frame: frame, revision: 7, token: token, name: "DigiTech", color: .orange, requestID: UUID().uuidString), "An immediate source-switch gate rejects the old revision before runtime changes")
        let forbiddenRemoval = try await call("chat", pass: pass, body: ["action": "remove", "id": imageID]); XCTAssertEqual(forbiddenRemoval.0, 400)
        host.removeChat(id: imageID, token: token)
        XCTAssertNil(host.chatFrame(id: imageID))
        let deletedImage = try await call("chat/frame/\(imageID)", pass: pass); XCTAssertEqual(deletedImage.0, 404)
        XCTAssertTrue(host.remove(number: number))
        let removed = try await call("chat", pass: pass); XCTAssertEqual(removed.0, 403)
        let removedImage = try await call("chat/frame/\(imageID)", pass: pass); XCTAssertEqual(removedImage.0, 403)
        session.token = "new-token"; host.update(session); XCTAssertTrue(host.chatMessages.isEmpty)
        XCTAssertThrowsError(try host.postChat(text: "Old window", replyTo: nil, frame: nil, revision: 7, token: token, name: "DigiTech", color: .orange, requestID: UUID().uuidString))
        host.stop(); XCTAssertTrue(host.chatMessages.isEmpty)
    }
}
