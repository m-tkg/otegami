// Package api holds the wire-format DTOs shared between the relay's HTTP
// API and the app (apps/Otegami, packages/OtegamiKit/Sources/OtegamiRelayAPI
// and PushRelayClient). Field names, JSON shapes, and the date encoding
// below MUST stay byte-for-byte compatible with the Swift
// OtegamiRelayAPI.swift package this mirrors — the app is not being
// changed as part of this port (Task #180), so any drift here breaks a
// client that's already shipped.
package api

import (
	"fmt"
	"strings"
	"time"
)

// wireTime formats/parses exactly like Swift's `JSONEncoder.dateEncodingStrategy
// = .iso8601` / `JSONDecoder.dateDecodingStrategy = .iso8601`, which is what
// Hummingbird's BasicRequestContext wires up for every JSON response/request
// in the Swift relay (see Hummingbird's RequestContext.swift). That
// strategy uses Foundation's ISO8601DateFormatter with the default
// `.withInternetDateTime` options: "yyyy-MM-dd'T'HH:mm:ssZ" — no fractional
// seconds, "Z" for UTC. This is exactly Go's time.RFC3339 format string.
type WireTime struct {
	time.Time
}

func NewWireTime(t time.Time) WireTime {
	return WireTime{Time: t.UTC()}
}

func (t WireTime) MarshalJSON() ([]byte, error) {
	if t.Time.IsZero() {
		return []byte("null"), nil
	}
	return []byte(`"` + t.Time.UTC().Format(time.RFC3339) + `"`), nil
}

func (t *WireTime) UnmarshalJSON(data []byte) error {
	s := strings.Trim(string(data), `"`)
	if s == "null" || s == "" {
		t.Time = time.Time{}
		return nil
	}
	// Accept RFC3339 with or without fractional seconds — lenient decoding,
	// same spirit as OtegamiRelayAPI's own leniency for fields that may be
	// absent from an older peer.
	parsed, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		parsed, err = time.Parse(time.RFC3339, s)
		if err != nil {
			return fmt.Errorf("wireTime: invalid ISO8601 timestamp %q: %w", s, err)
		}
	}
	t.Time = parsed.UTC()
	return nil
}

// Environment mirrors RegisterDeviceRequest.Environment.
type Environment string

const (
	EnvironmentSandbox    Environment = "sandbox"
	EnvironmentProduction Environment = "production"
)

// RegisterDeviceRequest is POST /v1/devices's request body.
type RegisterDeviceRequest struct {
	ApnsToken   string      `json:"apnsToken"`
	Environment Environment `json:"environment"`
}

// RegisterDeviceResponse is POST /v1/devices's response body.
type RegisterDeviceResponse struct {
	DeviceID     string `json:"deviceId"`
	DeviceSecret string `json:"deviceSecret"`
}

// UpdateDeviceTokenRequest is PUT /v1/devices/:id/token's request body.
type UpdateDeviceTokenRequest struct {
	ApnsToken   string      `json:"apnsToken"`
	Environment Environment `json:"environment"`
}

// WatchAuthKind mirrors WatchAuth.Kind.
type WatchAuthKind string

const (
	WatchAuthPassword WatchAuthKind = "password"
	WatchAuthOAuth    WatchAuthKind = "oauth"
)

// WatchAuthProvider mirrors WatchAuth.Provider.
type WatchAuthProvider string

const (
	ProviderGoogle    WatchAuthProvider = "google"
	ProviderMicrosoft WatchAuthProvider = "microsoft"
)

// WatchAuth mirrors WatchAuth.
type WatchAuth struct {
	Type     WatchAuthKind      `json:"type"`
	Secret   string             `json:"secret"`
	Provider *WatchAuthProvider `json:"provider,omitempty"`
}

// CreateWatchRequest is POST /v1/watches's request body.
type CreateWatchRequest struct {
	AccountID    string    `json:"accountId"`
	ImapHost     string    `json:"imapHost"`
	ImapPort     int       `json:"imapPort"`
	ImapUseTLS   bool      `json:"imapUseTLS"`
	ImapUsername string    `json:"imapUsername"`
	Auth         WatchAuth `json:"auth"`
	Mailbox      string    `json:"mailbox"`
}

// WatchResponse is the response to POST /v1/watches.
type WatchResponse struct {
	WatchID   string   `json:"watchId"`
	AccountID string   `json:"accountId"`
	Mailbox   string   `json:"mailbox"`
	CreatedAt WireTime `json:"createdAt"`
}

// PushNotificationPayload is the body of the (minimal) push payload.
type PushNotificationPayload struct {
	AccountID string `json:"accountId"`
	UidNext   int    `json:"uidNext"`
}

// WatchStatus mirrors WatchSummary.Status.
type WatchStatus string

const (
	WatchStatusActive  WatchStatus = "active"
	WatchStatusStopped WatchStatus = "stopped"
)

// WatchErrorKind mirrors WatchSummary.ErrorKind.
type WatchErrorKind string

const (
	ErrorKindAuthFailure       WatchErrorKind = "authFailure"
	ErrorKindConnectionError   WatchErrorKind = "connectionError"
	ErrorKindOAuthTokenExpired WatchErrorKind = "oauthTokenExpired"
)

// WatchSummary is one entry of GET /v1/watches's response.
type WatchSummary struct {
	WatchID         string          `json:"watchId"`
	AccountID       string          `json:"accountId"`
	ImapHost        string          `json:"imapHost"`
	Mailbox         string          `json:"mailbox"`
	CreatedAt       WireTime        `json:"createdAt"`
	Status          WatchStatus     `json:"status"`
	LastConnectedAt *WireTime       `json:"lastConnectedAt,omitempty"`
	LastErrorKind   *WatchErrorKind `json:"lastErrorKind,omitempty"`
	LastErrorAt     *WireTime       `json:"lastErrorAt,omitempty"`
}

// ListWatchesResponse is GET /v1/watches's response body.
type ListWatchesResponse struct {
	Watches []WatchSummary `json:"watches"`
}

// ErrorResponse is the uniform error body for every non-2xx relay response.
type ErrorResponse struct {
	Error   string `json:"error"`
	Message string `json:"message"`
}
