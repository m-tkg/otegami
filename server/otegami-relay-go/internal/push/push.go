// Package push delivers the relay's minimal new-mail notification to APNs.
package push

import (
	"context"
	"log/slog"
	"strings"

	"github.com/m-tkg/otegami-relay-go/internal/api"
)

// Sender mirrors the PushSending protocol: "deliver this payload to this
// device via APNs". Implementations should not return an error for
// ordinary APNs-reported delivery failures (e.g. an expired token) — the
// watcher pool isn't in a position to usefully react beyond logging, so
// implementations log instead and only error for programmer-error-shaped
// conditions (bad configuration).
type Sender interface {
	Send(ctx context.Context, deviceToken string, environment api.Environment, payload api.PushNotificationPayload) error
}

// ConsoleSender mirrors ConsolePushSender — the fallback used whenever the
// APNS_* env vars aren't configured: logs what would have been sent
// instead of actually contacting APNs, letting a self-hoster run the full
// watch → IDLE → "push fires" pipeline end to end without an Apple
// Developer account or .p8 key.
type ConsoleSender struct {
	Logger *slog.Logger
}

func (s *ConsoleSender) Send(_ context.Context, deviceToken string, environment api.Environment, payload api.PushNotificationPayload) error {
	s.Logger.Info("[console-push] would deliver push",
		"deviceToken", Redact(deviceToken),
		"environment", string(environment),
		"accountId", SanitizeForLog(payload.AccountID),
		"uidNext", payload.UidNext,
	)
	return nil
}

// Redact never logs a full device token — only enough to eyeball "yes,
// this looks like the token I registered" in container logs. Mirrors
// ConsolePushSender.redact/APNsSender.redact.
func Redact(token string) string {
	if len(token) <= 8 {
		return strings.Repeat("*", len(token))
	}
	return token[:4] + "…" + token[len(token)-4:]
}

// SanitizeForLog is CLAUDE-SECURITY F16's second, independent backstop
// against log-record forgery: replaces (never strips — a forgery attempt
// stays visible as mangled text) any C0 control character or DEL with "?".
// accountId is already validated at POST /v1/watches time; this covers any
// value that reaches a log line by a path that skips that validation.
func SanitizeForLog(value string) string {
	var b strings.Builder
	for _, r := range value {
		if r < 0x20 || r == 0x7F {
			b.WriteRune('?')
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}
