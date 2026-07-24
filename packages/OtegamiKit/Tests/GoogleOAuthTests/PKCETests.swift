import Foundation
import Testing
@testable import GoogleOAuth

/// Known-vector tests for `PKCE.generate` — RFC 7636 §A gives a worked
/// example (`verifier="dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"` →
/// `challenge="E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"`), used here as
/// the ground truth for the base64url + SHA-256 pipeline rather than just
/// checking length/charset.
@Suite("PKCE")
struct PKCETests {
    @Test
    func generateDerivesTheRFC7636WorkedExampleChallenge() throws {
        let knownVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        // `PKCE.generate` base64url-*encodes* whatever `entropySource`
        // returns to produce `verifier` — so reproducing the RFC's exact
        // verifier string means feeding its *decoded* bytes in as entropy,
        // not the verifier's own ASCII text.
        let entropy = try #require(Self.base64URLDecode(knownVerifier))
        let pkce = PKCE.generate(entropySource: { entropy })

        #expect(pkce.verifier == knownVerifier)
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var standard = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while standard.count % 4 != 0 { standard.append("=") }
        return Data(base64Encoded: standard)
    }

    @Test
    func generateProducesAVerifierWithinRFCLengthAndCharset() {
        let pkce = PKCE.generate()
        #expect(pkce.verifier.count >= 43 && pkce.verifier.count <= 128)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(pkce.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(!pkce.challenge.contains("=") && !pkce.challenge.contains("+") && !pkce.challenge.contains("/"))
    }

    @Test
    func generateProducesDifferentValuesEachCall() {
        let first = PKCE.generate()
        let second = PKCE.generate()
        #expect(first.verifier != second.verifier)
        #expect(first.challenge != second.challenge)
    }

    @Test
    func base64URLEncodeStripsPaddingAndSwapsAlphabet() {
        // Standard base64 of "sure." is "c3VyZS4=" (has padding, uses
        // no +//, so pick bytes that *do* hit + and / in standard base64
        // to exercise the character-swap branch too).
        let bytes = Data([0xFB, 0xFF, 0xFE])
        let standard = bytes.base64EncodedString()
        #expect(standard.contains("+") || standard.contains("/") || standard.contains("="))
        let encoded = PKCE.base64URLEncode(bytes)
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
    }
}
