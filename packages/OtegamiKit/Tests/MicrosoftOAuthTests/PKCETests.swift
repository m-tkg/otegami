import Foundation
import Testing
@testable import MicrosoftOAuth

/// Mirrors `GoogleOAuthTests.PKCETests` (same RFC 7636 §A worked example —
/// PKCE itself is provider-agnostic, so the ground truth doesn't change).
@Suite("PKCE")
struct PKCETests {
    @Test
    func generateDerivesTheRFC7636WorkedExampleChallenge() throws {
        let knownVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
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
}
