package imapclient

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/m-tkg/otegami-relay-go/internal/security"
)

// rawScriptedServer starts a one-shot raw TCP server: sends greeting, reads
// and discards the LOGIN line answering it OK, then reads the UID FETCH
// line and writes buildResponse's result verbatim (no further processing)
// — used by this file's tests to exercise readLiteralAwareLine/
// readFetchResponses against deliberately malformed/oversized/truncated
// literal framing that imaptest.FakeServer's well-behaved UID FETCH
// handling can't produce. buildResponse receives the real tag the client
// used for its UID FETCH command, so a test that wants its scripted
// response to include a tagged completion line can address the client's
// actual tag rather than a guessed one.
func rawScriptedServer(t *testing.T, buildResponse func(fetchTag string) string) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		fmt.Fprintf(conn, "* OK fake IMAP ready\r\n")
		r := bufio.NewReader(conn)
		loginLine, err := r.ReadString('\n') // LOGIN
		if err != nil {
			return
		}
		fmt.Fprintf(conn, "%s OK LOGIN completed\r\n", strings.SplitN(loginLine, " ", 2)[0])
		fetchLine, err := r.ReadString('\n') // UID FETCH
		if err != nil {
			return
		}
		fetchTag := strings.SplitN(fetchLine, " ", 2)[0]
		_, _ = conn.Write([]byte(buildResponse(fetchTag)))
		// Hold the connection open past the test's own deadlines rather
		// than closing immediately — a close would let ErrConnectionClosed
		// mask what should be a timeout/size-bound failure in the
		// truncated-literal case below.
		time.Sleep(3 * time.Second)
	}()
	return ln.Addr().(*net.TCPAddr).Port
}

func connectAndLogin(t *testing.T, port int) *Client {
	t.Helper()
	c := New()
	if err := c.Connect("127.0.0.1", port, false, 5*time.Second, security.PermissiveForTesting()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	return c
}

func TestUIDFetchPreviewsRejectsOversizedLiteral(t *testing.T) {
	port := rawScriptedServer(t, func(string) string {
		return "* 1 FETCH (UID 1 BODY[HEADER.FIELDS (FROM)] {999999}\r\n"
	})
	c := connectAndLogin(t, port)
	_, err := c.UIDFetchPreviews(1, 1, 3*time.Second)
	if !errors.Is(err, ErrResponseTooLarge) {
		t.Fatalf("got %v", err)
	}
}

func TestUIDFetchPreviewsSurvivesTruncatedLiteral(t *testing.T) {
	// Declares a 1000-byte literal but the connection only ever delivers
	// 10 bytes of it before the server (per rawScriptedServer's own
	// sleep-then-nothing-more behavior) goes silent — the read must time
	// out rather than hang forever or panic.
	port := rawScriptedServer(t, func(string) string {
		return "* 1 FETCH (UID 1 BODY[HEADER.FIELDS (FROM)] {1000}\r\n0123456789"
	})
	c := connectAndLogin(t, port)
	_, err := c.UIDFetchPreviews(1, 1, 1*time.Second)
	if !errors.Is(err, ErrTimedOut) && !errors.Is(err, ErrConnectionClosed) {
		t.Fatalf("got %v", err)
	}
}

func TestUIDFetchPreviewsRejectsExcessLiteralsInOneLogicalLine(t *testing.T) {
	// A logical line that never stops offering another tiny literal —
	// each one individually well within maxLiteralBytes, but far more of
	// them than this client's own FETCH command could ever provoke.
	// readLiteralAwareLine's maxLiteralsPerLogicalLine bound must stop
	// this from looping forever.
	var response string
	for i := 0; i < 50; i++ {
		response += "{1}\r\nX "
	}
	port := rawScriptedServer(t, func(string) string {
		return "* 1 FETCH (UID 1 BODY[HEADER.FIELDS (FROM)] " + response + ")\r\n"
	})
	c := connectAndLogin(t, port)
	_, err := c.UIDFetchPreviews(1, 1, 5*time.Second)
	if !errors.Is(err, ErrResponseTooLarge) {
		t.Fatalf("got %v", err)
	}
}

func TestUIDFetchPreviewsMalformedMissingUIDAtomSkipsRecord(t *testing.T) {
	// A well-formed FETCH response that simply never mentions "UID n" —
	// UIDFetchPreviews must skip it (not error the whole batch) and return
	// an empty result, mirroring how the watcher pool falls back to the
	// content-free payload only when nothing at all could be parsed.
	port := rawScriptedServer(t, func(fetchTag string) string {
		return "* 1 FETCH (FLAGS (\\Seen))\r\n" + fetchTag + " OK UID FETCH completed\r\n"
	})
	c := connectAndLogin(t, port)
	previews, err := c.UIDFetchPreviews(1, 1, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 0 {
		t.Fatalf("got %+v", previews)
	}
}
