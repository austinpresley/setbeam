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
    func testVideoAndUnknownTracksNeverEstablishAudio() {
        XCTAssertFalse(MediaTracks.hasAudio(["H264", "H265", "unknown"]))
        XCTAssertFalse(MediaTracks.hasAudio([]))
        XCTAssertTrue(MediaTracks.hasAudio(["H264", "Opus"]))
        XCTAssertTrue(MediaTracks.hasAudio(["H265", "MPEG4Audio"]))
    }
}
