import Crypto
import Foundation
import OtegamiRelayAPI
import Testing

@testable import OtegamiRelay

/// Exercises everything about `APNsSender` that doesn't require a live
/// APNs connection — no `.p8` key has been issued for this project yet
/// (`PENDING.md`, M9), so `send(deviceToken:environment:payload:)` itself
/// is never called here. What *is* verified is the JWT this project would
/// present to APNs: correct header/claims shape and a structurally valid
/// ES256 signature, using a throwaway `P256` key generated in-test (APNs'
/// JWT format doesn't care whose key it is to check the shape).
@Suite("APNsJWT")
struct APNsSenderTests {
    private func makeConfiguration(privateKey: P256.Signing.PrivateKey) -> APNsSender.Configuration {
        .init(
            privateKeyPEM: privateKey.pemRepresentation,
            keyId: "ABC123DEFG",
            teamId: "TEAM7654321",
            bundleId: "com.mtkg.otegami"
        )
    }

    @Test("JWT has three dot-separated segments")
    func hasThreeSegments() throws {
        let key = P256.Signing.PrivateKey()
        let token = try APNsJWT.makeToken(configuration: makeConfiguration(privateKey: key), issuedAt: Date())
        #expect(token.split(separator: ".", omittingEmptySubsequences: false).count == 3)
    }

    @Test("header decodes to alg=ES256 and the configured key id")
    func headerShape() throws {
        let key = P256.Signing.PrivateKey()
        let token = try APNsJWT.makeToken(configuration: makeConfiguration(privateKey: key), issuedAt: Date())
        let headerSegment = String(token.split(separator: ".")[0])
        let header = try decodeJSONObject(base64url: headerSegment)
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "ABC123DEFG")
    }

    @Test("claims decode to the configured team id and a recent iat")
    func claimsShape() throws {
        let key = P256.Signing.PrivateKey()
        let issuedAt = Date()
        let token = try APNsJWT.makeToken(configuration: makeConfiguration(privateKey: key), issuedAt: issuedAt)
        let claimsSegment = String(token.split(separator: ".")[1])
        let claims = try decodeJSONObject(base64url: claimsSegment)
        #expect(claims["iss"] as? String == "TEAM7654321")
        #expect(claims["iat"] as? Int == Int(issuedAt.timeIntervalSince1970))
    }

    @Test("signature segment is a valid ES256 signature over header.claims")
    func signatureIsValid() throws {
        let key = P256.Signing.PrivateKey()
        let token = try APNsJWT.makeToken(configuration: makeConfiguration(privateKey: key), issuedAt: Date())
        let segments = token.split(separator: ".")
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        let signatureData = try base64urlDecode(String(segments[2]))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        #expect(key.publicKey.isValidSignature(signature, for: signingInput))
    }

    @Test("signature segment is exactly 64 raw bytes (r || s, not ASN.1 DER)")
    func signatureIsRawNotDER() throws {
        let key = P256.Signing.PrivateKey()
        let token = try APNsJWT.makeToken(configuration: makeConfiguration(privateKey: key), issuedAt: Date())
        let signatureSegment = String(token.split(separator: ".")[2])
        let signatureData = try base64urlDecode(signatureSegment)
        #expect(signatureData.count == 64)
    }

    @Test("re-signing with a different key produces a signature the first key's public key rejects")
    func wrongKeySignatureIsRejected() throws {
        let key = P256.Signing.PrivateKey()
        let otherKey = P256.Signing.PrivateKey()
        let token = try APNsJWT.makeToken(configuration: makeConfiguration(privateKey: otherKey), issuedAt: Date())
        let segments = token.split(separator: ".")
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        let signatureData = try base64urlDecode(String(segments[2]))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        #expect(!key.publicKey.isValidSignature(signature, for: signingInput))
    }

    @Test("a device registered as .sandbox is routed to APNs' sandbox host")
    func sandboxRoutesToSandboxHost() {
        #expect(APNsSender.host(for: .sandbox) == "api.sandbox.push.apple.com")
    }

    @Test("a device registered as .production is routed to APNs' production host")
    func productionRoutesToProductionHost() {
        #expect(APNsSender.host(for: .production) == "api.push.apple.com")
    }

    // MARK: - Helpers

    private func base64urlDecode(_ value: String) throws -> Data {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else {
            throw APNsSenderTestsError.invalidBase64
        }
        return data
    }

    private func decodeJSONObject(base64url segment: String) throws -> [String: Any] {
        let data = try base64urlDecode(segment)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APNsSenderTestsError.invalidJSON
        }
        return object
    }

    private enum APNsSenderTestsError: Error {
        case invalidBase64
        case invalidJSON
    }
}
