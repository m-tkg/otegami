import CryptoKit
import Foundation

/// RFC 7636 (Proof Key for Code Exchange) verifier/challenge pair, generated
/// once per authorization attempt (plan: "PKCE verifier/challenge 生成は純関数
/// でテスト"). Kept as a pure value type with no dependency on
/// `AuthenticationServices`/`URLSession` so `PKCETests` can assert against
/// known vectors without touching the network or a web view.
///
/// Shared by `GoogleOAuth`/`MicrosoftOAuth` (moved here from each package
/// during the OAuthKit consolidation) — the PKCE algorithm itself (RFC 7636)
/// has nothing provider-specific about it, so both `GoogleOAuthClient` and
/// `MicrosoftOAuthClient` use this same type via `import OAuthKit`.
public struct PKCE: Sendable, Equatable {
    /// The `code_verifier` sent at token-exchange time — a high-entropy
    /// random string, 43–128 characters of `[A-Za-z0-9-._~]` per RFC 7636
    /// §4.1. Kept secret client-side until then (never put in a URL).
    public let verifier: String
    /// The `code_challenge` sent in the authorization request: base64url
    /// (no padding) of SHA-256(verifier). `method` is always `S256` (the
    /// plan calls for it explicitly; `plain` exists in the RFC but defeats
    /// the point of PKCE and MailCore/Google both support S256).
    public let challenge: String

    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
    }

    /// Generates a fresh verifier from `entropy` (default: `SystemRandomNumberGenerator`
    /// via `Data(count:)`-backed random bytes) and derives its S256
    /// challenge. `entropy` is injectable so tests can assert an exact
    /// verifier string against a known SHA-256 vector rather than merely
    /// checking length/charset.
    public static func generate(entropySource: () -> Data = { PKCE.randomBytes(count: 32) }) -> PKCE {
        let verifier = base64URLEncode(entropySource())
        let challenge = base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
        return PKCE(verifier: verifier, challenge: challenge)
    }

    /// 32 random bytes base64url-encode to a 43-character verifier — within
    /// RFC 7636's 43–128 character range and matching what most OAuth
    /// clients (including Google's own examples) use.
    public static func randomBytes(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    /// RFC 4648 §5 base64url, no padding — both the verifier's own encoding
    /// and its SHA-256 challenge use this, per RFC 7636 §4.2's
    /// `BASE64URL-ENCODE(SHA256(ASCII(code_verifier)))`. `public` (rather
    /// than the pre-consolidation `internal`) because
    /// `GoogleOAuthClient.randomState()`/`MicrosoftOAuthClient.randomState()`
    /// — in their own, now-separate modules — reuse this same base64url
    /// encoding for the OAuth `state` parameter, not just for PKCE itself.
    public static func base64URLEncode(_ data: Data) -> String {
        Data(data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
