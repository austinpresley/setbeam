import Foundation
import Darwin

// This process owns the helper's group and watches the originating app. A parent
// Force Quit closes every media listener without requiring app cleanup code.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3, let parent = Int32(arguments[0]), arguments[1] == "--", arguments[2].hasPrefix("/") else { exit(64) }
let group = getpgrp()
guard group == getpid(), getppid() == parent else { exit(71) }

func stopOrphanedGroup(_ group: pid_t) {
    kill(-group, SIGTERM)
    Thread.sleep(forTimeInterval: 1)
    kill(-group, SIGKILL)
}

// The helper receives TERM normally. The supervisor waits for it, then exits too.
signal(SIGTERM, SIG_IGN)
var attributes: posix_spawnattr_t?
posix_spawnattr_init(&attributes)
var defaults = sigset_t(); sigemptyset(&defaults); sigaddset(&defaults, SIGTERM)
posix_spawnattr_setsigdefault(&attributes, &defaults)
posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))
let argv = Array(arguments.dropFirst(2)).map { strdup($0) } + [nil]
var child: pid_t = 0
let result = argv.withUnsafeBufferPointer { posix_spawn(&child, arguments[2], nil, &attributes, $0.baseAddress!, environ) }
argv.forEach { free($0) }; posix_spawnattr_destroy(&attributes)
guard result == 0 else { fputs("Media helper could not start.\n", stderr); exit(70) }
let parentExit = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: DispatchQueue.global(qos: .userInitiated))
parentExit.setEventHandler { stopOrphanedGroup(group) }
parentExit.resume()
// The originating app may have exited between the first check and watching it.
if getppid() != parent { stopOrphanedGroup(group) }
var status: Int32 = 0
while waitpid(child, &status, 0) < 0 { if errno != EINTR { exit(71) } }
// No descendants may survive a helper that has exited.
kill(-group, SIGTERM)
let capacity = max(16, Int(proc_listpgrppids(group, nil, 0)) + 16)
var members = [pid_t](repeating: 0, count: capacity)
let count = members.withUnsafeMutableBytes { proc_listpgrppids(group, $0.baseAddress, Int32($0.count)) }
for member in members.prefix(max(0, Int(count))) where member > 0 && member != group && getpgid(member) == group {
    kill(member, SIGKILL)
}
parentExit.cancel()
if status & 0x7f == 0 { exit((status >> 8) & 0xff) }
exit(128 + (status & 0x7f))
