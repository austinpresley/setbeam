import Foundation

/// Decides when an opt-in transmitter Wi-Fi rejoin may run. macOS often moves to another
/// known network while a transmitter is off and does not return on its own.
public struct TransmitterRejoinPolicy: Sendable {
    /// The transmitter must stay missing this long before Setbeam touches Wi-Fi.
    public static let grace: TimeInterval = 15
    private var missingSince: Date?
    private var nextAttempt = Date.distantPast
    private var failures = 0

    public init() {}

    /// Returns true when an association attempt should start now. `blocked` covers a running
    /// attempt, a pending operator action, or sharing that depends on the current Wi-Fi network.
    public mutating func observe(enabled: Bool, transmitterVisible: Bool, pictureLive: Bool, blocked: Bool, now: Date) -> Bool {
        if transmitterVisible || pictureLive { self = TransmitterRejoinPolicy(); return false }
        guard enabled else { missingSince = nil; return false }
        let since = missingSince ?? now
        missingSince = since
        guard !blocked, now.timeIntervalSince(since) >= Self.grace, now >= nextAttempt else { return false }
        failures += 1
        nextAttempt = now.addingTimeInterval(min(120, 20 * pow(2, Double(failures - 1))))
        return true
    }
}
