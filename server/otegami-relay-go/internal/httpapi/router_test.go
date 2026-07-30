package httpapi

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/m-tkg/otegami-relay-go/internal/api"
	"github.com/m-tkg/otegami-relay-go/internal/cryptox"
	"github.com/m-tkg/otegami-relay-go/internal/security"
	"github.com/m-tkg/otegami-relay-go/internal/store"
)

// fakePool is a no-op watcherPool for route tests, which don't need real
// IMAP connections — every test here uses a TEST-NET-3 (RFC 5737) literal
// imapHost so RelayNetworkPolicy.Strict's checks pass without a real DNS
// lookup or connection attempt, same rationale as the Swift
// WatchRoutesTests.
type fakePool struct {
	added   []string
	removed []string
}

func (f *fakePool) AddWatch(id string)    { f.added = append(f.added, id) }
func (f *fakePool) RemoveWatch(id string) { f.removed = append(f.removed, id) }

func newTestRouterStore(t *testing.T) *store.Store {
	t.Helper()
	c, err := cryptox.New(make([]byte, 32))
	if err != nil {
		t.Fatal(err)
	}
	s, err := store.Open(":memory:", c)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func newTestRouter(t *testing.T) (*http.ServeMux, *store.Store, *fakePool) {
	t.Helper()
	s := newTestRouterStore(t)
	pool := &fakePool{}
	router := NewRouter(s, pool, security.Strict(), "", discardLogger())
	return router, s, pool
}

func do(router http.Handler, method, path, body, bearer string) *httptest.ResponseRecorder {
	var r io.Reader
	if body != "" {
		r = strings.NewReader(body)
	}
	req := httptest.NewRequest(method, path, r)
	if body != "" {
		req.Header.Set("content-type", "application/json")
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	return rec
}

func registerDevice(t *testing.T, router http.Handler) api.RegisterDeviceResponse {
	t.Helper()
	body, err := json.Marshal(api.RegisterDeviceRequest{ApnsToken: "tok", Environment: api.EnvironmentSandbox})
	if err != nil {
		t.Fatal(err)
	}
	rec := do(router, "POST", "/v1/devices", string(body), "")
	if rec.Code != http.StatusCreated {
		t.Fatalf("register device: got %d: %s", rec.Code, rec.Body.String())
	}
	var resp api.RegisterDeviceResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	return resp
}

const testNet3Host = "203.0.113.10" // RFC 5737 TEST-NET-3, documentation-only

func TestHealthEndpoint(t *testing.T) {
	router, _, _ := newTestRouter(t)
	rec := do(router, "GET", "/health", "", "")
	if rec.Code != http.StatusOK || rec.Body.String() != "ok" {
		t.Fatalf("got status=%d body=%q", rec.Code, rec.Body.String())
	}
}

func TestRegisterAndUpdateDeviceToken(t *testing.T) {
	router, s, _ := newTestRouter(t)
	device := registerDevice(t, router)
	if device.DeviceID == "" || device.DeviceSecret == "" {
		t.Fatal("expected non-empty id/secret")
	}

	updateBody, _ := json.Marshal(api.UpdateDeviceTokenRequest{ApnsToken: "rotated", Environment: api.EnvironmentProduction})
	rec := do(router, "PUT", "/v1/devices/"+device.DeviceID+"/token", string(updateBody), device.DeviceSecret)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("got %d: %s", rec.Code, rec.Body.String())
	}

	target, err := s.PushTarget(t.Context(), device.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	if target == nil || target.ApnsToken != "rotated" || target.Environment != api.EnvironmentProduction {
		t.Fatalf("got %+v", target)
	}
}

func TestUpdateTokenWrongSecretRejected(t *testing.T) {
	router, _, _ := newTestRouter(t)
	device := registerDevice(t, router)
	updateBody, _ := json.Marshal(api.UpdateDeviceTokenRequest{ApnsToken: "new", Environment: api.EnvironmentSandbox})
	rec := do(router, "PUT", "/v1/devices/"+device.DeviceID+"/token", string(updateBody), "totally-wrong-secret")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d", rec.Code)
	}
}

func TestUpdateTokenMissingAuthRejected(t *testing.T) {
	router, _, _ := newTestRouter(t)
	updateBody, _ := json.Marshal(api.UpdateDeviceTokenRequest{ApnsToken: "new", Environment: api.EnvironmentSandbox})
	rec := do(router, "PUT", "/v1/devices/some-id/token", string(updateBody), "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d", rec.Code)
	}
}

func TestRegistrationOpenWhenSecretNotConfigured(t *testing.T) {
	s := newTestRouterStore(t)
	router := NewRouter(s, &fakePool{}, security.Strict(), "", discardLogger())
	body, _ := json.Marshal(api.RegisterDeviceRequest{ApnsToken: "tok", Environment: api.EnvironmentSandbox})
	rec := do(router, "POST", "/v1/devices", string(body), "")
	if rec.Code != http.StatusCreated {
		t.Fatalf("got %d", rec.Code)
	}
}

func TestRegistrationRejectedWithoutSecretWhenConfigured(t *testing.T) {
	s := newTestRouterStore(t)
	router := NewRouter(s, &fakePool{}, security.Strict(), "op-secret", discardLogger())
	body, _ := json.Marshal(api.RegisterDeviceRequest{ApnsToken: "tok", Environment: api.EnvironmentSandbox})

	rec := do(router, "POST", "/v1/devices", string(body), "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d", rec.Code)
	}
	rec = do(router, "POST", "/v1/devices", string(body), "wrong-secret")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d", rec.Code)
	}
}

func TestRegistrationAcceptedWithCorrectSecret(t *testing.T) {
	s := newTestRouterStore(t)
	router := NewRouter(s, &fakePool{}, security.Strict(), "op-secret", discardLogger())
	body, _ := json.Marshal(api.RegisterDeviceRequest{ApnsToken: "tok", Environment: api.EnvironmentSandbox})
	rec := do(router, "POST", "/v1/devices", string(body), "op-secret")
	if rec.Code != http.StatusCreated {
		t.Fatalf("got %d", rec.Code)
	}
}

func passwordWatchBody(accountID, imapHost, username, secret, mailbox string) string {
	req := api.CreateWatchRequest{
		AccountID: accountID, ImapHost: imapHost, ImapPort: 993, ImapUseTLS: true,
		ImapUsername: username, Auth: api.WatchAuth{Type: api.WatchAuthPassword, Secret: secret}, Mailbox: mailbox,
	}
	body, _ := json.Marshal(req)
	return string(body)
}

func TestCreateWatchThenDelete(t *testing.T) {
	router, s, pool := newTestRouter(t)
	device := registerDevice(t, router)

	body := passwordWatchBody("account-1", testNet3Host, "user@example.com", "app-password", "INBOX")
	rec := do(router, "POST", "/v1/watches", body, device.DeviceSecret)
	if rec.Code != http.StatusCreated {
		t.Fatalf("got %d: %s", rec.Code, rec.Body.String())
	}
	var created api.WatchResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if created.AccountID != "account-1" || created.Mailbox != "INBOX" {
		t.Fatalf("got %+v", created)
	}
	if len(pool.added) != 1 || pool.added[0] != created.WatchID {
		t.Fatalf("expected pool.AddWatch to be called, got %+v", pool.added)
	}

	records, err := s.ListWatches(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 {
		t.Fatalf("got %d records", len(records))
	}

	rec = do(router, "DELETE", "/v1/watches/"+created.WatchID, "", device.DeviceSecret)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("got %d", rec.Code)
	}
	if len(pool.removed) != 1 || pool.removed[0] != created.WatchID {
		t.Fatalf("expected pool.RemoveWatch to be called, got %+v", pool.removed)
	}
	records, _ = s.ListWatches(t.Context())
	if len(records) != 0 {
		t.Fatal("expected watch to be deleted")
	}
}

func TestCreateWatchRequiresAuth(t *testing.T) {
	router, s, _ := newTestRouter(t)
	body := passwordWatchBody("account-1", testNet3Host, "user@example.com", "app-password", "INBOX")
	rec := do(router, "POST", "/v1/watches", body, "not-a-real-secret")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d", rec.Code)
	}
	records, _ := s.ListWatches(t.Context())
	if len(records) != 0 {
		t.Fatal("expected nothing persisted")
	}
}

func TestDeleteIsScopedToOwningDevice(t *testing.T) {
	router, s, pool := newTestRouter(t)
	owner := registerDevice(t, router)
	intruder := registerDevice(t, router)

	body := passwordWatchBody("account-1", testNet3Host, "user@example.com", "app-password", "INBOX")
	rec := do(router, "POST", "/v1/watches", body, owner.DeviceSecret)
	var created api.WatchResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &created)

	rec = do(router, "DELETE", "/v1/watches/"+created.WatchID, "", intruder.DeviceSecret)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("got %d", rec.Code)
	}
	records, _ := s.ListWatches(t.Context())
	if len(records) != 1 {
		t.Fatal("expected owner's watch to survive an intruder's delete attempt")
	}
	pool.RemoveWatch(created.WatchID) // test cleanup, mirrors the Swift test's comment
}

func TestListWatchesScopedAndCredentialFree(t *testing.T) {
	router, _, _ := newTestRouter(t)
	owner := registerDevice(t, router)
	other := registerDevice(t, router)

	rec := do(router, "POST", "/v1/watches", passwordWatchBody("owner-account", testNet3Host, "u1@example.com", "app-password", "INBOX"), owner.DeviceSecret)
	if rec.Code != http.StatusCreated {
		t.Fatalf("got %d", rec.Code)
	}
	rec = do(router, "POST", "/v1/watches", passwordWatchBody("other-account", testNet3Host, "u2@example.com", "app-password-2", "INBOX"), other.DeviceSecret)
	if rec.Code != http.StatusCreated {
		t.Fatalf("got %d", rec.Code)
	}

	rec = do(router, "GET", "/v1/watches", "", owner.DeviceSecret)
	if rec.Code != http.StatusOK {
		t.Fatalf("got %d", rec.Code)
	}
	var listed api.ListWatchesResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &listed); err != nil {
		t.Fatal(err)
	}
	if len(listed.Watches) != 1 || listed.Watches[0].AccountID != "owner-account" || listed.Watches[0].ImapHost != testNet3Host {
		t.Fatalf("got %+v", listed)
	}
	if strings.Contains(rec.Body.String(), "app-password") {
		t.Fatal("credential leaked into GET /v1/watches response")
	}
}

func TestListWatchesRequiresAuth(t *testing.T) {
	router, _, _ := newTestRouter(t)
	rec := do(router, "GET", "/v1/watches", "", "not-a-real-secret")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d", rec.Code)
	}
}

func TestListWatchesReflectsStoppedStatus(t *testing.T) {
	router, s, pool := newTestRouter(t)
	device := registerDevice(t, router)
	rec := do(router, "POST", "/v1/watches", passwordWatchBody("account-1", testNet3Host, "user@example.com", "app-password", "INBOX"), device.DeviceSecret)
	var created api.WatchResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &created)

	if err := s.RecordWatchError(t.Context(), created.WatchID, api.ErrorKindAuthFailure, true); err != nil {
		t.Fatal(err)
	}
	pool.RemoveWatch(created.WatchID)

	rec = do(router, "GET", "/v1/watches", "", device.DeviceSecret)
	var listed api.ListWatchesResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &listed)
	if len(listed.Watches) != 1 || listed.Watches[0].Status != api.WatchStatusStopped {
		t.Fatalf("got %+v", listed)
	}
	if listed.Watches[0].LastErrorKind == nil || *listed.Watches[0].LastErrorKind != api.ErrorKindAuthFailure {
		t.Fatalf("got %+v", listed.Watches[0])
	}
	if listed.Watches[0].LastErrorAt == nil {
		t.Fatal("expected lastErrorAt to be set")
	}
}

func TestCreateWatchValidatesRequiredFields(t *testing.T) {
	router, s, _ := newTestRouter(t)
	device := registerDevice(t, router)
	body := passwordWatchBody("account-1", "", "user@example.com", "app-password", "INBOX")
	rec := do(router, "POST", "/v1/watches", body, device.DeviceSecret)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("got %d", rec.Code)
	}
	records, _ := s.ListWatches(t.Context())
	if len(records) != 0 {
		t.Fatal("expected nothing persisted")
	}
}

func TestCreateOAuthWatchSucceeds(t *testing.T) {
	router, s, _ := newTestRouter(t)
	device := registerDevice(t, router)
	provider := api.ProviderGoogle
	req := api.CreateWatchRequest{
		AccountID: "gmail-account", ImapHost: testNet3Host, ImapPort: 993, ImapUseTLS: true,
		ImapUsername: "user@gmail.example.test",
		Auth:         api.WatchAuth{Type: api.WatchAuthOAuth, Secret: "a-refresh-token", Provider: &provider},
		Mailbox:      "INBOX",
	}
	body, _ := json.Marshal(req)
	rec := do(router, "POST", "/v1/watches", string(body), device.DeviceSecret)
	if rec.Code != http.StatusCreated {
		t.Fatalf("got %d: %s", rec.Code, rec.Body.String())
	}

	records, err := s.ListWatches(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].AuthType != api.WatchAuthOAuth || records[0].Provider == nil || *records[0].Provider != api.ProviderGoogle {
		t.Fatalf("got %+v", records)
	}
	if records[0].Secret != "a-refresh-token" {
		t.Fatalf("got secret %q", records[0].Secret)
	}
	raw, ok, err := s.RawEncryptedSecretForTesting(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if !ok || raw == "a-refresh-token" {
		t.Fatal("plaintext refresh token leaked to storage")
	}
}

func TestCreateOAuthWatchWithoutProviderRejected(t *testing.T) {
	router, s, _ := newTestRouter(t)
	device := registerDevice(t, router)
	req := api.CreateWatchRequest{
		AccountID: "gmail-account", ImapHost: testNet3Host, ImapPort: 993, ImapUseTLS: true,
		ImapUsername: "user@gmail.example.test",
		Auth:         api.WatchAuth{Type: api.WatchAuthOAuth, Secret: "a-refresh-token"},
		Mailbox:      "INBOX",
	}
	body, _ := json.Marshal(req)
	rec := do(router, "POST", "/v1/watches", string(body), device.DeviceSecret)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("got %d", rec.Code)
	}
	records, _ := s.ListWatches(t.Context())
	if len(records) != 0 {
		t.Fatal("expected nothing persisted")
	}
}

func TestCreateWatchRejectsPrivateHost(t *testing.T) {
	hosts := []string{
		"127.0.0.1", "10.0.0.5", "172.16.0.1", "192.168.1.1", "169.254.1.1",
		"0.0.0.0", "::1", "fe80::1", "fc00::1", "::ffff:127.0.0.1",
	}
	for _, host := range hosts {
		t.Run(host, func(t *testing.T) {
			router, s, _ := newTestRouter(t)
			device := registerDevice(t, router)
			body := passwordWatchBody("account-1", host, "user@example.com", "app-password", "INBOX")
			rec := do(router, "POST", "/v1/watches", body, device.DeviceSecret)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("got %d for host %q", rec.Code, host)
			}
			records, _ := s.ListWatches(t.Context())
			if len(records) != 0 {
				t.Fatal("expected nothing persisted")
			}
		})
	}
}

func TestCreateWatchAcceptsPublicHostOnAllowedPort(t *testing.T) {
	router, s, _ := newTestRouter(t)
	device := registerDevice(t, router)
	body := passwordWatchBody("account-1", testNet3Host, "user@example.com", "app-password", "INBOX")
	rec := do(router, "POST", "/v1/watches", body, device.DeviceSecret)
	if rec.Code != http.StatusCreated {
		t.Fatalf("got %d: %s", rec.Code, rec.Body.String())
	}
	records, _ := s.ListWatches(t.Context())
	if len(records) != 1 {
		t.Fatal("expected watch to be persisted")
	}
}

func TestCreateWatchRejectsDisallowedPort(t *testing.T) {
	router, s, _ := newTestRouter(t)
	device := registerDevice(t, router)
	req := api.CreateWatchRequest{
		AccountID: "account-1", ImapHost: testNet3Host, ImapPort: 6379, ImapUseTLS: false,
		ImapUsername: "user@example.com", Auth: api.WatchAuth{Type: api.WatchAuthPassword, Secret: "app-password"}, Mailbox: "INBOX",
	}
	body, _ := json.Marshal(req)
	rec := do(router, "POST", "/v1/watches", string(body), device.DeviceSecret)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("got %d", rec.Code)
	}
	records, _ := s.ListWatches(t.Context())
	if len(records) != 0 {
		t.Fatal("expected nothing persisted")
	}
}

func TestCreateWatchRejectsControlCharactersInUsername(t *testing.T) {
	poisoned := []string{
		"a\r\nRCPT TO:<attacker@evil.test>",
		"a\nCONFIG SET dir /var/lib/redis",
		"a\r\n",
		"a\x00b",
	}
	for _, username := range poisoned {
		t.Run(username, func(t *testing.T) {
			router, s, _ := newTestRouter(t)
			device := registerDevice(t, router)
			body := passwordWatchBody("account-1", testNet3Host, username, "app-password", "INBOX")
			rec := do(router, "POST", "/v1/watches", body, device.DeviceSecret)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("got %d", rec.Code)
			}
			records, _ := s.ListWatches(t.Context())
			if len(records) != 0 {
				t.Fatal("expected nothing persisted")
			}
		})
	}
}

func TestCreateWatchRejectsControlCharactersInSecret(t *testing.T) {
	router, s, _ := newTestRouter(t)
	device := registerDevice(t, router)
	body := passwordWatchBody("account-1", testNet3Host, "user@example.com", "pw\r\nHELO relay\r\nMAIL FROM:<a@b>", "INBOX")
	rec := do(router, "POST", "/v1/watches", body, device.DeviceSecret)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("got %d", rec.Code)
	}
	records, _ := s.ListWatches(t.Context())
	if len(records) != 0 {
		t.Fatal("expected nothing persisted")
	}
}

func TestCreateWatchRejectsControlCharactersInMailbox(t *testing.T) {
	router, s, _ := newTestRouter(t)
	device := registerDevice(t, router)
	body := passwordWatchBody("account-1", testNet3Host, "user@example.com", "app-password", "INBOX\r\nA2 LOGOUT")
	rec := do(router, "POST", "/v1/watches", body, device.DeviceSecret)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("got %d", rec.Code)
	}
	records, _ := s.ListWatches(t.Context())
	if len(records) != 0 {
		t.Fatal("expected nothing persisted")
	}
}

func TestCreateWatchRejectsInvalidAccountID(t *testing.T) {
	invalid := []string{
		"a\r\n2026-07-29T00:00:00 info otegami-relay : forged log line",
		"a\nb",
		"has spaces",
		"",
		strings.Repeat("a", 129),
	}
	for _, accountID := range invalid {
		t.Run(accountID, func(t *testing.T) {
			router, s, _ := newTestRouter(t)
			device := registerDevice(t, router)
			body := passwordWatchBody(accountID, testNet3Host, "user@example.com", "app-password", "INBOX")
			rec := do(router, "POST", "/v1/watches", body, device.DeviceSecret)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("got %d", rec.Code)
			}
			records, _ := s.ListWatches(t.Context())
			if len(records) != 0 {
				t.Fatal("expected nothing persisted")
			}
		})
	}
}

func TestCreateWatchAcceptsUUIDAccountID(t *testing.T) {
	router, _, _ := newTestRouter(t)
	device := registerDevice(t, router)
	body := passwordWatchBody("5f1e1c9a-3b2d-4e6f-8a1b-2c3d4e5f6a7b", testNet3Host, "user@example.com", "app-password", "INBOX")
	rec := do(router, "POST", "/v1/watches", body, device.DeviceSecret)
	if rec.Code != http.StatusCreated {
		t.Fatalf("got %d: %s", rec.Code, rec.Body.String())
	}
}
