import Darwin
import Foundation

/// The test runner can read the sample share's bearer link while that share is active.
final class IntegrationSessionFile {
    private let destination: URL
    private var identity: (device: dev_t, inode: ino_t)?

    init?(arguments: [String]) {
        guard arguments.contains("--integration-demo"), let index = arguments.firstIndex(of: "--session-file"),
              arguments.indices.contains(index + 1), !arguments[index + 1].isEmpty else { return nil }
        destination = URL(fileURLWithPath: arguments[index + 1])
    }

    func write(_ data: Data) throws {
        var template = Array(destination.deletingLastPathComponent()
            .appendingPathComponent(".setbeam-session-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw Self.fileError() }
        let path = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { unlink(path) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Self.fileError() }
        try file.write(contentsOf: data)
        try file.close()
        guard rename(path, destination.path) == 0 else { throw Self.fileError() }
        identity = (info.st_dev, info.st_ino)
    }

    func clear() {
        guard let identity else { return }
        var info = stat()
        if lstat(destination.path, &info) == 0, info.st_dev == identity.device, info.st_ino == identity.inode,
           unlink(destination.path) != 0 { return }
        self.identity = nil
    }

    private static func fileError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
