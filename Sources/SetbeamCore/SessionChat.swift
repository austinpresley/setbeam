import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ChatReaction: String, Codable, Sendable, CaseIterable {
    case heart, thumbsUp, laugh, surprised, sad, emphasis
    public var emoji: String {
        switch self {
        case .heart: "❤️"
        case .thumbsUp: "👍"
        case .laugh: "😂"
        case .surprised: "😮"
        case .sad: "😢"
        case .emphasis: "‼️"
        }
    }
    public var label: String {
        switch self {
        case .heart: "Love"
        case .thumbsUp: "Like"
        case .laugh: "Laugh"
        case .surprised: "Surprise"
        case .sad: "Sad"
        case .emphasis: "Emphasis"
        }
    }
}

public struct ChatReactionSummary: Codable, Sendable, Equatable {
    public let reaction: ChatReaction
    public let count: Int
    public let selected: Bool
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let authorNumber: Int
    public let name: String
    public let color: String
    public let operatorMessage: Bool
    public let text: String
    public let sentAt: Double
    public let replyTo: Int?
    public let hasFrame: Bool
    public let hadFrame: Bool?
    public let sampleFrame: Bool
    public let likes: Int
    public let liked: Bool
    public let ownMessage: Bool
    public let reactions: [ChatReactionSummary]
}

struct ChatAuthor {
    let number: Int, name: String, color: PointerColor
    var isOperator: Bool { number == 0 }
}

enum ChatDraftError: String, LocalizedError {
    case replyUnavailable, frameStale

    var errorDescription: String? {
        switch self {
        case .replyUnavailable: "The original message is no longer available. Cancel the reply to send without it."
        case .frameStale: "The feed changed. Remove the frame or capture a new one before sending."
        }
    }
}

/// Session-only bounded content. The gateway lock owns every access; no content is logged or saved.
struct SessionChat {
    static let maxMessages = 100, maxText = 1200, maxFrameBytes = 131_072, maxFrames = 8
    // Bound encoded histories below Android's 1 MiB HTTP cap, including JSON metadata and escaping.
    static let maxTextBytes = 6144, maxNameBytes = 160, maxEncodedStringBytes = 8192
    // Keep receipts after deletion and history eviction. Reject new posts at the session cap
    // so a successful request ID can never become sendable again in this session.
    static let maxReceipts = 65_536
    struct Entry {
        let id: Int, author: ChatAuthor, text: String, sentAt: Date, replyTo: Int?, hadFrame: Bool, sampleFrame: Bool
        var frame: Data?
        var reactions: [Int: ChatReaction] = [:]
    }
    private(set) var entries: [Entry] = []
    private var nextID = 1
    private struct RequestKey: Hashable { let author: Int; let id: String }
    private var receipts: [RequestKey: Int] = [:]
    private struct Budget { var tokens: Double; var updatedAt: Date }
    private var budgets: [Int: Budget] = [:]
    private var reactionBudgets: [Int: Budget] = [:]
    var lastMessageID: Int { nextID - 1 }
    mutating func reset() { self = Self() }
    static func clean(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter {
            (!CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t") &&
            !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value) && $0.value != 0x200E && $0.value != 0x200F
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func receipt(author: Int, requestID: String) -> Int? {
        receipts[RequestKey(author: author, id: requestID)]
    }
    @discardableResult
    mutating func post(author: ChatAuthor, text: String, replyTo: Int?, frame: Data?, requestID: String, now: Date, sampleFrame: Bool = false) throws -> Int {
        guard (16...64).contains(requestID.utf8.count), requestID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { throw SetbeamError.invalidSource("Retry sending this message.") }
        let key = RequestKey(author: author.number, id: requestID)
        if let id = receipts[key] { return id }
        guard receipts.count < Self.maxReceipts else { throw SetbeamError.unavailable("This chat has reached its session message limit.") }
        let text = Self.clean(text)
        guard text.count <= Self.maxText, !text.isEmpty || frame != nil else { throw SetbeamError.invalidSource("Write a message of up to 1,200 characters or attach a frame.") }
        guard text.utf8.count <= Self.maxTextBytes else { throw SetbeamError.invalidSource("Shorten this message. It exceeds the chat text size limit.") }
        guard replyTo == nil || entries.contains(where: { $0.id == replyTo }) else { throw ChatDraftError.replyUnavailable }
        guard frame.map({ $0.count <= Self.maxFrameBytes }) ?? true else { throw SetbeamError.invalidSource("This frame is too large. Capture it again.") }
        var name = ""
        var nameBytes = 0
        for character in Self.clean(author.name).prefix(40) {
            nameBytes += String(character).utf8.count
            guard nameBytes <= Self.maxNameBytes else { break }
            name.append(character)
        }
        let boundedAuthor = ChatAuthor(number: author.number, name: name.isEmpty ? "Viewer \(author.number)" : name, color: author.color)
        let encoder = JSONEncoder()
        guard try encoder.encode(text).count + encoder.encode(boundedAuthor.name).count <= Self.maxEncodedStringBytes else {
            throw SetbeamError.invalidSource("Shorten this message. It exceeds the chat text size limit.")
        }
        try Self.rateLimit(author.number, now: now, budgets: &budgets)
        let id = nextID
        entries.append(Entry(id: id, author: boundedAuthor, text: text, sentAt: now, replyTo: replyTo, hadFrame: frame != nil, sampleFrame: sampleFrame, frame: frame))
        receipts[key] = id
        nextID += 1
        if entries.count > Self.maxMessages { entries.removeFirst(entries.count - Self.maxMessages) }
        let frames = entries.indices.filter { entries[$0].frame != nil }
        for index in frames.prefix(max(0, frames.count - Self.maxFrames)) { entries[index].frame = nil }
        return id
    }
    mutating func like(id: Int, author: Int, liked: Bool, now: Date) throws {
        // Older open pages still use heart likes. Removing a heart must not remove another reaction.
        guard let entry = entries.first(where: { $0.id == id }) else { throw SetbeamError.unavailable("This message is no longer available.") }
        if !liked, entry.reactions[author] != .heart { return }
        try react(id: id, author: author, reaction: liked ? .heart : nil, now: now)
    }
    mutating func react(id: Int, author: Int, reaction: ChatReaction?, now: Date) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw SetbeamError.unavailable("This message is no longer available.") }
        if entries[index].reactions[author] == reaction { return }
        if reaction != nil, entries[index].reactions[author] == nil, entries[index].reactions.count >= 128 {
            throw SetbeamError.unavailable("This message has reached its reaction limit.")
        }
        try Self.rateLimit(author, now: now, budgets: &reactionBudgets)
        entries[index].reactions[author] = reaction
    }
    private static func rateLimit(_ author: Int, now: Date, budgets: inout [Int: Budget]) throws {
        var budget = budgets[author] ?? Budget(tokens: 4, updatedAt: now)
        budget.tokens = min(4, budget.tokens + max(0, now.timeIntervalSince(budget.updatedAt)) * 2)
        budget.updatedAt = now
        guard budget.tokens >= 1 else { budgets[author] = budget; throw SetbeamError.unavailable("Wait a moment and try again.") }
        budget.tokens -= 1
        if budgets.count >= 128, budgets[author] == nil, let oldest = budgets.min(by: { $0.value.updatedAt < $1.value.updatedAt }) { budgets.removeValue(forKey: oldest.key) }
        budgets[author] = budget
    }
    func messages(for number: Int) -> [ChatMessage] {
        entries.map { ChatMessage(id: $0.id, authorNumber: $0.author.number, name: $0.author.name, color: $0.author.color.rawValue,
            operatorMessage: $0.author.isOperator, text: $0.text, sentAt: $0.sentAt.timeIntervalSince1970,
            replyTo: $0.replyTo, hasFrame: $0.frame != nil, hadFrame: $0.hadFrame, sampleFrame: $0.sampleFrame,
            likes: $0.reactions.values.filter { $0 == .heart }.count, liked: $0.reactions[number] == .heart,
            ownMessage: $0.author.number == number, reactions: summaries($0, for: number)) }
    }
    private func summaries(_ entry: Entry, for number: Int) -> [ChatReactionSummary] {
        ChatReaction.allCases.compactMap { reaction in
            let count = entry.reactions.values.filter { $0 == reaction }.count
            return count == 0 ? nil : ChatReactionSummary(reaction: reaction, count: count, selected: entry.reactions[number] == reaction)
        }
    }
    func frame(_ id: Int) -> Data? { entries.first { $0.id == id }?.frame }
    mutating func remove(_ id: Int) { entries.removeAll { $0.id == id } }

    /// Decode a bounded JPEG, reject decompression bombs and re-encode without metadata.
    static func sanitizedFrame(_ data: Data) throws -> Data {
        guard data.count <= maxFrameBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 1920, height <= 1920, width * height <= 2_073_600,
              width > 0 else { throw SetbeamError.invalidSource("Capture a new JPEG image from the feed.") }
        for maximum in [1280, 960, 640] {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximum, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false] as CFDictionary) else { continue }
            for quality in [0.65, 0.4, 0.2, 0.1] {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(destination), output.length <= maxFrameBytes { return output as Data }
            }
        }
        throw SetbeamError.invalidSource("The image could not be prepared. Capture it again at a smaller size.")
    }
}
