package httpapi

import (
	"context"
	"errors"
	"net/http"

	"github.com/m-tkg/otegami-relay-go/internal/api"
	"github.com/m-tkg/otegami-relay-go/internal/security"
	"github.com/m-tkg/otegami-relay-go/internal/store"
)

// watchStore is the subset of *store.Store the watch routes need, plus
// deviceStore (both are satisfied by *store.Store).
type watchStore interface {
	deviceStore
	CreateWatch(ctx context.Context, deviceID string, req api.CreateWatchRequest) (api.WatchResponse, error)
	// DeleteWatch's watchFullyRemoved return (Task #208) tells the route
	// whether the underlying watch has no subscribers left at all (so the
	// watcher pool loop should actually stop) or other devices still
	// subscribe to the same shared IMAP connection (so it must keep
	// running).
	DeleteWatch(ctx context.Context, id, deviceID string) (watchFullyRemoved bool, err error)
	ListWatchSummaries(ctx context.Context, deviceID string) ([]api.WatchSummary, error)
}

// watcherPool is what WatchRoutes needs from the watcher pool — kept as an
// interface so httpapi doesn't need to import the concrete watcher
// implementation (mirrors how the Swift routes only call
// WatcherPool.addWatch/removeWatch, never anything IMAP-specific).
type watcherPool interface {
	AddWatch(id string)
	RemoveWatch(id string)
}

// registerWatchRoutes wires POST /v1/watches, DELETE /v1/watches/:id, and
// GET /v1/watches — mirrors WatchRoutes.register(on:store:watcherPool:networkPolicy:).
func registerWatchRoutes(mux *http.ServeMux, s watchStore, pool watcherPool, networkPolicy security.NetworkPolicy) {
	mux.HandleFunc("POST /v1/watches", func(w http.ResponseWriter, r *http.Request) {
		deviceID, httpErr := authenticatedDeviceID(r, s)
		if httpErr != nil {
			writeError(w, httpErr)
			return
		}
		var body api.CreateWatchRequest
		if err := decodeJSON(r, &body); err != nil {
			writeError(w, err)
			return
		}
		// Swift's Codable decoding rejects an unknown auth.type/provider
		// raw value, and a missing mailbox key, with a 400 — Go's
		// string-typed enums and zero values accept them, so validate
		// explicitly for identical behavior.
		if body.Auth.Type != api.WatchAuthPassword && body.Auth.Type != api.WatchAuthOAuth {
			writeError(w, badRequest("invalid JSON request body"))
			return
		}
		if body.Auth.Provider != nil && *body.Auth.Provider != api.ProviderGoogle && *body.Auth.Provider != api.ProviderMicrosoft {
			writeError(w, badRequest("invalid JSON request body"))
			return
		}
		if body.Mailbox == "" {
			writeError(w, badRequest("invalid JSON request body"))
			return
		}
		if body.ImapHost == "" || body.ImapUsername == "" || body.Auth.Secret == "" {
			writeError(w, badRequest("imapHost, imapUsername, and auth.secret are required"))
			return
		}
		// Task #175: .oauth must carry a provider.
		if body.Auth.Type == api.WatchAuthOAuth && body.Auth.Provider == nil {
			writeError(w, badRequest("auth.provider is required when auth.type is oauth"))
			return
		}

		// CLAUDE-SECURITY F3: reject (not escape) CR/LF/NUL/other control
		// characters before anything is persisted.
		if err := security.ValidateNoControlCharacters(body.ImapUsername, "imapUsername"); err != nil {
			writeError(w, badRequest(err.Error()))
			return
		}
		if err := security.ValidateNoControlCharacters(body.Auth.Secret, "auth.secret"); err != nil {
			writeError(w, badRequest(err.Error()))
			return
		}
		if err := security.ValidateNoControlCharacters(body.Mailbox, "mailbox"); err != nil {
			writeError(w, badRequest(err.Error()))
			return
		}

		// CLAUDE-SECURITY F16: bound accountId to a safe charset before
		// it's ever persisted or logged.
		if err := validateAccountID(body.AccountID); err != nil {
			writeError(w, badRequest(err.Error()))
			return
		}

		// CLAUDE-SECURITY F2: resolve + validate host/port before
		// persisting or opening any connection.
		if err := networkPolicy.ValidatePort(body.ImapPort); err != nil {
			writeError(w, badRequest(err.Error()))
			return
		}
		if _, err := networkPolicy.ResolveAndValidate(body.ImapHost, body.ImapPort); err != nil {
			writeError(w, badRequest(err.Error()))
			return
		}

		resp, err := s.CreateWatch(r.Context(), deviceID, body)
		if err != nil {
			writeError(w, badRequest("could not create watch"))
			return
		}
		pool.AddWatch(resp.WatchID)
		writeJSON(w, http.StatusCreated, resp)
	})

	mux.HandleFunc("DELETE /v1/watches/{id}", func(w http.ResponseWriter, r *http.Request) {
		deviceID, httpErr := authenticatedDeviceID(r, s)
		if httpErr != nil {
			writeError(w, httpErr)
			return
		}
		watchID := r.PathValue("id")
		watchFullyRemoved, err := s.DeleteWatch(r.Context(), watchID, deviceID)
		if errors.Is(err, store.ErrWatchNotFound) {
			writeError(w, notFound("watch not found"))
			return
		}
		if err != nil {
			writeError(w, badRequest("could not delete watch"))
			return
		}
		// Task #208: only stop the watcher pool's loop once nobody
		// subscribes to it anymore — another device may still be relying
		// on this exact same IMAP connection.
		if watchFullyRemoved {
			pool.RemoveWatch(watchID)
		}
		w.WriteHeader(http.StatusNoContent)
	})

	// M9 follow-up: lets the app reconcile its local account/watch state
	// against the relay's ground truth on launch/foreground. Never
	// returns a credential, only what api.WatchSummary exposes.
	mux.HandleFunc("GET /v1/watches", func(w http.ResponseWriter, r *http.Request) {
		deviceID, httpErr := authenticatedDeviceID(r, s)
		if httpErr != nil {
			writeError(w, httpErr)
			return
		}
		summaries, err := s.ListWatchSummaries(r.Context(), deviceID)
		if err != nil {
			writeError(w, badRequest("could not list watches"))
			return
		}
		writeJSON(w, http.StatusOK, api.ListWatchesResponse{Watches: summaries})
	})
}

// accountIDAllowedCharacters mirrors WatchRoutes.accountIdAllowedCharacters
// — the relay's own generated ids' base64url alphabet plus real-world
// UUID-shaped ids.
func isAccountIDAllowedRune(r rune) bool {
	switch {
	case r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z', r >= '0' && r <= '9':
		return true
	case r == '_' || r == '-':
		return true
	default:
		return false
	}
}

// validateAccountID mirrors WatchRoutes.validateAccountId(_:).
func validateAccountID(accountID string) error {
	if accountID == "" || len([]rune(accountID)) > 128 {
		return errAccountID
	}
	for _, r := range accountID {
		if !isAccountIDAllowedRune(r) {
			return errAccountID
		}
	}
	return nil
}

var errAccountID = errors.New("accountId must be 1-128 characters from [A-Za-z0-9_-]")
