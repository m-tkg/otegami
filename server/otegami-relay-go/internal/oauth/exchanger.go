// Package oauth exchanges a stored OAuth refresh token for a short-lived
// access token, right before an .oauth watch's IMAP AUTHENTICATE XOAUTH2 —
// mirrors the retired Swift relay's OAuthTokenExchanger (Task #175). The
// access token is never persisted anywhere (the store only
// ever holds the refresh token, encrypted, same as an IMAP password): each
// (re)connect calls this again.
//
// Neither provider's refresh grant needs a client secret here: Google's
// "iOS" OAuth client type (docs/oauth-setup.md) has none at all, and
// Microsoft's "public client" app registration is the same "no secret,
// PKCE instead" shape — the refresh step only ever needs
// client_id+refresh_token+grant_type (Microsoft's also repeats scope).
package oauth

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/m-tkg/otegami-relay-go/internal/api"
)

// Errors mirror OAuthTokenExchangeError. The watcher pool's
// classifyAuthFailure maps these onto api.WatchErrorKind — ErrInvalidGrant
// is the one case that stops the watch immediately (a dead refresh token
// never recovers on its own); every other case is treated as transient and
// retried with backoff, same as an IMAP connection error.

// MissingClientIDError mirrors .missingClientId — an operator setup gap,
// not something retrying will fix, but kept non-fatal (classified the same
// as connectionError) so a relay serving both password and OAuth watches
// doesn't need every provider configured to keep working at all.
type MissingClientIDError struct{ Provider api.WatchAuthProvider }

func (e *MissingClientIDError) Error() string {
	return fmt.Sprintf("no OAuth client id configured for %s (RELAY_GOOGLE_CLIENT_ID/RELAY_MICROSOFT_CLIENT_ID)", e.Provider)
}

// ErrInvalidGrant mirrors .invalidGrant — the provider's token endpoint
// rejected the refresh token itself (revoked, expired, or the user removed
// the app's access). Permanently dead; only re-authenticating in the app
// mints a new one.
var ErrInvalidGrant = errInvalidGrant{}

type errInvalidGrant struct{}

func (errInvalidGrant) Error() string { return "refresh token was rejected (invalid_grant)" }

// TokenRequestFailedError mirrors .tokenRequestFailed — a non-2xx response
// that isn't invalid_grant (rate limiting, endpoint outage, ...).
type TokenRequestFailedError struct{ Status int }

func (e *TokenRequestFailedError) Error() string {
	return fmt.Sprintf("token endpoint returned %d", e.Status)
}

// ErrInvalidResponse mirrors .invalidResponse — a 2xx response that didn't
// parse as the expected token JSON shape.
var ErrInvalidResponse = errInvalidResponse{}

type errInvalidResponse struct{}

func (errInvalidResponse) Error() string {
	return "token endpoint returned a response that couldn't be decoded"
}

// NetworkError mirrors .network — couldn't reach the token endpoint at all.
type NetworkError struct{ Err error }

func (e *NetworkError) Error() string {
	return fmt.Sprintf("network error reaching the token endpoint: %v", e.Err)
}
func (e *NetworkError) Unwrap() error { return e.Err }

// TokenExchanger mirrors the OAuthTokenExchanging protocol — the watcher
// pool depends on this interface, never on the concrete Exchanger, so its
// tests can inject a scripted fake.
type TokenExchanger interface {
	AccessToken(ctx context.Context, provider api.WatchAuthProvider, refreshToken string) (string, error)
}

// Unconfigured mirrors UnconfiguredOAuthTokenExchanger — the watcher
// pool's default when no exchanger is supplied: every call fails with
// MissingClientIDError, which classifyAuthFailure treats as a
// connectionError (retried with backoff, not stopped instantly). Never
// reached by a .password watch.
type Unconfigured struct{}

func (Unconfigured) AccessToken(_ context.Context, provider api.WatchAuthProvider, _ string) (string, error) {
	return "", &MissingClientIDError{Provider: provider}
}

// Transport is the one HTTP call Exchanger needs, factored out as its own
// narrow interface so tests can inject a canned response instead of
// hitting Google/Microsoft's real token endpoints (mirrors
// OAuthHTTPTransport).
type Transport interface {
	Post(ctx context.Context, url, formBody string) (status int, body []byte, err error)
}

// Exchanger is the real implementation, mirroring OAuthTokenExchanger.
type Exchanger struct {
	transport         Transport
	googleClientID    string
	microsoftClientID string
}

// New builds an Exchanger. Empty client ids mean the corresponding
// provider can never authenticate (MissingClientIDError at exchange time).
func New(transport Transport, googleClientID, microsoftClientID string) *Exchanger {
	return &Exchanger{transport: transport, googleClientID: googleClientID, microsoftClientID: microsoftClientID}
}

// AccessToken mirrors OAuthTokenExchanger.accessToken(provider:refreshToken:).
func (e *Exchanger) AccessToken(ctx context.Context, provider api.WatchAuthProvider, refreshToken string) (string, error) {
	var tokenURL string
	parameters := map[string]string{"refresh_token": refreshToken, "grant_type": "refresh_token"}

	switch provider {
	case api.ProviderGoogle:
		if e.googleClientID == "" {
			return "", &MissingClientIDError{Provider: api.ProviderGoogle}
		}
		tokenURL = "https://oauth2.googleapis.com/token"
		parameters["client_id"] = e.googleClientID
	case api.ProviderMicrosoft:
		if e.microsoftClientID == "" {
			return "", &MissingClientIDError{Provider: api.ProviderMicrosoft}
		}
		tokenURL = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
		parameters["client_id"] = e.microsoftClientID
		// Mirrors MicrosoftOAuthEndpoints.standard(clientId:)'s scope —
		// Microsoft's refresh grant repeats the scope the original
		// authorization grant used.
		parameters["scope"] = "https://outlook.office.com/IMAP.AccessAsUser.All offline_access"
	default:
		return "", &MissingClientIDError{Provider: provider}
	}

	status, body, err := e.transport.Post(ctx, tokenURL, FormEncode(parameters))
	if err != nil {
		return "", &NetworkError{Err: err}
	}

	if status < 200 || status >= 300 {
		var errorBody struct {
			Error string `json:"error"`
		}
		if json.Unmarshal(body, &errorBody) == nil && errorBody.Error == "invalid_grant" {
			return "", ErrInvalidGrant
		}
		return "", &TokenRequestFailedError{Status: status}
	}
	var success struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &success); err != nil || success.AccessToken == "" {
		return "", ErrInvalidResponse
	}
	return success.AccessToken, nil
}

// FormEncode mirrors OAuthTokenExchanger.formEncode(_:) —
// application/x-www-form-urlencoded body encoding, percent-encoding each
// pair per RFC 3986's unreserved set (alphanumerics plus "-._~"), rather
// than Go's url.Values.Encode (which encodes a space as "+"). Keys are
// sorted for determinism (Swift's dictionary order is arbitrary; nothing
// depends on ordering).
func FormEncode(parameters map[string]string) string {
	keys := make([]string, 0, len(parameters))
	for key := range parameters {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	pairs := make([]string, 0, len(keys))
	for _, key := range keys {
		pairs = append(pairs, percentEncode(key)+"="+percentEncode(parameters[key]))
	}
	return strings.Join(pairs, "&")
}

func percentEncode(value string) string {
	var b strings.Builder
	for _, byteValue := range []byte(value) {
		if isUnreserved(byteValue) {
			b.WriteByte(byteValue)
		} else {
			b.WriteString(fmt.Sprintf("%%%02X", byteValue))
		}
	}
	return b.String()
}

func isUnreserved(b byte) bool {
	switch {
	case b >= 'A' && b <= 'Z', b >= 'a' && b <= 'z', b >= '0' && b <= '9':
		return true
	case b == '-' || b == '.' || b == '_' || b == '~':
		return true
	default:
		return false
	}
}

// HTTPTransport is the production Transport: a single net/http POST with a
// 15-second timeout and a 1MB response-body bound (same posture as the
// IMAP client's maxUntaggedBytesPerCommand — a misbehaving/compromised
// endpoint can't grow the relay's memory unbounded). Mirrors
// AsyncHTTPClientOAuthTransport.
type HTTPTransport struct {
	Client *http.Client
}

// NewHTTPTransport builds an HTTPTransport with the 15s request timeout
// the Swift transport uses.
func NewHTTPTransport() *HTTPTransport {
	return &HTTPTransport{Client: &http.Client{Timeout: 15 * time.Second}}
}

func (t *HTTPTransport) Post(ctx context.Context, url, formBody string) (int, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, strings.NewReader(formBody))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("content-type", "application/x-www-form-urlencoded")
	resp, err := t.Client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1024*1024))
	if err != nil {
		return 0, nil, err
	}
	return resp.StatusCode, body, nil
}
