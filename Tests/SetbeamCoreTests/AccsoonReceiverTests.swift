import XCTest
@testable import SetbeamCore

final class AccsoonReceiverTests: XCTestCase {
    func testStatisticsRemainConsistentWhileReceivingAndReadingDiagnostics() {
        let counters = AccsoonReceiveCounters()
        let initial = counters.snapshot
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            counters.add("udpPackets")
            counters.add("udpBytes", by: 1_200)
            _ = counters.snapshot
        }
        let received = counters.snapshot
        XCTAssertEqual(initial["udpPackets"], 0)
        XCTAssertEqual(received["udpPackets"], 1_000)
        XCTAssertEqual(received["udpBytes"], 1_200_000)
        XCTAssertEqual(received["rejectedUIDPackets"], 0)
        XCTAssertEqual(AccsoonReceiver().statistics, ["running": 0, "tcpConnected": 0])
    }

    func testFragmentsReorderWithoutAcknowledgingPastAnIncompleteMessage() throws {
        var assembler = AccsoonRTMSAssembler()
        XCTAssertTrue(try assembler.receive(fragment(id: 10, count: 2, index: 1, bytes: [3, 4]), now: 0).isEmpty)
        XCTAssertTrue(try assembler.receive(fragment(id: 11, bytes: [5, 6]), now: 0.01).isEmpty)
        XCTAssertTrue(assembler.acknowledgements.isEmpty)
        let missing = try XCTUnwrap(assembler.missingFragments(now: 0.11).first?.messages.first)
        XCTAssertEqual(missing.id, 10); XCTAssertEqual(missing.indices, [0])
        let complete = try assembler.receive(fragment(id: 10, count: 2, index: 0, bytes: [1, 2]), now: 0.2)
        XCTAssertEqual(complete.map(\.data), [Data([1, 2, 3, 4]), Data([5, 6])])
        XCTAssertEqual(assembler.acknowledgements.first?.message, 11)
        XCTAssertTrue(try assembler.receive(fragment(id: 10, bytes: [1]), now: 0.3).isEmpty)
        XCTAssertFalse(assembler.hasExpiredGap(now: 4))
    }

    func testWholeMessageLossRequestsRetransmissionAndHasABoundedDeadline() throws {
        var assembler = AccsoonRTMSAssembler()
        _ = try assembler.receive(fragment(id: 10, bytes: [10]), now: 0)
        XCTAssertTrue(try assembler.receive(fragment(id: 12, bytes: [12]), now: 1).isEmpty)
        XCTAssertEqual(assembler.acknowledgements.first?.message, 10)
        let missing = try XCTUnwrap(assembler.missingFragments(now: 1.1).first?.messages.first)
        XCTAssertEqual(missing.id, 11); XCTAssertTrue(missing.indices.isEmpty)
        XCTAssertFalse(assembler.hasExpiredGap(now: 3.9)); XCTAssertTrue(assembler.hasExpiredGap(now: 4.1))
        let complete = try assembler.receive(fragment(id: 11, bytes: [11]), now: 4.2)
        XCTAssertEqual(complete.map(\.data), [Data([11]), Data([12])])
        XCTAssertEqual(assembler.acknowledgements.first?.message, 12)
        XCTAssertFalse(assembler.hasExpiredGap(now: 10))
    }

    func testRecoveryDeadlineFollowsTheMovingWindowWhileFragmentsKeepArriving() throws {
        var assembler = AccsoonRTMSAssembler()
        _ = try assembler.receive(fragment(id: 10, count: 2, bytes: [1]), now: 0)
        for step in 0..<6 {
            let now = Double(step) * 0.8 + 0.1
            let id = UInt32(10 + step)
            // The next picture arrives before the preceding picture's retransmission.
            _ = try assembler.receive(fragment(id: id + 1, count: 2, bytes: [1]), now: now)
            let complete = try assembler.receive(fragment(id: id, count: 2, index: 1, bytes: [2]), now: now + 0.1)
            XCTAssertEqual(complete.count, 1)
            XCTAssertEqual(assembler.acknowledgements.first?.message, id)
            XCTAssertFalse(assembler.hasExpiredGap(now: now + 0.2))
        }
        // Genuine loss still expires once the newest blocking message stops recovering.
        XCTAssertTrue(assembler.hasExpiredGap(now: 7.2))
    }

    func testMalformedFragmentsAndHeadersDoNotBecomeMedia() throws {
        var assembler = AccsoonRTMSAssembler()
        XCTAssertTrue(try assembler.receive(fragment(id: 1, count: 0, bytes: [1]), now: 0).isEmpty)
        XCTAssertTrue(try assembler.receive(fragment(id: 1, count: 2, index: 2, bytes: [1]), now: 0).isEmpty)
        _ = try assembler.receive(fragment(id: 1, count: 2, index: 0, bytes: [1]), now: 0)
        XCTAssertTrue(try assembler.receive(fragment(id: 1, count: 3, index: 1, bytes: [2]), now: 0).isEmpty)
        XCTAssertEqual(try assembler.receive(fragment(id: 1, count: 2, index: 1, bytes: [2]), now: 0).first?.data, Data([1, 2]))
        var header = Data(repeating: 0, count: 24)
        put(UInt64(2_000_000), into: &header, at: 0); put(UInt32(265 | 0x400), into: &header, at: 8)
        put(UInt32(2), into: &header, at: 20); header.append(contentsOf: [0x26, 1])
        let media = try XCTUnwrap(AccsoonEncodedMessage(header))
        XCTAssertEqual(media.timestamp, 2_000_000); XCTAssertEqual(media.codec, 265)
        XCTAssertEqual(media.payload, Data([0x26, 1]))
        put(UInt32(100), into: &header, at: 20); XCTAssertNil(AccsoonEncodedMessage(header))
    }

    func testHEVCFragmentationPreservesNALHeadersSequenceAndRTPClock() throws {
        let nal = Data([0x26, 0x09]) + Data(repeating: 0x55, count: 3_000)
        var packetizer = AccsoonRTPPacketizer(payloadType: 96)
        let packets = try packetizer.hevc(Data([0, 0, 0, 1]) + nal, timestamp: 1_000_000)
        XCTAssertEqual(packets.count, 3)
        XCTAssertTrue(packets.allSatisfy { $0.count <= 1_200 && $0[0] == 0x80 && $0[1] & 0x7f == 96 })
        XCTAssertEqual(Array(packets[0][4..<8]), [0, 1, 0x5f, 0x90])
        XCTAssertEqual(packets[0][12] >> 1 & 0x3f, 49)
        XCTAssertEqual(packets[0][13], 0x09)
        XCTAssertEqual(packets[0][14], 0x80 | 19)
        XCTAssertEqual(packets[2][14], 0x40 | 19)
        XCTAssertEqual(packets[0][1] & 0x80, 0); XCTAssertEqual(packets[2][1] & 0x80, 0x80)
        var reconstructed = Data([((packets[0][12] & 0x81) | ((packets[0][14] & 0x3f) << 1)), packets[0][13]])
        for packet in packets { reconstructed.append(packet.dropFirst(15)) }
        XCTAssertEqual(reconstructed, nal)
        for index in 1..<packets.count {
            XCTAssertEqual(sequence(packets[index]), sequence(packets[index - 1]) &+ 1)
        }
        var parameters = AccsoonRTPPacketizer(payloadType: 96)
        let sets = try parameters.hevc(Data([0, 0, 1, 0x40, 1, 0x55, 0, 0, 0, 1, 0x42, 1, 0x66]), timestamp: 0)
        XCTAssertEqual(sets.map { Data($0.dropFirst(12)) }, [Data([0x40, 1, 0x55]), Data([0x42, 1, 0x66])])
        XCTAssertTrue(sets.allSatisfy { $0[1] & 0x80 == 0 })
    }

    func testRandomAccessPictureReplaysParametersMissedByALateDecoder() throws {
        let vps = Data([0x40, 1, 0x11]), sps = Data([0x42, 1, 0x22]), pps = Data([0x44, 1, 0x33])
        let idr = Data([0x26, 1, 0x55]), inter = Data([0x02, 1, 0x66])
        var packetizer = AccsoonRTPPacketizer(payloadType: 96)
        // These packets are sent before the decoder's local socket is listening.
        _ = try packetizer.hevc(annexB([vps, sps, pps]), timestamp: 0)
        let recovered = try packetizer.hevc(annexB([idr]), timestamp: 1_000_000)
        XCTAssertEqual(recovered.map { Data($0.dropFirst(12)) }, [vps, sps, pps, idr])
        XCTAssertTrue(recovered.allSatisfy { Data($0[4..<8]) == Data([0, 1, 0x5f, 0x90]) })
        XCTAssertTrue(recovered.dropLast().allSatisfy { $0[1] & 0x80 == 0 })
        XCTAssertEqual(recovered.last?[1], 0x80 | 96)
        let ordinary = try packetizer.hevc(annexB([inter]), timestamp: 1_016_667)
        XCTAssertEqual(ordinary.count, 1); XCTAssertEqual(Data(ordinary[0].dropFirst(12)), inter)
        // Already complete access units must not receive duplicate parameter sets.
        let complete = try packetizer.hevc(annexB([vps, sps, pps, idr]), timestamp: 2_000_000)
        XCTAssertEqual(complete.map { Data($0.dropFirst(12)) }, [vps, sps, pps, idr])
    }

    func testParameterUpdatesReplaceOldSetsAndOversizedSetsAreNotRetained() throws {
        let vps = Data([0x40, 1, 0x11]), oldSPS = Data([0x42, 1, 0x22]), oldPPS = Data([0x44, 1, 0x33])
        let newSPS = Data([0x42, 1, 0x77]), newPPS = Data([0x44, 1, 0x88]), idr = Data([0x26, 1, 0x55])
        var packetizer = AccsoonRTPPacketizer(payloadType: 96)
        _ = try packetizer.hevc(annexB([vps, oldSPS, oldPPS]), timestamp: 0)
        _ = try packetizer.hevc(annexB([newSPS]), timestamp: 1_000)
        let partlyIncluded = try packetizer.hevc(annexB([newPPS, idr]), timestamp: 2_000)
        XCTAssertEqual(partlyIncluded.map { Data($0.dropFirst(12)) }, [vps, newSPS, newPPS, idr])
        let updated = try packetizer.hevc(annexB([idr]), timestamp: 3_000)
        XCTAssertEqual(updated.map { Data($0.dropFirst(12)) }, [vps, newSPS, newPPS, idr])
        let oversized = Data([0x42, 1]) + Data(repeating: 0x55, count: 65_535)
        _ = try packetizer.hevc(annexB([oversized]), timestamp: 4_000)
        let bounded = try packetizer.hevc(annexB([idr]), timestamp: 5_000)
        XCTAssertEqual(bounded.map { Data($0.dropFirst(12)) }, [vps, newPPS, idr])
    }

    func testADTSStripsCRCAndFramingAndAdvancesOneAACFrame() throws {
        var packetizer = AccsoonRTPPacketizer(payloadType: 97)
        let first = adts(payload: Data([1, 2, 3]), crc: false)
        let second = adts(payload: Data([4, 5]), crc: true)
        let packets = try packetizer.aac(first + second, timestamp: 0)
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(Data(packets[0].dropFirst(12)), Data([0, 16, 0, 24, 1, 2, 3]))
        XCTAssertEqual(Data(packets[1].dropFirst(12)), Data([0, 16, 0, 16, 4, 5]))
        XCTAssertEqual(Array(packets[1][4..<8]), [0, 0, 4, 0])
        XCTAssertEqual(packets[0][1], 0x80 | 97)
        var invalid = first; invalid[2] = 0x50 // 44.1 kHz does not match SDP config 1190.
        XCTAssertThrowsError(try packetizer.aac(invalid, timestamp: 0))
        XCTAssertThrowsError(try packetizer.aac(Data(first.dropLast()), timestamp: 0))
    }

    func testLargeAACAccessUnitUsesOneTimestampAndFullSizeHeaders() throws {
        let raw = Data(repeating: 0x55, count: 2_500)
        var packetizer = AccsoonRTPPacketizer(payloadType: 97)
        let packets = try packetizer.aac(adts(payload: raw, crc: false), timestamp: 1_000_000)
        XCTAssertEqual(packets.count, 3)
        XCTAssertTrue(packets.allSatisfy { $0.count <= 1_200 })
        XCTAssertTrue(packets.allSatisfy { Data($0[4..<8]) == Data(packets[0][4..<8]) })
        XCTAssertTrue(packets.allSatisfy { Int($0[14]) << 5 | Int($0[15] >> 3) == 2_500 })
        XCTAssertEqual(packets[0][1] & 0x80, 0); XCTAssertEqual(packets[2][1] & 0x80, 0x80)
        XCTAssertEqual(packets.reduce(into: Data()) { $0.append($1.dropFirst(16)) }, raw)
    }

    private func fragment(id: UInt32, count: UInt16 = 1, index: UInt16 = 0, bytes: [UInt8]) -> Data {
        var data = Data(repeating: 0, count: 24); data[12] = 1
        put(id, into: &data, at: 16); put(count, into: &data, at: 20); put(index, into: &data, at: 22)
        data.append(contentsOf: bytes); return data
    }

    private func put<T: FixedWidthInteger>(_ value: T, into data: inout Data, at offset: Int) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<offset + $0.count, with: $0) }
    }

    private func sequence(_ packet: Data) -> UInt16 { UInt16(packet[2]) << 8 | UInt16(packet[3]) }

    private func annexB(_ units: [Data]) -> Data {
        units.reduce(into: Data()) { $0.append(contentsOf: [0, 0, 0, 1]); $0.append($1) }
    }

    private func adts(payload: Data, crc: Bool) -> Data {
        let length = payload.count + (crc ? 9 : 7)
        var result = Data([0xff, crc ? 0xf0 : 0xf1, 0x4c, 0x80 | UInt8(length >> 11), UInt8((length >> 3) & 0xff), UInt8((length & 7) << 5) | 0x1f, 0xfc])
        if crc { result.append(contentsOf: [0, 0]) }
        result.append(payload); return result
    }
}
