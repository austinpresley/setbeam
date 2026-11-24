import Darwin
import SetbeamCore

enum SoakProcess {
    static func footprint(_ pid: pid_t) throws -> UInt64 {
        var usage = rusage_info_v0()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
        }
        guard status == 0 else { throw SetbeamError.runtime("Could not read physical footprint for PID \(pid): errno \(errno).") }
        return usage.ri_phys_footprint
    }

    static func children(_ parent: pid_t) throws -> [pid_t] {
        var children = [pid_t](repeating: 0, count: 64)
        let size = Int32(children.count * MemoryLayout<pid_t>.size)
        let count = children.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, size) }
        guard count >= 0, count < children.count else { throw SetbeamError.runtime("Could not enumerate all children of PID \(parent).") }
        return Array(children.prefix(Int(count))).filter { $0 > 0 }
    }

    static func descendants(_ parent: pid_t) throws -> [pid_t] {
        let direct = try children(parent)
        return try direct + direct.flatMap { try descendants($0) }
    }
}
