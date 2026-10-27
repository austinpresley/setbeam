import Foundation

/// A private, size-bounded timeline of session transitions for diagnosing on-set failures
/// after the fact. Entries are JSON lines; every string value passes through Redaction.
/// Nothing is written until a directory is configured.
public final class SessionLog: @unchecked Sendable {
    public static let shared = SessionLog()

    private let lock = NSLock()
    private let maxBytes: Int
    private let keep: Int
    private var directory: URL?
    private let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Rotates the current file at `maxBytes`, keeping `keep` older files.
    public init(maxBytes: Int = 1_000_000, keep: Int = 3) {
        self.maxBytes = maxBytes; self.keep = keep
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Setbeam", isDirectory: true)
    }

    public func configure(directory: URL?) {
        lock.withLock { self.directory = directory }
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public var currentFile: URL? { lock.withLock { directory?.appendingPathComponent("session.log") } }

    public func record(_ event: String, _ fields: [String: Any] = [:]) {
        var entry: [String: Any] = [:]
        for (key, value) in fields {
            switch value {
            case let text as String: entry[key] = Redaction.text(text)
            case let flag as Bool: entry[key] = flag
            case let number as Int: entry[key] = number
            case let number as Double: entry[key] = NSDecimalNumber(string: String(format: "%.3f", number))
            default: entry[key] = Redaction.text(String(describing: value))
            }
        }
        lock.lock(); defer { lock.unlock() }
        guard let directory else { return }
        entry["time"] = timestamps.string(from: Date()); entry["event"] = event
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let file = directory.appendingPathComponent("session.log")
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size > 0, size + line.count > maxBytes { rotate(in: directory) }
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    private func rotate(in directory: URL) {
        let manager = FileManager.default
        func name(_ index: Int) -> URL { directory.appendingPathComponent(index == 0 ? "session.log" : "session.\(index).log") }
        try? manager.removeItem(at: name(keep))
        for index in stride(from: keep - 1, through: 0, by: -1) where manager.fileExists(atPath: name(index).path) {
            try? manager.moveItem(at: name(index), to: name(index + 1))
        }
    }
}
