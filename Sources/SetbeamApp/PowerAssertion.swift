import Foundation
import IOKit.pwr_mgt

/// Holds one IOKit power assertion only while its condition is true.
@MainActor final class PowerAssertion {
    private let type: String
    private let reason: String
    private let create: (String, String) -> IOPMAssertionID?
    private let release: (IOPMAssertionID) -> Void
    private var assertion: IOPMAssertionID?

    init(type: String, reason: String,
         create: @escaping (String, String) -> IOPMAssertionID? = PowerAssertion.systemCreate,
         release: @escaping (IOPMAssertionID) -> Void = { IOPMAssertionRelease($0) }) {
        self.type = type; self.reason = reason; self.create = create; self.release = release
    }

    var isHeld: Bool { assertion != nil }

    /// Returns true when the held state changed.
    @discardableResult func hold(_ wanted: Bool) -> Bool {
        if wanted, assertion == nil { assertion = create(type, reason); return assertion != nil }
        if !wanted, let current = assertion { release(current); assertion = nil; return true }
        return false
    }

    nonisolated static func systemCreate(_ type: String, _ reason: String) -> IOPMAssertionID? {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }
}
