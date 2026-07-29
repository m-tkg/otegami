import CryptoKit
import Foundation

/// RFC 7636 (Proof Key for Code Exchange) verifier/challenge pair.
/// Deliberately a byte-for-byte mirror of `GoogleOAuth.PKCE` (Task #116
/// 第2段: "GoogleOAuth 実装をひな形に MicrosoftOAuth を実装") — PKCE itself
/// is provider-agnostic RFC 7636, but this target intentionally doesn't
/// depend on `GoogleOAuth` (matching that target's own "no dependency on
/// any other target in this package" design, so either provider module can
/// be dropped independently without touching the other) — see this
/// package's `Package.swift` comment on the `MicrosoftOAuth` target.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
    }

    public static func generate(entropySource: () -> Data = { PKCE.randomBytes(count: 32) }) -> PKCE {
        let verifier = base64URLEncode(entropySource())
        let challenge = base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
        return PKCE(verifier: verifier, challenge: challenge)
    }

    public static func randomBytes(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    static func base64URLEncode(_ data: Data) -> String {
        Data(data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
