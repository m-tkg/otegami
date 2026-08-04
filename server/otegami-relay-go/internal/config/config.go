// Package config reads everything the relay needs from the environment at
// startup, mirroring the retired Swift relay's RelayConfiguration exactly —
// env var names and defaults must stay identical (Task #180's
// requirement 9) so an operator's existing .env/docker-compose.yml works
// unchanged against this binary.
package config

import (
	"errors"
	"os"
	"strconv"
	"strings"

	"github.com/m-tkg/otegami-relay-go/internal/security"
)

// ErrMissingMasterKey mirrors
// RelayConfiguration.ConfigurationError.missingMasterKey.
var ErrMissingMasterKey = errors.New(
	"RELAY_MASTER_KEY is not set. Generate a 32-byte base64 key with " +
		"`openssl rand -base64 32` and set it in the environment before " +
		"starting the relay — see docs/relay-deployment.md.",
)

// APNsConfig mirrors RelayConfiguration.APNsConfig.
type APNsConfig struct {
	KeyPath  string
	KeyID    string
	TeamID   string
	BundleID string
}

// Config mirrors RelayConfiguration.
type Config struct {
	MasterKeyBase64          string
	DatabasePath             string
	APNs                     *APNsConfig
	Port                     int
	NetworkPolicy            security.NetworkPolicy
	DeviceRegistrationSecret string
	GoogleOAuthClientID      string
	MicrosoftOAuthClientID   string
	// ContentPreviewEnabled (RELAY_CONTENT_PREVIEW, Phase 2) opts into
	// fetching and caching real message content (sender/subject/body
	// snippet) on new-mail detection, and exposing it via GET
	// /v1/messages and richer push payload fields. Defaults to false — the
	// relay's existing design (docs/relay-deployment.md "リレーが何をする
	// か") never touches mail content unless an operator explicitly opts
	// in.
	ContentPreviewEnabled bool
}

// FromEnvironment mirrors RelayConfiguration.fromEnvironment(_:). Pass
// os.Getenv (or a stub, in tests) as getenv.
func FromEnvironment(getenv func(string) string) (Config, error) {
	masterKey := getenv("RELAY_MASTER_KEY")
	if masterKey == "" {
		return Config{}, ErrMissingMasterKey
	}

	databasePath := getenv("RELAY_DATABASE_PATH")
	if databasePath == "" {
		databasePath = "otegami-relay.sqlite"
	}
	port := 8080
	if raw := getenv("RELAY_PORT"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil {
			port = parsed
		}
	}

	var apns *APNsConfig
	keyPath := getenv("APNS_KEY_PATH")
	keyID := getenv("APNS_KEY_ID")
	teamID := getenv("APNS_TEAM_ID")
	bundleID := getenv("APNS_BUNDLE_ID")
	if keyPath != "" && keyID != "" && teamID != "" && bundleID != "" {
		apns = &APNsConfig{KeyPath: keyPath, KeyID: keyID, TeamID: teamID, BundleID: bundleID}
	}

	// Same "1"/"true"/"yes", case-insensitive parsing as
	// RELAY_ALLOW_PRIVATE_IMAP_HOSTS (security.FromEnvironment) — kept
	// consistent across every relay boolean env var.
	contentPreviewRaw := strings.ToLower(getenv("RELAY_CONTENT_PREVIEW"))
	contentPreviewEnabled := contentPreviewRaw == "1" || contentPreviewRaw == "true" || contentPreviewRaw == "yes"

	return Config{
		MasterKeyBase64:          masterKey,
		DatabasePath:             databasePath,
		APNs:                     apns,
		Port:                     port,
		NetworkPolicy:            security.FromEnvironment(getenv),
		DeviceRegistrationSecret: getenv("RELAY_DEVICE_REGISTRATION_SECRET"),
		GoogleOAuthClientID:      getenv("RELAY_GOOGLE_CLIENT_ID"),
		MicrosoftOAuthClientID:   getenv("RELAY_MICROSOFT_CLIENT_ID"),
		ContentPreviewEnabled:    contentPreviewEnabled,
	}, nil
}

// FromOSEnvironment is FromEnvironment(os.Getenv), the production entry
// point.
func FromOSEnvironment() (Config, error) {
	return FromEnvironment(os.Getenv)
}
