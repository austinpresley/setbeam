import XCTest
@testable import SetbeamCore

final class TransmitterRejoinPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testWaitsForASustainedAbsenceThenBacksOff() {
        var policy = TransmitterRejoinPolicy()
        let attempts = stride(from: 0.0, through: 200, by: 1).filter {
            policy.observe(enabled: true, transmitterVisible: false, pictureLive: false, blocked: false, now: at($0))
        }
        XCTAssertEqual(attempts, [15, 35, 75, 155])
    }

    func testOffByDefaultNeverJoins() {
        var policy = TransmitterRejoinPolicy()
        for second in 0...300 {
            XCTAssertFalse(policy.observe(enabled: false, transmitterVisible: false, pictureLive: false, blocked: false, now: at(Double(second))))
        }
    }

    func testReturningTransmitterOrPictureResetsTheWait() {
        var policy = TransmitterRejoinPolicy()
        XCTAssertFalse(policy.observe(enabled: true, transmitterVisible: false, pictureLive: false, blocked: false, now: at(0)))
        XCTAssertTrue(policy.observe(enabled: true, transmitterVisible: false, pictureLive: false, blocked: false, now: at(15)))
        XCTAssertFalse(policy.observe(enabled: true, transmitterVisible: true, pictureLive: false, blocked: false, now: at(16)))
        // A fresh absence starts its own grace period and first-attempt delay.
        XCTAssertFalse(policy.observe(enabled: true, transmitterVisible: false, pictureLive: false, blocked: false, now: at(17)))
        XCTAssertFalse(policy.observe(enabled: true, transmitterVisible: false, pictureLive: false, blocked: false, now: at(31)))
        XCTAssertTrue(policy.observe(enabled: true, transmitterVisible: false, pictureLive: false, blocked: false, now: at(32)))
        XCTAssertFalse(policy.observe(enabled: true, transmitterVisible: false, pictureLive: true, blocked: false, now: at(33)))
    }

    func testBlockedSessionsWaitWithoutConsumingAttempts() {
        var policy = TransmitterRejoinPolicy()
        for second in 0...60 {
            XCTAssertFalse(policy.observe(enabled: true, transmitterVisible: false, pictureLive: false, blocked: true, now: at(Double(second))))
        }
        XCTAssertTrue(policy.observe(enabled: true, transmitterVisible: false, pictureLive: false, blocked: false, now: at(61)))
    }
}
