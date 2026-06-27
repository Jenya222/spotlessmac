import CryptoKit
import Foundation

enum LicenseError: Error {
    case invalidFormat
    case invalidSignature
}

struct LicensePayload {
    let email: String
    let productID: String
    let issuedDate: String
}

struct LicenseValidator {
    // TODO: Replace these 32 bytes with your actual Ed25519 public key.
    //
    // Steps:
    //   1. openssl genpkey -algorithm ed25519 -out license_private.pem
    //   2. openssl pkey -in license_private.pem -pubout -out license_public.pem
    //   3. openssl pkey -in license_public.pem -pubin -outform DER | tail -c 32 | xxd -i
    //   4. Paste the xxd output below. Keep license_private.pem secret — never commit it.
    private static let publicKeyBytes: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    // License key format:  Base64(payload) + "." + Base64(signature)
    // Payload:             "{email}|spotlessmac-v1|{YYYY-MM-DD}"
    static func validate(_ licenseKey: String) throws -> LicensePayload {
        let parts = licenseKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ".")
        guard parts.count == 2,
              let payloadData = Data(base64Encoded: parts[0]),
              let sigData     = Data(base64Encoded: parts[1])
        else { throw LicenseError.invalidFormat }

        let pubKey: Curve25519.Signing.PublicKey
        do {
            pubKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(publicKeyBytes))
        } catch {
            throw LicenseError.invalidSignature
        }

        guard pubKey.isValidSignature(sigData, for: payloadData) else {
            throw LicenseError.invalidSignature
        }

        guard let payloadString = String(data: payloadData, encoding: .utf8) else {
            throw LicenseError.invalidFormat
        }
        let fields = payloadString.components(separatedBy: "|")
        guard fields.count >= 3 else { throw LicenseError.invalidFormat }

        return LicensePayload(email: fields[0], productID: fields[1], issuedDate: fields[2])
    }
}
