import CryptoKit
import Foundation

/// The small RFC 6455 subset used by the presence channel: unfragmented, masked client text
/// frames with small payloads, ping/pong, and close. Anything else is a protocol error.
enum WebSocketFrame: Equatable {
    case text(String), ping(Data), pong, close

    enum Failure: Error, Equatable { case protocolError, tooLarge }

    static func acceptKey(for key: String) -> String? {
        guard let decoded = Data(base64Encoded: key), decoded.count == 16 else { return nil }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    /// Removes and returns every complete frame at the start of `buffer`, leaving any partial frame.
    static func parse(_ buffer: inout Data, maxPayload: Int) throws -> [WebSocketFrame] {
        var frames: [WebSocketFrame] = []
        while true {
            let bytes = [UInt8](buffer.prefix(14))
            guard bytes.count >= 2 else { return frames }
            let fin = bytes[0] & 0x80 != 0, reserved = bytes[0] & 0x70, opcode = bytes[0] & 0x0f
            let masked = bytes[1] & 0x80 != 0
            guard fin, reserved == 0, masked else { throw Failure.protocolError }
            var length = Int(bytes[1] & 0x7f), offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { return frames }
                length = Int(bytes[2]) << 8 | Int(bytes[3]); offset = 4
            } else if length == 127 { throw Failure.tooLarge }
            let control = opcode >= 8
            guard length <= (control ? 125 : maxPayload) else { throw Failure.tooLarge }
            guard buffer.count >= offset + 4 + length else { return frames }
            let all = [UInt8](buffer.prefix(offset + 4 + length))
            let mask = Array(all[offset..<offset + 4])
            let payload = Data(all[(offset + 4)...].enumerated().map { $0.element ^ mask[$0.offset % 4] })
            buffer = Data(buffer.dropFirst(offset + 4 + length))
            switch opcode {
            case 0x1:
                guard let text = String(data: payload, encoding: .utf8) else { throw Failure.protocolError }
                frames.append(.text(text))
            case 0x8: frames.append(.close); return frames
            case 0x9: frames.append(.ping(payload))
            case 0xA: frames.append(.pong)
            default: throw Failure.protocolError
            }
        }
    }

    /// An unmasked server frame.
    static func encode(text: String) -> Data { encode(opcode: 0x1, payload: Data(text.utf8)) }
    static func encode(opcode: UInt8, payload: Data) -> Data {
        var header = Data([0x80 | opcode])
        if payload.count < 126 { header.append(UInt8(payload.count)) }
        else if payload.count <= 0xffff { header.append(126); header.append(UInt8(payload.count >> 8)); header.append(UInt8(payload.count & 0xff)) }
        else {
            header.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { header.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xff)) }
        }
        return header + payload
    }
}
