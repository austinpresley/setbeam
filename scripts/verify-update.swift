import CryptoKit
import Foundation

// Verify with the public key shipped in Setbeam, without Keychain access.
let args = CommandLine.arguments
func verify() -> Bool {
    guard args.count >= 4, args.count.isMultiple(of: 2),
          let keyData = Data(base64Encoded: args[1]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    else { return false }
    for index in stride(from: 2, to: args.count, by: 2) {
        guard let signature = Data(base64Encoded: args[index + 1]),
              let bytes = try? Data(contentsOf: URL(fileURLWithPath: args[index]), options: .mappedIfSafe),
              key.isValidSignature(signature, for: bytes)
        else { return false }
    }
    return true
}
if !verify() {
    FileHandle.standardError.write(Data("Invalid Sparkle feed or artifact signature.\n".utf8))
    exit(1)
}
