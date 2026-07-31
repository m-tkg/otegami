// Package cryptox encrypts/decrypts IMAP credentials at rest, exactly
// compatible with the retired Swift relay's CredentialCrypto.
//
// Compatibility is the single most delicate part of this port (Task #180):
// an existing SQLite database has `watch.encryptedSecret` BLOB columns
// written by swift-crypto's `AES.GCM.seal(_:using:)`, and this relay must
// decrypt them with the same RELAY_MASTER_KEY without any migration step.
//
// swift-crypto's `AES.GCM.SealedBox.combined` representation (what
// CredentialCrypto.encrypt stores) is, per Apple's CryptoKit/swift-crypto
// documentation: nonce (12 bytes) || ciphertext (same length as plaintext)
// || authentication tag (16 bytes), concatenated as raw bytes — no
// base64, no length prefixes, no additional authenticated data.
//
// Go's crypto/cipher.AEAD (via crypto/aes + cipher.NewGCM, which defaults
// to a 12-byte nonce and a 16-byte tag, matching AES-GCM's standard sizes)
// produces the identical layout when Seal's `dst` argument is the nonce
// itself: `aead.Seal(nonce, nonce, plaintext, nil)` appends
// ciphertext||tag onto `dst`, yielding nonce||ciphertext||tag — byte-for-
// byte what swift-crypto's `.combined` produces for the same key/nonce/
// plaintext. This is verified against real Swift-encrypted fixtures in
// credential_crypto_test.go (TestDecryptsSwiftEncryptedFixture and
// TestDecryptsSwiftEncryptedUTF8Fixture).
package cryptox

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"unicode/utf8"
)

// nonceSize and tagSize match AES-GCM's standard sizes, which is what both
// swift-crypto's AES.GCM (no custom nonce ever passed by CredentialCrypto)
// and Go's cipher.NewGCM (default constructor) use.
const (
	nonceSize = 12
	tagSize   = 16
)

// ErrInvalidKeyLength mirrors CredentialCryptoError.invalidKeyLength.
type ErrInvalidKeyLength struct{ Length int }

func (e ErrInvalidKeyLength) Error() string {
	return fmt.Sprintf("RELAY_MASTER_KEY must decode to exactly 32 bytes (got %d)", e.Length)
}

// ErrInvalidBase64 mirrors CredentialCryptoError.invalidBase64.
var ErrInvalidBase64 = errors.New("RELAY_MASTER_KEY is not valid base64")

// ErrDecryptionFailed mirrors CredentialCryptoError.decryptionFailed —
// deliberately generic (wrong key vs. tampered/corrupted data are not
// distinguished), matching the Swift side's oracle-avoidance rationale.
var ErrDecryptionFailed = errors.New("failed to decrypt stored credential (wrong key, or corrupted/tampered data)")

// CredentialCrypto encrypts/decrypts IMAP credentials with AES-256-GCM,
// keyed by RELAY_MASTER_KEY.
type CredentialCrypto struct {
	key []byte // exactly 32 bytes
}

// New wraps an already-decoded 32-byte AES-256 key.
func New(key []byte) (*CredentialCrypto, error) {
	if len(key) != 32 {
		return nil, ErrInvalidKeyLength{Length: len(key)}
	}
	return &CredentialCrypto{key: key}, nil
}

// NewFromBase64Key parses the RELAY_MASTER_KEY env var: base64 for exactly
// 32 raw bytes (AES-256) — identical parsing to
// CredentialCrypto.init(base64Key:).
func NewFromBase64Key(base64Key string) (*CredentialCrypto, error) {
	data, err := base64.StdEncoding.DecodeString(base64Key)
	if err != nil {
		return nil, ErrInvalidBase64
	}
	return New(data)
}

// GenerateBase64Key generates a fresh random 32-byte key, base64-encoded —
// what docs/relay-deployment.md tells operators to run once (`openssl rand
// -base64 32`-equivalent) to produce RELAY_MASTER_KEY.
func GenerateBase64Key() (string, error) {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(key), nil
}

func (c *CredentialCrypto) aead() (cipher.AEAD, error) {
	block, err := aes.NewCipher(c.key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// Encrypt seals plaintext, returning nonce||ciphertext||tag as a single
// []byte — the same "combined" layout CredentialCrypto.encrypt(_:)
// produces, and the only thing the store needs to persist per credential.
func (c *CredentialCrypto) Encrypt(plaintext string) ([]byte, error) {
	aead, err := c.aead()
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, nonceSize)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	// Seal(dst, nonce, plaintext, additionalData): appends ciphertext||tag
	// to dst. Passing nonce as dst yields nonce||ciphertext||tag in one
	// slice, matching swift-crypto's AES.GCM.SealedBox.combined exactly.
	combined := aead.Seal(nonce, nonce, []byte(plaintext), nil)
	return combined, nil
}

// Decrypt reverses Encrypt (and, critically, any AES.GCM.seal-produced
// combined representation from the retired Swift relay). Returns ErrDecryptionFailed
// on any authentication-tag mismatch, malformed input, or non-UTF-8
// plaintext.
func (c *CredentialCrypto) Decrypt(combined []byte) (string, error) {
	if len(combined) < nonceSize+tagSize {
		return "", ErrDecryptionFailed
	}
	aead, err := c.aead()
	if err != nil {
		return "", ErrDecryptionFailed
	}
	nonce := combined[:nonceSize]
	ciphertextAndTag := combined[nonceSize:]
	plaintext, err := aead.Open(nil, nonce, ciphertextAndTag, nil)
	if err != nil {
		return "", ErrDecryptionFailed
	}
	// Swift's CredentialCrypto.decrypt fails when the plaintext isn't
	// valid UTF-8 (String(data:encoding:) returning nil) — Go strings can
	// carry arbitrary bytes, so check explicitly for identical behavior.
	if !utf8.Valid(plaintext) {
		return "", ErrDecryptionFailed
	}
	return string(plaintext), nil
}
