import XCTest
@testable import SetbeamCore

final class SetupCheckTests: XCTestCase {
    func testRequiresOtherDeviceAndAudibleConfirmationWhenSoundIsExpected() {
        let localOnly = SetupCheck(picture: true, viewingAddress: true, otherDevicePlaying: false, expectsAudio: false, outgoingAudio: true, soundConfirmed: false)
        XCTAssertFalse(localOnly.passed)
        let trackOnly = SetupCheck(picture: true, viewingAddress: true, otherDevicePlaying: true, expectsAudio: true, outgoingAudio: true, soundConfirmed: false)
        XCTAssertFalse(trackOnly.passed)
        let noTrack = SetupCheck(picture: true, viewingAddress: true, otherDevicePlaying: true, expectsAudio: true, outgoingAudio: false, soundConfirmed: true)
        XCTAssertFalse(noTrack.passed)
        let audible = SetupCheck(picture: true, viewingAddress: true, otherDevicePlaying: true, expectsAudio: true, outgoingAudio: true, soundConfirmed: true)
        XCTAssertTrue(audible.passed)
        let silentByChoice = SetupCheck(picture: true, viewingAddress: true, otherDevicePlaying: true, expectsAudio: false, outgoingAudio: false, soundConfirmed: false)
        XCTAssertTrue(silentByChoice.passed)
    }
    func testSetupRequiresAnExplicitSoundExpectation() {
        let undecided = SetupCheck(picture: true, viewingAddress: true, otherDevicePlaying: true,
                                   expectsAudio: nil, outgoingAudio: false, soundConfirmed: false)
        XCTAssertFalse(undecided.passed)
    }

    func testSoundEvidenceMatchesTheSameLinkRevisionRouteAndRemoteSessions() {
        func report(_ number: Int, revision: Int = 4, local: Bool = false, admission: ViewerAdmission = .admitted,
                    playing: Bool = true) -> ViewerActivity {
            ViewerActivity(id: "viewer-\(number)", label: "Browser", playing: playing, onThisMac: local, revision: revision,
                           lastSeen: .distantPast, number: number, name: nil, health: .playing, admission: admission)
        }
        let tested = SetupCheckOutput(link: 1, revision: 4, route: "10.0.0.2", reports: [report(1)])
        let mixed = SetupCheckOutput(link: 1, revision: 4, route: "10.0.0.2", reports: [
            report(1), report(2, revision: 3), report(3, local: true), report(4, admission: .pending), report(5, playing: false)
        ])
        XCTAssertEqual(mixed.viewerCount, 1)
        XCTAssertEqual(mixed, tested)
        XCTAssertNotEqual(SetupCheckOutput(link: 2, revision: 4, route: "10.0.0.2", reports: [report(1)]), tested)
        XCTAssertNotEqual(SetupCheckOutput(link: 1, revision: 5, route: "10.0.0.2", reports: [report(1, revision: 5)]), tested)
        XCTAssertNotEqual(SetupCheckOutput(link: 1, revision: 4, route: "10.0.0.3", reports: [report(1)]), tested)
        XCTAssertNotEqual(SetupCheckOutput(link: 1, revision: 4, route: "10.0.0.2", reports: [report(6)]), tested)
    }

    func testVideoAndUnknownTracksNeverEstablishAudio() {
        XCTAssertFalse(MediaTracks.hasAudio(["H264", "H265", "unknown"]))
        XCTAssertFalse(MediaTracks.hasAudio([]))
        XCTAssertTrue(MediaTracks.hasAudio(["H264", "Opus"]))
        XCTAssertTrue(MediaTracks.hasAudio(["H265", "MPEG4Audio"]))
    }
}
