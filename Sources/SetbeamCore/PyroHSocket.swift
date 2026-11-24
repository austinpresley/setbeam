import Darwin
import Foundation

/// Discovery and playback open their upstream sockets through the same interface and local IPv4 binding.
enum PyroHSocket {
    static let addressSize = socklen_t(MemoryLayout<sockaddr_in>.size)

    static func address(_ host: String, port: UInt16 = 0) -> sockaddr_in? {
        var value = sockaddr_in()
        value.sin_len = UInt8(addressSize)
        value.sin_family = sa_family_t(AF_INET)
        value.sin_port = port.bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &value.sin_addr) }) == 1 else { return nil }
        return value
    }

    static func configure(_ fd: Int32) -> Bool {
        var yes: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0
            && fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
            && fcntl(fd, F_SETFL, O_NONBLOCK) == 0
    }

    static func bind(_ fd: Int32, _ address: inout sockaddr_in) -> Bool {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, addressSize) == 0 }
        }
    }

    static func connect(_ route: PyroHRoute, deadline: UInt64, cancelled: () -> Bool) -> Int32? {
        guard !cancelled(),
              var local = address(route.network.address),
              var remote = address(route.network.router, port: route.port) else { return nil }
        var index = if_nametoindex(route.network.interface)
        guard index != 0 else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var keep = false
        defer { if !keep { close(fd) } }
        guard configure(fd),
              setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout.size(ofValue: index))) == 0,
              bind(fd, &local), !cancelled() else { return nil }
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, addressSize) }
        }
        guard connected == 0 || errno == EINPROGRESS,
              wait(fd, events: Int16(POLLOUT), deadline: deadline, cancelled: cancelled) else { return nil }
        var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return nil }
        keep = true
        return fd
    }

    static func wait(_ fd: Int32, events: Int16, deadline: UInt64, cancelled: () -> Bool) -> Bool {
        while !cancelled() {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            var value = pollfd(fd: fd, events: events, revents: 0)
            let count = poll(&value, 1, Int32(min(50, max(1, (deadline - now) / 1_000_000))))
            if count > 0 { return value.revents & (events | Int16(POLLHUP)) != 0 && value.revents & Int16(POLLERR | POLLNVAL) == 0 }
            if count < 0 && errno != EINTR { return false }
        }
        return false
    }
}
