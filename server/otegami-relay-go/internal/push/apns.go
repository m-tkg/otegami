package push

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/golang-jwt/jwt/v5"

	"github.com/m-tkg/otegami-relay-go/internal/api"
)

// APNsConfig mirrors APNsSender.Configuration.
type APNsConfig struct {
	// PrivateKeyPEM is the contents of the .p8 file
	// (PEM, -----BEGIN PRIVATE KEY-----…).
	PrivateKeyPEM string
	// KeyID is the Key ID shown next to the key in App Store Connect.
	KeyID string
	// TeamID is the Apple Developer Team ID.
	TeamID string
	// BundleID is apns-topic — the app's bundle id (Notification Service
	// Extension pushes use the main app's bundle id, not the extension's).
	BundleID string
}

// APNsSender mirrors APNsSender.swift: real APNs delivery over HTTP/2
// (Go's net/http negotiates HTTP/2 via ALPN automatically for https),
// token-based (.p8/ES256 JWT) authentication. Never exercised against real
// APNs in this repo's test suite (no .p8 key has been issued);
// what IS tested is the JWT header/claims shape and ES256 signature format
// (apns_test.go), same as the Swift APNsSenderTests.
type APNsSender struct {
	config APNsConfig
	client *http.Client
	logger *slog.Logger

	// JWT cache: signed tokens are valid up to 60 minutes; refresh at 50
	// to leave headroom (mirrors APNsSender.JWTCache).
	mu          sync.Mutex
	cachedToken string
	issuedAt    time.Time
}

// NewAPNsSender builds an APNsSender. client may be nil (a default client
// with a 10s timeout is used, matching the Swift sender's per-request
// timeout).
func NewAPNsSender(config APNsConfig, client *http.Client, logger *slog.Logger) *APNsSender {
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	return &APNsSender{config: config, client: client, logger: logger}
}

// Host mirrors APNsSender.host(for:) — which APNs endpoint a device's
// registered environment routes to.
func Host(environment api.Environment) string {
	if environment == api.EnvironmentProduction {
		return "api.push.apple.com"
	}
	return "api.sandbox.push.apple.com"
}

// apnsBody mirrors APNsSender.APNsBody — the original minimal payload
// shape (plan §7: mutable-content, loc-key NEW_MAIL, accountId, uidNext)
// plus, when RELAY_CONTENT_PREVIEW=1 and this cycle's fetch succeeded, the
// api.PushNotificationPayload preview fields (latest message's sender/
// subject/uid, previewCount) — see that type's doc comment for why only
// the newest message's fields fit here at all. Every field but
// accountId/uidNext is omitempty so a preview-disabled relay's payload
// shape is byte-for-byte unchanged from before this feature existed.
// accountId/uidNext live outside aps at the top level; NotificationService
// reads them from there.
type apnsBody struct {
	Aps               apnsAPS `json:"aps"`
	AccountID         string  `json:"accountId"`
	UidNext           int     `json:"uidNext"`
	LatestUID         int64   `json:"latestUid,omitempty"`
	LatestFromName    string  `json:"latestFromName,omitempty"`
	LatestFromAddress string  `json:"latestFromAddress,omitempty"`
	LatestSubject     string  `json:"latestSubject,omitempty"`
	PreviewCount      int     `json:"previewCount,omitempty"`
}

// maxAPNsBodyBytes leaves headroom under APNs' 4KB (4096-byte) whole-JSON-
// body limit for a push whose latestSubject/latestFromName came from an
// attacker-influenced mail header (CLAUDE-SECURITY-adjacent: an absurdly
// long subject, or one whose characters JSON-escape expensively, must
// degrade this one push's content richness — via buildAPNsBody's shrink
// loop — rather than fail the whole send).
const maxAPNsBodyBytes = 3500

// buildAPNsBody marshals payload into the APNs JSON body, halving
// latestSubject then latestFromName (in that order — subject first, since
// a device notification banner shows less of it anyway) until the result
// fits under maxAPNsBodyBytes. The caller (Send) already sends a payload
// whose subject/fromName were capped well under this limit at the source
// (pool.go's fire()), so this is a defensive backstop, not the normal
// path — it only bites when JSON-escaping (control characters, certain
// Unicode) expands an already-capped field enough to matter.
func buildAPNsBody(payload api.PushNotificationPayload) ([]byte, error) {
	working := payload
	for {
		data, err := json.Marshal(apnsBody{
			Aps:               apnsAPS{Alert: apnsAlert{LocKey: "NEW_MAIL"}, MutableContent: 1, Category: notificationCategory},
			AccountID:         working.AccountID,
			UidNext:           working.UidNext,
			LatestUID:         working.LatestUID,
			LatestFromName:    working.LatestFromName,
			LatestFromAddress: working.LatestFromAddress,
			LatestSubject:     working.LatestSubject,
			PreviewCount:      working.PreviewCount,
		})
		if err != nil {
			return nil, err
		}
		if len(data) <= maxAPNsBodyBytes {
			return data, nil
		}
		switch {
		case working.LatestSubject != "":
			working.LatestSubject = halveUTF8(working.LatestSubject)
		case working.LatestFromName != "":
			working.LatestFromName = halveUTF8(working.LatestFromName)
		default:
			// Nothing left worth shrinking (accountId is already capped to
			// 128 chars at watch-creation time; fromAddress/messageId-shaped
			// fields are never long enough on their own to matter) — give
			// up and let this still-oversized body go to APNs, which will
			// itself reject it. Looping forever is worse than one rejected
			// push.
			return data, nil
		}
	}
}

// halveUTF8 returns roughly the first half of s, never splitting a
// multi-byte rune. Repeated halving (buildAPNsBody's shrink loop) always
// terminates: a non-empty string strictly shrinks each call, reaching ""
// in at most len(s) steps.
func halveUTF8(s string) string {
	if s == "" {
		return s
	}
	b := s[:len(s)/2]
	for len(b) > 0 && !utf8.RuneStart(b[len(b)-1]) {
		b = b[:len(b)-1]
	}
	return b
}

// notificationCategory is the aps.category value APNs delivers for
// mutable-content mail pushes. Must match the UNNotificationCategory
// identifier registered app-side in
// apps/Otegami/Sources/Support/PushNotificationActionCategory.swift — that
// registration is what makes iOS show the "既読にする"/"アーカイブ" action
// buttons on a long-press of the notification.
const notificationCategory = "NEW_MAIL_ACTIONS"

type apnsAPS struct {
	Alert          apnsAlert `json:"alert"`
	MutableContent int       `json:"mutable-content"`
	Category       string    `json:"category"`
}

type apnsAlert struct {
	LocKey string `json:"loc-key"`
}

// Send mirrors APNsSender.send(deviceToken:environment:payload:).
func (s *APNsSender) Send(ctx context.Context, deviceToken string, environment api.Environment, payload api.PushNotificationPayload) error {
	token, err := s.currentToken()
	if err != nil {
		return err
	}

	bodyData, err := buildAPNsBody(payload)
	if err != nil {
		return err
	}

	url := fmt.Sprintf("https://%s/3/device/%s", Host(environment), deviceToken)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(bodyData))
	if err != nil {
		return err
	}
	req.Header.Set("authorization", "bearer "+token)
	req.Header.Set("apns-topic", s.config.BundleID)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")
	req.Header.Set("content-type", "application/json")

	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// Collect the JSON error body APNs sends on failure (e.g.
		// {"reason":"BadDeviceToken"}) — the status code alone doesn't
		// distinguish "token is stale, re-register" from "our JWT/topic is
		// misconfigured".
		bodyText, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		s.logger.Warn("APNs push rejected",
			"status", resp.StatusCode,
			"accountId", SanitizeForLog(payload.AccountID),
			"deviceToken", Redact(deviceToken),
			"body", SanitizeForLog(string(bodyText)),
		)
		return nil
	}
	s.logger.Info("APNs push accepted",
		"accountId", SanitizeForLog(payload.AccountID),
		"uidNext", payload.UidNext,
		"deviceToken", Redact(deviceToken),
		"environment", string(environment),
	)
	return nil
}

func (s *APNsSender) currentToken() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	if s.cachedToken != "" && now.Sub(s.issuedAt) < 50*time.Minute {
		return s.cachedToken, nil
	}
	token, err := MakeToken(s.config, now)
	if err != nil {
		return "", err
	}
	s.cachedToken = token
	s.issuedAt = now
	return token, nil
}

// MakeToken builds the ES256 JWT APNs' token-based auth expects
// (Authorization: bearer <jwt>), mirroring APNsJWT.makeToken. Exported (and
// taking issuedAt explicitly) so apns_test.go can verify the header/claims
// shape and signature format with a throwaway P-256 key, without any HTTP
// round trip — same testing posture as the Swift APNsSenderTests.
func MakeToken(config APNsConfig, issuedAt time.Time) (string, error) {
	privateKey, err := jwt.ParseECPrivateKeyFromPEM([]byte(config.PrivateKeyPEM))
	if err != nil {
		return "", fmt.Errorf("APNS_KEY_PATH does not contain a valid EC private key: %w", err)
	}
	token := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{
		"iss": config.TeamID,
		"iat": issuedAt.Unix(),
	})
	token.Header["kid"] = config.KeyID
	return token.SignedString(privateKey)
}
