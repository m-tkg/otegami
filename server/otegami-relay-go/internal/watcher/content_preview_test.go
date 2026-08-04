package watcher

import (
	"testing"
	"time"

	"github.com/m-tkg/otegami-relay-go/internal/api"
	"github.com/m-tkg/otegami-relay-go/internal/imaptest"
	"github.com/m-tkg/otegami-relay-go/internal/security"
)

func TestContentPreviewFetchesEnrichesPayloadAndCaches(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.SetInitialState(5, 6)
	server.AddMessage(6, imaptest.FakeMessage{
		HeaderFields: "From: Alice Example <alice@example.test>\r\n" +
			"Subject: Hello there\r\n" +
			"Date: Mon, 1 Jan 2024 00:00:00 +0000\r\n" +
			"Message-ID: <msg-6@example.test>\r\n" +
			"Content-Type: text/plain; charset=utf-8\r\n\r\n",
		Text: "This is the body.",
	})
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := New(s, sender, testLogger(), Options{
		IdleMaxWait:           3 * time.Second,
		PollInterval:          200 * time.Millisecond,
		NetworkPolicy:         security.PermissiveForTesting(),
		ContentPreviewEnabled: true,
	})
	t.Cleanup(pool.Stop)

	_, watchID := createWatch(t, s, port, "account-1",
		api.WatchAuth{Type: api.WatchAuthPassword, Secret: "password"},
		api.EnvironmentSandbox, "device-token-abc")
	pool.AddWatch(watchID)

	time.Sleep(300 * time.Millisecond)
	server.DeliverNewMail()

	calls := waitForCalls(t, sender, 1, 5*time.Second)
	if len(calls) != 1 {
		t.Fatalf("got %d calls: %+v", len(calls), calls)
	}
	payload := calls[0].Payload
	if payload.AccountID != "account-1" || payload.UidNext != 7 {
		t.Fatalf("got %+v", payload)
	}
	if payload.LatestUID != 6 || payload.LatestFromName != "Alice Example" ||
		payload.LatestFromAddress != "alice@example.test" || payload.LatestSubject != "Hello there" {
		t.Fatalf("got %+v", payload)
	}
	if payload.PreviewCount != 1 {
		t.Fatalf("got previewCount=%d", payload.PreviewCount)
	}

	previews, err := s.MessagePreviewsSince(t.Context(), watchID, 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 1 || previews[0].UID != 6 || previews[0].BodyPreview != "This is the body." {
		t.Fatalf("got %+v", previews)
	}
}

func TestContentPreviewDisabledLeavesPayloadContentFree(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.SetInitialState(5, 6)
	// No AddMessage registered — if the feature were (incorrectly) active
	// here, the FETCH would find nothing anyway; the point of this test is
	// that ContentPreviewEnabled defaulting to false must never even issue
	// the FETCH.
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := newTestPool(t, s, sender, nil) // ContentPreviewEnabled left at its zero value (false)
	_, watchID := createWatch(t, s, port, "account-1",
		api.WatchAuth{Type: api.WatchAuthPassword, Secret: "password"},
		api.EnvironmentSandbox, "device-token-abc")
	pool.AddWatch(watchID)

	time.Sleep(300 * time.Millisecond)
	server.DeliverNewMail()

	calls := waitForCalls(t, sender, 1, 5*time.Second)
	if len(calls) != 1 {
		t.Fatalf("got %d calls", len(calls))
	}
	payload := calls[0].Payload
	if payload.LatestUID != 0 || payload.LatestFromName != "" || payload.LatestSubject != "" || payload.PreviewCount != 0 {
		t.Fatalf("expected a content-free payload, got %+v", payload)
	}

	previews, err := s.MessagePreviewsSince(t.Context(), watchID, 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 0 {
		t.Fatalf("expected nothing cached with the feature off, got %+v", previews)
	}
}

func TestContentPreviewFetchFindingNothingStillFiresContentFreePush(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.SetInitialState(5, 6)
	// Deliberately no AddMessage(6, ...) — the UID FETCH will succeed but
	// find nothing to return, mirroring a message that vanished (expunged)
	// between the UIDNEXT check and the FETCH.
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := New(s, sender, testLogger(), Options{
		IdleMaxWait:           3 * time.Second,
		PollInterval:          200 * time.Millisecond,
		NetworkPolicy:         security.PermissiveForTesting(),
		ContentPreviewEnabled: true,
	})
	t.Cleanup(pool.Stop)

	_, watchID := createWatch(t, s, port, "account-1",
		api.WatchAuth{Type: api.WatchAuthPassword, Secret: "password"},
		api.EnvironmentSandbox, "device-token-abc")
	pool.AddWatch(watchID)

	time.Sleep(300 * time.Millisecond)
	server.DeliverNewMail()

	calls := waitForCalls(t, sender, 1, 5*time.Second)
	if len(calls) != 1 {
		t.Fatalf("got %d calls", len(calls))
	}
	payload := calls[0].Payload
	if payload.AccountID != "account-1" || payload.UidNext != 7 {
		t.Fatalf("got %+v", payload)
	}
	if payload.LatestUID != 0 || payload.LatestFromName != "" || payload.PreviewCount != 0 {
		t.Fatalf("expected the content-free fallback shape, got %+v", payload)
	}
}

func TestContentPreviewCapsFetchToNewestTen(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	// Deliberately the non-IDLE poll path (runPollCycle), not IDLE: IDLE's
	// Idle() breaks its read loop the moment it sees the FIRST untagged
	// EXISTS line, racing against however many of this test's 15
	// DeliverNewMail calls have actually reached the wire by then — an
	// inherently flaky thing to assert on. The poll path instead takes its
	// UIDNEXT snapshot via a fresh SELECT once per PollInterval on a brand
	// new connection, with no client connected in between — so as long as
	// all 15 DeliverNewMail calls (fast, synchronous, in-process) finish
	// well within one PollInterval of each other, the next poll cycle
	// deterministically observes the final state in one shot.
	server.SupportsIdle = false
	server.SetInitialState(0, 100)
	for uid := uint32(100); uid < 115; uid++ {
		server.AddMessage(uid, imaptest.FakeMessage{
			HeaderFields: "From: sender@example.test\r\nSubject: msg\r\n\r\n",
			Text:         "body",
		})
	}
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := New(s, sender, testLogger(), Options{
		PollInterval:          200 * time.Millisecond,
		NetworkPolicy:         security.PermissiveForTesting(),
		ContentPreviewEnabled: true,
	})
	t.Cleanup(pool.Stop)

	_, watchID := createWatch(t, s, port, "account-1",
		api.WatchAuth{Type: api.WatchAuthPassword, Secret: "password"},
		api.EnvironmentSandbox, "device-token-abc")
	pool.AddWatch(watchID)

	// Let the first poll cycle establish its UIDNEXT baseline (100) —
	// lastKnownUIDNext starts at 0, so this cycle never fires regardless
	// of what's delivered afterward.
	time.Sleep(300 * time.Millisecond)
	for i := 0; i < 15; i++ {
		server.DeliverNewMail()
	}

	calls := waitForCalls(t, sender, 1, 5*time.Second)
	if len(calls) != 1 {
		t.Fatalf("got %d calls: %+v", len(calls), calls)
	}
	payload := calls[0].Payload
	if payload.UidNext != 115 {
		t.Fatalf("got uidNext=%d", payload.UidNext)
	}
	if payload.LatestUID != 114 || payload.PreviewCount != 10 {
		t.Fatalf("expected the newest 10 of 15 new messages, got %+v", payload)
	}

	previews, err := s.MessagePreviewsSince(t.Context(), watchID, 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 10 {
		t.Fatalf("got %d cached previews: %+v", len(previews), previews)
	}
	minUID := previews[0].UID
	maxUID := previews[0].UID
	for _, p := range previews {
		if p.UID < minUID {
			minUID = p.UID
		}
		if p.UID > maxUID {
			maxUID = p.UID
		}
	}
	if minUID != 105 || maxUID != 114 {
		t.Fatalf("expected uids 105..114, got min=%d max=%d", minUID, maxUID)
	}
}
