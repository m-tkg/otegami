package push

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/m-tkg/otegami-relay-go/internal/api"
)

// Mirrors the Swift APNsSenderTests: no .p8 key has been issued for this
// project, so Send itself is never exercised against real APNs — what IS
// verified is the JWT the relay would present: header/claims shape and a
// structurally valid ES256 signature, using a throwaway P-256 key
// generated in-test.

func makeTestKey(t *testing.T) (*ecdsa.PrivateKey, APNsConfig) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	return key, APNsConfig{
		PrivateKeyPEM: string(pemBytes),
		KeyID:         "ABC123DEFG",
		TeamID:        "TEAM7654321",
		BundleID:      "com.mtkg.otegami",
	}
}

func base64urlDecode(t *testing.T, value string) []byte {
	t.Helper()
	data, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestJWTHasThreeSegments(t *testing.T) {
	_, config := makeTestKey(t)
	token, err := MakeToken(config, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if len(strings.Split(token, ".")) != 3 {
		t.Fatalf("got %q", token)
	}
}

func TestJWTHeaderShape(t *testing.T) {
	_, config := makeTestKey(t)
	token, err := MakeToken(config, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	var header map[string]any
	if err := json.Unmarshal(base64urlDecode(t, strings.Split(token, ".")[0]), &header); err != nil {
		t.Fatal(err)
	}
	if header["alg"] != "ES256" || header["kid"] != "ABC123DEFG" {
		t.Fatalf("got %+v", header)
	}
}

func TestJWTClaimsShape(t *testing.T) {
	_, config := makeTestKey(t)
	issuedAt := time.Now()
	token, err := MakeToken(config, issuedAt)
	if err != nil {
		t.Fatal(err)
	}
	var claims map[string]any
	if err := json.Unmarshal(base64urlDecode(t, strings.Split(token, ".")[1]), &claims); err != nil {
		t.Fatal(err)
	}
	if claims["iss"] != "TEAM7654321" {
		t.Fatalf("got %+v", claims)
	}
	if int64(claims["iat"].(float64)) != issuedAt.Unix() {
		t.Fatalf("got %+v", claims)
	}
}

func TestJWTSignatureIsValidRawES256(t *testing.T) {
	key, config := makeTestKey(t)
	token, err := MakeToken(config, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	segments := strings.Split(token, ".")
	signature := base64urlDecode(t, segments[2])
	// JWT ES256 wants the raw (r || s) 64-byte concatenation, not ASN.1
	// DER — same assertion the Swift test makes.
	if len(signature) != 64 {
		t.Fatalf("got %d signature bytes", len(signature))
	}
	digest := sha256.Sum256([]byte(segments[0] + "." + segments[1]))
	r := new(big.Int).SetBytes(signature[:32])
	sVal := new(big.Int).SetBytes(signature[32:])
	if !ecdsa.Verify(&key.PublicKey, digest[:], r, sVal) {
		t.Fatal("signature did not verify against the signing key")
	}
}

func TestJWTWrongKeySignatureIsRejected(t *testing.T) {
	key, _ := makeTestKey(t)
	_, otherConfig := makeTestKey(t)
	token, err := MakeToken(otherConfig, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	segments := strings.Split(token, ".")
	signature := base64urlDecode(t, segments[2])
	digest := sha256.Sum256([]byte(segments[0] + "." + segments[1]))
	r := new(big.Int).SetBytes(signature[:32])
	sVal := new(big.Int).SetBytes(signature[32:])
	if ecdsa.Verify(&key.PublicKey, digest[:], r, sVal) {
		t.Fatal("a different key's signature must not verify")
	}
}

func TestSandboxRoutesToSandboxHost(t *testing.T) {
	if Host(api.EnvironmentSandbox) != "api.sandbox.push.apple.com" {
		t.Fatal("sandbox host mismatch")
	}
}

func TestProductionRoutesToProductionHost(t *testing.T) {
	if Host(api.EnvironmentProduction) != "api.push.apple.com" {
		t.Fatal("production host mismatch")
	}
}

func TestAPNsBodyShape(t *testing.T) {
	data, err := json.Marshal(apnsBody{
		Aps:       apnsAPS{Alert: apnsAlert{LocKey: "NEW_MAIL"}, MutableContent: 1},
		AccountID: "account-1",
		UidNext:   42,
	})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"aps":{"alert":{"loc-key":"NEW_MAIL"},"mutable-content":1},"accountId":"account-1","uidNext":42}`
	if string(data) != want {
		t.Fatalf("got %s", data)
	}
}

func TestRedact(t *testing.T) {
	if got := Redact("abcdefghijkl"); got != "abcd…ijkl" {
		t.Fatalf("got %q", got)
	}
	if got := Redact("short"); got != "*****" {
		t.Fatalf("got %q", got)
	}
}

func TestSanitizeForLog(t *testing.T) {
	if got := SanitizeForLog("a\r\nforged log line\x7F"); got != "a??forged log line?" {
		t.Fatalf("got %q", got)
	}
}
