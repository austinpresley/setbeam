import Foundation
import Darwin

/// A bounded video pipe that drains on writability, independently of capture cadence.
/// Append and close run on the supplied capture queue. Failure closes the owned pipe.
final class VideoPipeWriter {
    private let output: FileHandle
    private let queue: DispatchQueue
    private let maximumPendingBytes: Int
    private let onFailure: () -> Void
    private var pending = Data()
    private var writable: DispatchSourceWrite?
    private var closed = false

    init(output: FileHandle, queue: DispatchQueue, maximumPendingBytes: Int = 8 * 1024 * 1024,
         onFailure: @escaping () -> Void) {
        self.output = output; self.queue = queue; self.maximumPendingBytes = maximumPendingBytes; self.onFailure = onFailure
        let fd = output.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    }
    func append(_ bytes: Data) {
        guard !closed else { return }
        guard bytes.count <= maximumPendingBytes - pending.count else { fail(); return }
        pending.append(bytes); drain()
    }
    private func drain() {
        guard !closed else { return }
        while !pending.isEmpty {
            let count = pending.withUnsafeBytes { Darwin.write(output.fileDescriptor, $0.baseAddress!, $0.count) }
            if count > 0 { pending.removeFirst(count) }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && errno == EAGAIN {
                if writable == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: output.fileDescriptor, queue: queue)
                    source.setEventHandler { [weak self] in self?.drain() }
                    writable = source; source.resume()
                }
                return
            } else { fail(); return }
        }
        // A permanently writable empty pipe must not spin the capture queue.
        writable?.cancel(); writable = nil
    }
    private func fail() { close(); onFailure() }
    func close() {
        guard !closed else { return }
        closed = true; writable?.cancel(); writable = nil; pending.removeAll()
        try? output.close()
    }
    deinit { writable?.cancel(); try? output.close() }
}
