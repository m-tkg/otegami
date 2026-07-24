import Crypto
import Foundation
import Testing

@testable import OtegamiRelay

@Suite("CredentialCrypto")
struct CredentialCryptoTests {
    @Test("round-trips a plaintext credential")
    func roundTrip() throws {
        let crypto = CredentialCrypto(key: SymmetricKey(size: .bits256))
        let ciphertext = try crypto.encrypt("s3cr3t-app-password")
        let plaintext = try crypto.decrypt(ciphertext)
        #expect(plaintext == "s3cr3t-app-password")
    }

    @Test("handles Japanese/UTF-8 credentials")
    func utf8RoundTrip() throws {
        let crypto = CredentialCrypto(key: SymmetricKey(size: .bits256))
        let ciphertext = try crypto.encrypt("パスワード🔑")
        let plaintext = try crypto.decrypt(ciphertext)
        #expect(plaintext == "パスワード🔑")
    }

    @Test("two encryptions of the same plaintext produce different ciphertext (fresh nonce)")
    func nonceIsFresh() throws {
        let crypto = CredentialCrypto(key: SymmetricKey(size: .bits256))
        let first = try crypto.encrypt("same-password")
        let second = try crypto.encrypt("same-password")
        #expect(first != second)
    }

    @Test("decrypting with the wrong key fails")
    func wrongKeyFails() throws {
        let crypto = CredentialCrypto(key: SymmetricKey(size: .bits256))
        let other = CredentialCrypto(key: SymmetricKey(size: .bits256))
        let ciphertext = try crypto.encrypt("s3cr3t")
        #expect(throws: (any Error).self) {
            try other.decrypt(ciphertext)
        }
    }

    @Test("decrypting tampered ciphertext fails")
    func tamperedCiphertextFails() throws {
        let crypto = CredentialCrypto(key: SymmetricKey(size: .bits256))
        var ciphertext = try crypto.encrypt("s3cr3t")
        ciphertext[ciphertext.startIndex] ^= 0xFF
        #expect(throws: (any Error).self) {
            try crypto.decrypt(ciphertext)
        }
    }

    @Test("base64Key init rejects a key of the wrong length")
    func rejectsWrongKeyLength() {
        let shortKey = Data(repeating: 0, count: 16).base64EncodedString()
        #expect(throws: (any Error).self) {
            try CredentialCrypto(base64Key: shortKey)
        }
    }

    @Test("base64Key init rejects non-base64 input")
    func rejectsInvalidBase64() {
        #expect(throws: (any Error).self) {
            try CredentialCrypto(base64Key: "not valid base64!!")
        }
    }

    @Test("generateBase64Key produces a usable 32-byte key")
    func generatedKeyWorks() throws {
        let generated = CredentialCrypto.generateBase64Key()
        let crypto = try CredentialCrypto(base64Key: generated)
        let ciphertext = try crypto.encrypt("round-trip")
        #expect(try crypto.decrypt(ciphertext) == "round-trip")
    }
}
