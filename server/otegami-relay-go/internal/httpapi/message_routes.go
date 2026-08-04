package httpapi

import (
	"context"
	"net/http"
	"strconv"

	"github.com/m-tkg/otegami-relay-go/internal/api"
	"github.com/m-tkg/otegami-relay-go/internal/store"
)

// maxMessagesResponseCount caps GET /v1/messages's response — mirrors
// watcher's own maxContentPreviewFetchCount (a push payload only ever
// carries the single newest message anyway, and this feature's cache is
// pruned to the newest 50 per watch, but the *response* to any one call is
// capped smaller since 10 is already more than any notification-driven UI
// needs to show at once).
const maxMessagesResponseCount = 10

// messageStore is the subset of *store.Store GET /v1/messages needs, plus
// deviceStore (satisfied by *store.Store, same shape as watchStore).
type messageStore interface {
	deviceStore
	WatchIDForDeviceAccount(ctx context.Context, deviceID, accountID string) (string, bool, error)
	MessagePreviewsSince(ctx context.Context, watchID string, sinceUID uint32, limit int) ([]store.MessagePreview, error)
}

// registerMessageRoutes wires GET /v1/messages (RELAY_CONTENT_PREVIEW,
// opt-in, Phase 2) — mirrors registerWatchRoutes's auth/error-shape
// conventions. contentPreviewEnabled gates the whole route: with the
// feature off, every call gets the same 404 an unrecognized accountId
// would get, so a caller can't distinguish "this relay doesn't have the
// feature on" from "you have no watch for that accountId" — deliberately,
// since the response (nothing to show) is identical either way.
func registerMessageRoutes(mux *http.ServeMux, s messageStore, contentPreviewEnabled bool) {
	mux.HandleFunc("GET /v1/messages", func(w http.ResponseWriter, r *http.Request) {
		deviceID, httpErr := authenticatedDeviceID(r, s)
		if httpErr != nil {
			writeError(w, httpErr)
			return
		}
		if !contentPreviewEnabled {
			writeError(w, notFound("content preview is not enabled on this relay"))
			return
		}

		accountID := r.URL.Query().Get("accountId")
		if accountID == "" {
			writeError(w, badRequest("accountId query parameter is required"))
			return
		}
		var sinceUID uint64
		if raw := r.URL.Query().Get("sinceUid"); raw != "" {
			parsed, err := strconv.ParseUint(raw, 10, 32)
			if err != nil {
				writeError(w, badRequest("sinceUid must be a non-negative integer"))
				return
			}
			sinceUID = parsed
		}

		watchID, found, err := s.WatchIDForDeviceAccount(r.Context(), deviceID, accountID)
		if err != nil {
			writeError(w, badRequest("could not resolve watch"))
			return
		}
		if !found {
			// Task #208-style scoping: this also covers "accountId belongs
			// to a different device" — that must look identical to
			// "unknown accountId" from here (see WatchIDForDeviceAccount's
			// doc comment), never a distinguishable error that would leak
			// whether some other device has it.
			writeError(w, notFound("no watch registered for this device/accountId"))
			return
		}

		previews, err := s.MessagePreviewsSince(r.Context(), watchID, uint32(sinceUID), maxMessagesResponseCount)
		if err != nil {
			writeError(w, badRequest("could not list message previews"))
			return
		}
		summaries := make([]api.MessagePreviewSummary, 0, len(previews))
		for _, p := range previews {
			summaries = append(summaries, api.MessagePreviewSummary{
				UID:         int64(p.UID),
				From:        api.MessagePreviewFrom{Name: p.FromName, Address: p.FromAddress},
				Subject:     p.Subject,
				Date:        api.NewWireTime(p.Date),
				MessageID:   p.MessageID,
				BodyPreview: p.BodyPreview,
			})
		}
		writeJSON(w, http.StatusOK, summaries)
	})
}
