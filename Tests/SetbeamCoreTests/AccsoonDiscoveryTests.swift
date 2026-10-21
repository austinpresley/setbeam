import XCTest
import CommonCrypto
import zlib
@testable import SetbeamCore

final class AccsoonDiscoveryTests: XCTestCase {
    func testBothProductStatusesObservedOnTheSamePhysicalMaster4KAreRecognized() {
        for product in [21, 24] {
            let device = AccsoonDevice(id: identifier, host: host, wifiName: "Accsoon_TEST", productID: product,
                firmware: 798, hardware: 256, lastSeen: Date())
            XCTAssertTrue(device.recognized, "The physically identified Master 4K reported product \(product)")
        }
        let unknown = AccsoonDevice(id: 1, host: "127.0.0.1", wifiName: "Unverified", productID: 999,
            firmware: nil, hardware: nil, lastSeen: Date())
        XCTAssertFalse(unknown.recognized)
    }
    private let identifier: UInt32 = 0x1234_5678
    private let host = "192.0.2.1"
    private let now = Date(timeIntervalSince1970: 1_000)

    func testAnnouncementPreservesIdentityAndSSIDWithoutClaimingARecognizedModel() throws {
        let packet = try announcement(profile: ["uid": identifier], custom: ["public_ssid": "Accsoon_TEST"])
        let device = try XCTUnwrap(AccsoonAnnouncement.decode(packet, host: host, now: now))

        XCTAssertEqual(device.id, identifier)
        XCTAssertEqual(device.host, host)
        XCTAssertEqual(device.wifiName, "Accsoon_TEST")
        XCTAssertEqual(device.lastSeen, now)
        XCTAssertFalse(device.recognized)
        XCTAssertNil(device.productID)
        XCTAssertNil(device.firmware)
        XCTAssertNil(device.hardware)
        XCTAssertFalse(device.videoAvailable)
        XCTAssertFalse(device.audioAvailable)
    }

    func testCustomNetworkKeyIsDiscarded() throws {
        // This marker is synthetic test data, not a network credential.
        let discarded = "SYNTHETIC_DISCARD_MARKER"
        let packet = try announcement(profile: ["uid": identifier], custom: [
            "public_ssid": "Accsoon_TEST",
            "public_key": discarded,
            "unrecognized_metadata": ["public_key": discarded]
        ])
        let device = try XCTUnwrap(AccsoonAnnouncement.decode(packet, host: host, now: now))

        XCTAssertEqual(device.wifiName, "Accsoon_TEST")
        XCTAssertFalse(String(reflecting: device).contains(discarded))
        XCTAssertFalse(Mirror(reflecting: device).children.contains { $0.label == "public_key" })
    }

    func testCorruptProfileOrCustomCRCRejectsTheWholeAnnouncement() throws {
        let profile = try element(type: 0, json: ["uid": identifier])
        let custom = try element(type: 1, json: ["public_ssid": "Accsoon_TEST"])

        var badProfile = profile
        badProfile[4] ^= 1
        XCTAssertNil(AccsoonAnnouncement.decode(header() + badProfile + custom, host: host))

        var badCustom = custom
        badCustom[4] ^= 1
        XCTAssertNil(AccsoonAnnouncement.decode(header() + profile + badCustom, host: host))
    }

    func testTruncatedAndNonBlockAlignedCiphertextLengthsAreRejected() throws {
        let packet = try announcement(profile: ["uid": identifier], custom: ["public_ssid": "Accsoon_TEST"])
        XCTAssertNil(AccsoonAnnouncement.decode(Data(packet.dropLast()), host: host))
        XCTAssertNil(AccsoonAnnouncement.decode(Data(packet.prefix(19)), host: host))

        var invalidLength = try element(type: 0, json: ["uid": identifier])
        put(UInt16(invalidLength.count - 9), into: &invalidLength, at: 2)
        XCTAssertNil(AccsoonAnnouncement.decode(header() + invalidLength, host: host))

        var oversizedLength = try element(type: 0, json: ["uid": identifier])
        put(UInt16(oversizedLength.count + 8), into: &oversizedLength, at: 2)
        XCTAssertNil(AccsoonAnnouncement.decode(header() + oversizedLength, host: host))
    }

    func testValidCRCDoesNotPermitMalformedJSONOrInvalidZeroPadding() throws {
        let notJSON = try element(type: 0, cleartext: Data("not a JSON profile".utf8))
        XCTAssertNil(AccsoonAnnouncement.decode(header() + notJSON, host: host))

        let notAnObject = try element(type: 0, cleartext: Data("[]".utf8))
        XCTAssertNil(AccsoonAnnouncement.decode(header() + notAnObject, host: host))

        var invalidPadding = try JSONSerialization.data(withJSONObject: ["uid": identifier])
        invalidPadding.append(contentsOf: [0, 1])
        let padded = try element(type: 0, cleartext: invalidPadding)
        XCTAssertNil(AccsoonAnnouncement.decode(header() + padded, host: host))
    }

    func testProfileUIDMustMatchTheHeaderAndBeNonzero() throws {
        let mismatch = try announcement(profile: ["uid": identifier &+ 1])
        XCTAssertNil(AccsoonAnnouncement.decode(mismatch, host: host))

        let zero = try announcement(profile: ["uid": 0], headerUID: 0)
        XCTAssertNil(AccsoonAnnouncement.decode(zero, host: host))

        let missing = try announcement(profile: ["stream": [:]])
        XCTAssertNil(AccsoonAnnouncement.decode(missing, host: host))
    }

    func testOnlyDiscoveryHeadersCanCreateAnAnnouncement() throws {
        let valid = try announcement(profile: ["uid": identifier])
        for offset in [0, 8, 9, 10] {
            var invalid = valid
            invalid[offset] ^= 1
            XCTAssertNil(AccsoonAnnouncement.decode(invalid, host: host), "Invalid header at byte \(offset)")
        }
    }

    private func announcement(profile: [String: Any], custom: [String: Any]? = nil, headerUID: UInt32? = nil) throws -> Data {
        var packet = header(uid: headerUID)
        packet.append(try element(type: 0, json: profile))
        if let custom { packet.append(try element(type: 1, json: custom)) }
        return packet
    }

    private func header(uid: UInt32? = nil) -> Data {
        var data = Data(repeating: 0, count: 12)
        put(UInt32(0x78776e93), into: &data, at: 0)
        put(uid ?? identifier, into: &data, at: 4)
        data[8] = 0x40
        put(UInt16(10), into: &data, at: 10)
        return data
    }

    private func element(type: UInt16, json: [String: Any]) throws -> Data {
        try element(type: type, cleartext: JSONSerialization.data(withJSONObject: json, options: .sortedKeys))
    }

    private func element(type: UInt16, cleartext: Data) throws -> Data {
        var padded = cleartext
        let padding = (kCCBlockSizeAES128 - padded.count % kCCBlockSizeAES128) % kCCBlockSizeAES128
        padded.append(Data(repeating: 0, count: padding))
        let key = Array("myN9QyGEwC2T7Ke2".utf8)
        var output = [UInt8](repeating: 0, count: padded.count + kCCBlockSizeAES128)
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            padded.withUnsafeBytes { inputBytes in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, kCCKeySizeAES128, nil, inputBytes.baseAddress, padded.count,
                        &output, output.count, &moved)
            }
        }
        guard status == kCCSuccess else { throw NSError(domain: "AccsoonSyntheticPacket", code: Int(status)) }
        let cipher = Data(output.prefix(moved))
        let checksum = cipher.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(cipher.count)) }
        var data = Data(repeating: 0, count: 8)
        put(type, into: &data, at: 0)
        put(UInt16(cipher.count), into: &data, at: 2)
        put(UInt32(checksum), into: &data, at: 4)
        data.append(cipher)
        return data
    }

    private func put<T: FixedWidthInteger>(_ value: T, into data: inout Data, at offset: Int) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<offset + $0.count, with: $0) }
    }
}
