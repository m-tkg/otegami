// Package httpapi is the relay's HTTP surface: POST /v1/devices, PUT
// /v1/devices/:id/token, POST /v1/watches, GET /v1/watches, DELETE
// /v1/watches/:id, GET /health. Mirrors App.swift's buildRouter +
// Routes/DeviceRoutes.swift + Routes/WatchRoutes.swift — every status
// code, JSON field name, and auth rule is intentionally identical so the
// existing app client (packages/OtegamiKit/Sources/PushRelayClient,
// OtegamiRelayAPI) needs zero changes to talk to this Go relay instead of
// the Swift one (Task #180).
package httpapi

import (
	"log/slog"
	"net/http"

	"github.com/m-tkg/otegami-relay-go/internal/security"
)

// Store is the full persistence surface the router needs — satisfied by
// *store.Store in production, and by a lightweight fake in router tests.
type Store interface {
	watchStore
	messageStore
}

// NewRouter builds the relay's *http.ServeMux, mirroring
// buildRouter(store:watcherPool:networkPolicy:deviceRegistrationSecret:logger:).
// contentPreviewEnabled mirrors config.Config.ContentPreviewEnabled
// (RELAY_CONTENT_PREVIEW) — see registerMessageRoutes's doc comment for
// how it gates GET /v1/messages.
func NewRouter(s Store, pool watcherPool, networkPolicy security.NetworkPolicy, deviceRegistrationSecret string, contentPreviewEnabled bool, logger *slog.Logger) *http.ServeMux {
	if logger == nil {
		logger = slog.Default()
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok"))
	})
	registerDeviceRoutes(mux, s, deviceRegistrationSecret, logger)
	registerWatchRoutes(mux, s, pool, networkPolicy)
	registerMessageRoutes(mux, s, contentPreviewEnabled)
	return mux
}
