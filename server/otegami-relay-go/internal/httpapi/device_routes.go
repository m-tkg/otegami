package httpapi

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/m-tkg/otegami-relay-go/internal/api"
	"github.com/m-tkg/otegami-relay-go/internal/store"
)

// deviceStore is the subset of *store.Store the device/watch routes need —
// kept as an interface (rather than importing *store.Store directly in
// signatures used by tests) purely for parity with the retired Swift
// relay's dependency-injected RelayStore route tests.
type deviceStore interface {
	CreateDevice(ctx context.Context, apnsToken string, environment api.Environment) (api.RegisterDeviceResponse, error)
	UpdateDeviceToken(ctx context.Context, id, apnsToken string, environment api.Environment) error
	DeviceIDForSecret(ctx context.Context, secret string) (string, bool, error)
}

// registerDeviceRoutes wires POST /v1/devices and PUT /v1/devices/:id/token
// — mirrors DeviceRoutes.register(on:store:registrationSecret:logger:).
//
//   - registrationSecret: CLAUDE-SECURITY F2 — when set (operator env var
//     RELAY_DEVICE_REGISTRATION_SECRET), POST /v1/devices requires it as a
//     bearer token. Empty string (the default, historical behavior) keeps
//     registration open — see authorizeRegistration's doc comment.
func registerDeviceRoutes(mux *http.ServeMux, s deviceStore, registrationSecret string, logger *slog.Logger) {
	mux.HandleFunc("POST /v1/devices", func(w http.ResponseWriter, r *http.Request) {
		if err := authorizeRegistration(r, registrationSecret, logger); err != nil {
			writeError(w, err)
			return
		}
		var body api.RegisterDeviceRequest
		if err := decodeJSON(r, &body); err != nil {
			writeError(w, err)
			return
		}
		// Swift's Codable decoding rejects an unknown enum raw value with
		// a 400 — Go's string-typed Environment accepts anything, so
		// validate explicitly for identical behavior.
		if !validEnvironment(body.Environment) {
			writeError(w, badRequest("invalid JSON request body"))
			return
		}
		resp, err := s.CreateDevice(r.Context(), body.ApnsToken, body.Environment)
		if err != nil {
			writeError(w, badRequest("could not create device"))
			return
		}
		writeJSON(w, http.StatusCreated, resp)
	})

	mux.HandleFunc("PUT /v1/devices/{id}/token", func(w http.ResponseWriter, r *http.Request) {
		pathID := r.PathValue("id")
		deviceID, httpErr := authenticatedDeviceID(r, s)
		if httpErr != nil {
			writeError(w, httpErr)
			return
		}
		if deviceID != pathID {
			writeError(w, unauthorized(""))
			return
		}
		var body api.UpdateDeviceTokenRequest
		if err := decodeJSON(r, &body); err != nil {
			writeError(w, err)
			return
		}
		if !validEnvironment(body.Environment) {
			writeError(w, badRequest("invalid JSON request body"))
			return
		}
		err := s.UpdateDeviceToken(r.Context(), deviceID, body.ApnsToken, body.Environment)
		if errors.Is(err, store.ErrDeviceNotFound) {
			writeError(w, notFound("device not found"))
			return
		}
		if err != nil {
			writeError(w, badRequest("could not update device"))
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
}

// validEnvironment mirrors Swift Codable's enum raw-value validation for
// RegisterDeviceRequest.Environment — an unrecognized value is a decode
// failure (400) there, so it must be here too.
func validEnvironment(e api.Environment) bool {
	return e == api.EnvironmentSandbox || e == api.EnvironmentProduction
}

// authorizeRegistration mirrors DeviceRoutes.authorizeRegistration — see
// its doc comment (CLAUDE-SECURITY F2) for the full rationale on why an
// unset registrationSecret keeps registration open rather than breaking
// existing deployments.
func authorizeRegistration(r *http.Request, registrationSecret string, logger *slog.Logger) *httpError {
	if registrationSecret == "" {
		logger.Warn("POST /v1/devices accepted an unauthenticated device registration " +
			"(RELAY_DEVICE_REGISTRATION_SECRET is not set) — anyone who can reach this " +
			"relay's HTTP port can self-register a device and create watches. See " +
			"docs/relay-deployment.md's threat model section.")
		return nil
	}
	const prefix = "Bearer "
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, prefix) || !store.ConstantTimeEquals(strings.TrimPrefix(header, prefix), registrationSecret) {
		return unauthorized("device registration requires a valid registration secret")
	}
	return nil
}

// authenticatedDeviceID mirrors authenticatedDeviceId(request:store:) —
// shared bearer-auth resolution used by every device-scoped route.
func authenticatedDeviceID(r *http.Request, s deviceStore) (string, *httpError) {
	header := r.Header.Get("Authorization")
	if header == "" {
		return "", unauthorized("missing Authorization header")
	}
	const prefix = "Bearer "
	if !strings.HasPrefix(header, prefix) {
		return "", unauthorized("Authorization header must be a Bearer token")
	}
	secret := strings.TrimPrefix(header, prefix)
	deviceID, ok, err := s.DeviceIDForSecret(r.Context(), secret)
	if err != nil || !ok {
		return "", unauthorized("")
	}
	return deviceID, nil
}
