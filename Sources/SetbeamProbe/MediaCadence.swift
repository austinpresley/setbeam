import Foundation
import SetbeamCore

/// Bounds for the generated codec fixtures, independent of network delivery time.
enum MediaCadence {
    static func fixtureJitter(_ timestamps: [Double], rate: Double) throws -> Double {
        guard rate.isFinite, rate > 0, timestamps.count > 1,
              timestamps.allSatisfy(\.isFinite) else {
            throw SetbeamError.runtime("The cadence fixture has no measurable timeline.")
        }
        let differences = zip(timestamps.dropFirst(), timestamps).map(-)
        let jitter = differences.map { abs($0 - 1 / rate) }.max() ?? 0
        // A bad fixture must fail, rather than make the relay's tolerance arbitrarily large.
        guard differences.allSatisfy({ $0 > 0 }), jitter < 0.02 / rate else {
            throw SetbeamError.runtime("The cadence fixture itself has an irregular timeline: \(jitter) seconds of jitter.")
        }
        return jitter
    }

    static func steadyFrames(_ timestamps: [Double], reorderDepth: Int) -> [Double] {
        // Read reorder depth from the completed decode, not the initial stream probe:
        // has_b_frames can still be zero before the decoder has seen its first B picture.
        let start = (timestamps.first ?? 0) + 2
        return Array(timestamps.drop(while: { $0 < start }).dropLast(max(1, reorderDepth + 1)))
    }

    static func maximumGap(rate: Double, sourceJitter: Double, loopAudioPadding: Double) -> Double {
        let gap = loopAudioPadding > 0 ? max(1.5 / rate, 1 / rate + loopAudioPadding + 0.001) : 1.5 / rate
        // Keep the existing half-frame allowance. Account only for measured fixture
        // jitter and rounding at each end through RTP's 90 kHz clock and microsecond JSON.
        return gap + sourceJitter + 2 / 90_000.0 + 2 / 1_000_000.0
    }
}
