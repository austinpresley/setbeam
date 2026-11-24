import CoreFoundation
import Foundation

/// Optional inbound video observations for the operator's current viewer row.
public struct ViewerMeasurements: Sendable {
    static let freshFor: TimeInterval = 7

    public let width: Int?
    public let height: Int?
    public let framesPerSecond: Double?
    /// Cumulative count for the viewer's current inbound video stream.
    public let droppedFrames: Int?
    let sampledAt: Date

    init?(json: Any?, receivedAt: Date) {
        guard let fields = json as? [String: Any],
              let age = Self.number(fields["ageMs"], in: 0...(Self.freshFor * 1000)),
              age < Self.freshFor * 1000 else { return nil }
        sampledAt = receivedAt.addingTimeInterval(-age / 1000)
        let width = Self.integer(fields["width"], in: 1...16_384)
        let height = Self.integer(fields["height"], in: 1...16_384)
        self.width = height == nil ? nil : width
        self.height = width == nil ? nil : height
        framesPerSecond = Self.number(fields["fps"], in: 0...1_000)
        droppedFrames = Self.integer(fields["droppedFrames"], in: 0...9_007_199_254_740_991)
        guard self.width != nil || framesPerSecond != nil || droppedFrames != nil else { return nil }
    }

    private static func number(_ value: Any?, in range: ClosedRange<Double>) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              range.contains(number.doubleValue) else { return nil }
        return number.doubleValue
    }

    private static func integer(_ value: Any?, in range: ClosedRange<Double>) -> Int? {
        number(value, in: range).flatMap { Int(exactly: $0) }
    }
}
