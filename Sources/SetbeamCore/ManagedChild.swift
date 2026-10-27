import Foundation
import Darwin

/// A direct executable in its own process group. No shell or global process matching.
public final class ManagedChild: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var status: Int32?
    private let output = Pipe()
    private let errors = Pipe()
    private var stderrText = ""
    private var progressText = ""
    private var outputText = ""
    private var lastFrame: Int = -1
    private var frameTime: Date?
    public let name: String

    public init(name: String, executable: URL, arguments: [String], directory: URL, onOutput: (@Sendable (Data) -> Void)? = nil, standardInput: FileHandle? = nil) throws {
        self.name = name
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        if let standardInput {
            posix_spawn_file_actions_adddup2(&actions, standardInput.fileDescriptor, STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errors.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, output.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, errors.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let environment = ProcessInfo.processInfo.environment
        let retained = ["HOME", "USER", "LOGNAME", "__CF_USER_TEXT_ENCODING", "XPC_FLAGS", "XPC_SERVICE_NAME"]
        var values = retained.compactMap { key in environment[key].map { "\(key)=\($0)" } }
        values += ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR=\(directory.path)", "LC_ALL=C"]
        let supervisor = executable.deletingLastPathComponent().appendingPathComponent("setbeam-supervisor")
        let supervised = FileManager.default.isExecutableFile(atPath: supervisor.path)
        let launched = supervised ? supervisor : executable
        let launchArguments = supervised ? [String(getpid()), "--", executable.path] + arguments : arguments
        let argv = ([launched.path] + launchArguments).map { strdup($0) } + [nil]
        let envp = values.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { argumentPointer in
            envp.withUnsafeBufferPointer { environmentPointer in
                posix_spawn(&child, launched.path, &actions, &attributes, argumentPointer.baseAddress!, environmentPointer.baseAddress!)
            }
        }
        guard result == 0 else { throw SetbeamError.runtime("Could not start \(name): \(String(cString: strerror(result)))") }
        pid = child
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if let onOutput { onOutput(data) }
            else { self?.consumeProgress(String(decoding: data, as: UTF8.self)) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.consumeError(String(decoding: data, as: UTF8.self))
        }
    }

    private func consumeError(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        stderrText = String((stderrText + Redaction.text(text)).suffix(12_000))
    }
    private func consumeProgress(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        outputText = String((outputText + text).suffix(48_000))
        progressText += text
        while let end = progressText.firstIndex(of: "\n") {
            let line = String(progressText[..<end]); progressText.removeSubrange(...end)
            if line.hasPrefix("frame="), let frame = Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces)), frame > 0, frame > lastFrame {
                lastFrame = frame; frameTime = Date()
            }
        }
        if progressText.count > 4096 { progressText = String(progressText.suffix(4096)) }
    }
    public var recentError: String { lock.lock(); defer { lock.unlock() }; return stderrText }
    public var capturedOutput: String { lock.lock(); defer { lock.unlock() }; return Redaction.text(outputText) }
    public var terminationStatus: Int32? { lock.lock(); defer { lock.unlock() }; return status }
    public var lastVideoFrameAt: Date? { lock.lock(); defer { lock.unlock() }; return frameTime }
    public var processID: pid_t { lock.lock(); defer { lock.unlock() }; return pid }
    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        guard pid > 0 else { return false }
        var code: Int32 = 0
        let result = waitpid(pid, &code, WNOHANG)
        if result == pid || result == -1 {
            // A killed supervisor may leave its helper in this owned group.
            if result == pid { kill(-pid, SIGKILL) }
            status = code; pid = 0; return false
        }
        return true
    }
    public func stop(timeout: TimeInterval = 2) {
        let child = processID
        guard child > 0 else { return }
        kill(-child, SIGTERM)
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
        if isRunning {
            kill(-child, SIGKILL)
            lock.lock(); var code: Int32 = 0; _ = waitpid(child, &code, 0); status = code; pid = 0; lock.unlock()
        }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
    }
    deinit { stop(timeout: 0.2) }
}
