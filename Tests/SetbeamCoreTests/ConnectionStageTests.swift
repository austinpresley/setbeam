import XCTest
@testable import SetbeamCore

final class ConnectionStageTests: XCTestCase {
    func testTransmitterProgressRequiresDiscoveryAcknowledgementAndFreshVideo() {
        func stage(server: Bool = true, fresh: Bool = false, found: Bool = false,
                   running: Bool = false, acknowledged: Bool = false) -> ConnectionStage {
            ConnectionStage.resolve(serverReady: server, sourceFresh: fresh, isTransmitter: true,
                transmitterFound: found, receiverRunning: running, connectionAcknowledged: acknowledged)
        }
        XCTAssertEqual(stage(server: false), .preparingMonitor)
        XCTAssertEqual(stage(), .findingTransmitter)
        XCTAssertEqual(stage(found: true), .connectingTransmitter)
        XCTAssertEqual(stage(found: true, running: true), .connectingTransmitter)
        XCTAssertEqual(stage(running: true, acknowledged: true), .waitingForPicture)
        XCTAssertEqual(stage(fresh: true, running: true, acknowledged: true), .openingPreview)

        // Old acknowledgements and frames cannot complete a new connection after a loss.
        XCTAssertEqual(stage(acknowledged: true), .findingTransmitter)
        XCTAssertEqual(stage(server: false, fresh: true, acknowledged: true), .preparingMonitor)
        XCTAssertEqual(stage(found: true, acknowledged: true), .connectingTransmitter)
    }

    func testOtherInputsDoNotClaimTransmitterDiscoveryOrHandshake() {
        let kinds: [InputKind] = [.sample, .capture, .network, .incoming]
        for kind in kinds {
            XCTAssertEqual(ConnectionStage.steps(for: kind), [.preparingMonitor, .waitingForPicture, .openingPreview])
        }
        XCTAssertEqual(ConnectionStage.resolve(serverReady: true, sourceFresh: false, isTransmitter: false,
            transmitterFound: false, receiverRunning: false, connectionAcknowledged: false), .waitingForPicture)
        XCTAssertEqual(ConnectionStage.resolve(serverReady: true, sourceFresh: true, isTransmitter: false,
            transmitterFound: false, receiverRunning: false, connectionAcknowledged: false), .openingPreview)
    }
}
