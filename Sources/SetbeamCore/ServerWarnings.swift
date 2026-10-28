import Foundation

/// MediaMTX writes warnings, such as reader discards and rejected input, to stdout. The first
/// line of each kind is recorded at once. Repeats within the interval are counted and reported
/// with a later line, so a sustained overload cannot fill the bounded session log.
final class ServerWarnings: @unchecked Sendable {
    struct Entry: Equatable { let message: String; let repeats: Int }
    private struct Kind { var recorded: Date; var message: String; var repeats: Int }
    private let lock = NSLock()
    private let interval: TimeInterval
    private var partial = ""
    private var kinds: [String: Kind] = [:]

    init(interval: TimeInterval = 10) { self.interval = interval }

    func consume(_ text: String, now: Date = Date()) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        partial += text
        var result: [Entry] = []
        while let end = partial.firstIndex(of: "\n") {
            let line = partial[..<end]; partial.removeSubrange(...end)
            guard let level = line.range(of: " WAR ") ?? line.range(of: " ERR ") else { continue }
            let message = String(line[line.index(after: level.lowerBound)...])
            // Session IDs and counts vary between otherwise identical warnings.
            let kind = message.replacing(#/[0-9a-f]{8}|[0-9]+/#, with: "#")
            if var previous = kinds[kind], now.timeIntervalSince(previous.recorded) < interval {
                previous.message = message; previous.repeats += 1; kinds[kind] = previous
            } else {
                result.append(Entry(message: message, repeats: kinds[kind]?.repeats ?? 0))
                kinds[kind] = Kind(recorded: now, message: message, repeats: 0)
            }
        }
        if partial.count > 4096 { partial = String(partial.suffix(4096)) }
        return result
    }

    /// Repeats whose interval has elapsed without another line to carry them.
    func due(now: Date = Date()) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        var result: [Entry] = []
        for (kind, value) in kinds where value.repeats > 0 && now.timeIntervalSince(value.recorded) >= interval {
            result.append(Entry(message: value.message, repeats: value.repeats))
            kinds[kind] = Kind(recorded: now, message: value.message, repeats: 0)
        }
        return result
    }
}
