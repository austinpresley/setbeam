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
    private var consumed = 0
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
        let remaining = pending.count - consumed
        guard bytes.count <= maximumPendingBytes - remaining else { fail(); return }
        if consumed > 0 {
            // Data.removeFirst advances its start index while keeping the consumed allocation.
            // Appending after every write then retains the shoot's cumulative encoded bytes,
            // even when pending.count is zero. Copy only the unsent tail before appending.
            pending = pending.withUnsafeBytes { Data(bytes: $0.baseAddress!.advanced(by: consumed), count: remaining) }
            consumed = 0
        }
        pending.append(bytes); drain()
    }
    private func drain() {
        guard !closed else { return }
        while consumed < pending.count {
            let count = pending.withUnsafeBytes { Darwin.write(output.fileDescriptor, $0.baseAddress!.advanced(by: consumed), $0.count - consumed) }
            if count > 0 { consumed += count }
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
        pending = Data(); consumed = 0
        // A permanently writable empty pipe must not spin the capture queue.
        writable?.cancel(); writable = nil
    }
    private func fail() { close(); onFailure() }
    func close() {
        guard !closed else { return }
        closed = true; writable?.cancel(); writable = nil; pending = Data(); consumed = 0
        try? output.close()
    }
    deinit { writable?.cancel(); try? output.close() }
}
