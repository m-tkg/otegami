import Crypto
import Foundation

/// Encrypts/decrypts IMAP credentials at rest (`RelayStore`'s `watch` rows)
/// with AES-256-GCM, keyed by `RELAY_MASTER_KEY` (plan §7: "サーバ側は
/// RELAY_MASTER_KEY(env) の AES-GCM で暗号化保存"). The key never touches
/// disk itself — it's supplied only via the environment, so a stolen
/// database file alone is useless without also having compromised the
/// process's environment.
///
/// Device secrets are handled separately (`RelayStore` stores only their
/// SHA-256 hash, like a password) — this type is only ever used for IMAP
/// credentials, which the relay genuinely needs to recover in plaintext to
/// open the watch's IMAP connection.
struct CredentialCrypto: Sendable {
    enum CredentialCryptoError: Error, CustomStringConvertible {
        case invalidKeyLength(Int)
        case invalidBase64
        case decryptionFailed

        var description: String {
            switch self {
            case .invalidKeyLength(let length):
                "RELAY_MASTER_KEY must decode to exactly 32 bytes (got \(length))"
            case .invalidBase64:
                "RELAY_MASTER_KEY is not valid base64"
            case .decryptionFailed:
                "failed to decrypt stored credential (wrong key, or corrupted/tampered data)"
            }
        }
    }

    // Stored as raw `Data` rather than `SymmetricKey` directly: on Linux,
    // swift-crypto's `SymmetricKey` doesn't conform to `Sendable` (unlike
    // on Apple platforms, where `Crypto` re-exports CryptoKit's Sendable-
    // safe type) — this server only ever runs on Linux in production
    // (docs/relay-deployment.md), so a `SymmetricKey` stored property would
    // fail to build there even though it builds fine locally on macOS.
    // `SymmetricKey(data:)` is cheap to reconstruct per call.
    private let keyData: Data

    init(key: SymmetricKey) {
        self.keyData = key.withUnsafeBytes { Data($0) }
    }

    /// Parses the `RELAY_MASTER_KEY` env var: base64 for exactly 32 raw
    /// bytes (AES-256).
    init(base64Key: String) throws {
        guard let data = Data(base64Encoded: base64Key) else {
            throw CredentialCryptoError.invalidBase64
        }
        guard data.count == 32 else {
            throw CredentialCryptoError.invalidKeyLength(data.count)
        }
        self.keyData = data
    }

    private var key: SymmetricKey { SymmetricKey(data: keyData) }

    /// Generates a fresh random 32-byte key, base64-encoded — what
    /// `docs/relay-deployment.md` tells operators to run once
    /// (`openssl rand -base64 32`-equivalent) to produce `RELAY_MASTER_KEY`.
    static func generateBase64Key() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    /// Encrypts `plaintext`, returning the AES-GCM sealed box's combined
    /// representation (nonce + ciphertext + tag) as a single `Data` — the
    /// only thing `RelayStore` needs to persist per credential.
    func encrypt(_ plaintext: String) throws -> Data {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else {
            // Only possible if the nonce were non-standard-size, which
            // `AES.GCM.seal` never produces without an explicit custom
            // nonce being passed in (we don't).
            throw CredentialCryptoError.decryptionFailed
        }
        return combined
    }

    /// Reverses `encrypt(_:)`. Throws `.decryptionFailed` on any
    /// authentication-tag mismatch (wrong key or tampered/corrupted data) —
    /// deliberately not more specific, to avoid oracle-style error
    /// messages leaking anything about *why* it failed.
    func decrypt(_ combined: Data) throws -> String {
        do {
            let sealed = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(sealed, using: key)
            guard let string = String(data: plaintext, encoding: .utf8) else {
                throw CredentialCryptoError.decryptionFailed
            }
            return string
        } catch is CredentialCryptoError {
            throw CredentialCryptoError.decryptionFailed
        } catch {
            throw CredentialCryptoError.decryptionFailed
        }
    }
}
