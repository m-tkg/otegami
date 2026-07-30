// Package imaptest holds test-only fake IMAP servers, shared by the
// imapclient and watcher test suites. Mirrors the Swift test target's
// FakeIMAPServer.swift (a well-behaved subset of the real protocol:
// LOGIN, AUTHENTICATE XOAUTH2, CAPABILITY, SELECT, STATUS, IDLE/DONE,
// LOGOUT) and FloodingIMAPServer (MinimalIMAPClientLimitsTests.swift — a
// deliberately misbehaving peer for the CLAUDE-SECURITY F4/F8 bounds).
//
// Never imported by production code — only *_test.go files reference it.
package imaptest

import (
	"bufio"
	"encoding/base64"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"
)

// FakeServer is a tiny scripted IMAP server: accepts connections, answers
// LOGIN/CAPABILITY/SELECT/STATUS/IDLE/DONE with plausible responses, and
// lets a test simulate "new mail arrived" via DeliverNewMail — which both
// bumps the server's own EXISTS/UIDNEXT counters (so a subsequent STATUS
// reflects it) and, if a client is currently connected, pushes an
// unsolicited "* n EXISTS" plus "* 0 RECENT" down the wire immediately
// (real Dovecot sends both as distinct untagged lines — see the Swift
// FakeIMAPServer.deliverNewMail doc comment for why the RECENT line
// matters).
type FakeServer struct {
	// SupportsIdle controls whether CAPABILITY advertises IDLE.
	SupportsIdle bool
	// RejectsLogin makes LOGIN always answer NO (Task #173's
	// auth-failure tests).
	RejectsLogin bool
	// ExpectedXOAuth2AccessToken, when non-empty, makes AUTHENTICATE
	// XOAUTH2 succeed only for that exact access token; a wrong token
	// gets the RFC 7628 §3.2.2 continuation-then-tagged-failure dance.
	// Empty accepts any well-formed XOAUTH2 request.
	ExpectedXOAuth2AccessToken string
	// InactivityTimeout, when non-zero, closes a connection that goes
	// this long without receiving any client command — simulating the
	// aggressive no-traffic disconnect real-world Yahoo Japan IMAP was
	// observed doing in production (Task #201; see pool.go's pollWait
	// doc comment). Zero (the default) never closes for inactivity,
	// matching every other fake-server test's assumption of an
	// otherwise-well-behaved peer.
	InactivityTimeout time.Duration

	mu         sync.Mutex
	listener   net.Listener
	clientConn net.Conn
	exists     int
	uidNext    int
	loginCount int
}

// LoginCount returns how many LOGIN commands this server has received
// across every connection so far — Task #201's polling-keepalive test
// uses this to confirm a connection survives an InactivityTimeout window
// without triggering the watcher pool's reconnect-and-relogin path.
func (s *FakeServer) LoginCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.loginCount
}

// NewFakeServer mirrors FakeIMAPServer.init's defaults (exists=5,
// uidNext=6, supportsIdle=true).
func NewFakeServer() *FakeServer {
	return &FakeServer{SupportsIdle: true, exists: 5, uidNext: 6}
}

// SetInitialState overrides the EXISTS/UIDNEXT counters before Start.
func (s *FakeServer) SetInitialState(exists, uidNext int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.exists = exists
	s.uidNext = uidNext
}

// Start listens on an ephemeral loopback port, returning it.
func (s *FakeServer) Start() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	s.mu.Lock()
	s.listener = ln
	s.mu.Unlock()
	go s.acceptLoop(ln)
	return ln.Addr().(*net.TCPAddr).Port, nil
}

// Stop closes the listener and any connected client.
func (s *FakeServer) Stop() {
	s.mu.Lock()
	ln := s.listener
	conn := s.clientConn
	s.mu.Unlock()
	if ln != nil {
		_ = ln.Close()
	}
	if conn != nil {
		_ = conn.Close()
	}
}

// DeliverNewMail simulates new mail arriving: bumps the mailbox state and,
// if a client is connected right now, wakes a mid-IDLE client immediately.
func (s *FakeServer) DeliverNewMail() {
	s.mu.Lock()
	s.exists++
	s.uidNext++
	newExists := s.exists
	conn := s.clientConn
	s.mu.Unlock()
	if conn == nil {
		return
	}
	fmt.Fprintf(conn, "* %d EXISTS\r\n", newExists)
	fmt.Fprintf(conn, "* 0 RECENT\r\n")
}

func (s *FakeServer) currentState() (exists, uidNext int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.exists, s.uidNext
}

func (s *FakeServer) acceptLoop(ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		s.mu.Lock()
		s.clientConn = conn
		s.mu.Unlock()
		go s.handleConn(conn)
	}
}

func (s *FakeServer) handleConn(conn net.Conn) {
	defer conn.Close()
	fmt.Fprintf(conn, "* OK fake IMAP ready\r\n")

	// InactivityTimeout support (Task #201): the timer is armed the
	// moment the connection is accepted (mirroring a real server's
	// no-traffic clock starting at connect) and reset on every line
	// received from the client — including NOOP, which is exactly what
	// the watcher pool's polling keepalive now sends to keep this from
	// firing.
	var activityTimer *time.Timer
	if s.InactivityTimeout > 0 {
		activityTimer = time.AfterFunc(s.InactivityTimeout, func() { _ = conn.Close() })
		defer activityTimer.Stop()
	}
	resetActivityTimer := func() {
		if activityTimer != nil {
			activityTimer.Reset(s.InactivityTimeout)
		}
	}

	idling := false
	pendingIdleTag := ""
	awaitingXOAuth2FailureAck := false
	pendingXOAuth2FailureTag := ""

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 0, 64*1024), 64*1024)
	for scanner.Scan() {
		resetActivityTimer()
		line := strings.TrimRight(scanner.Text(), "\r")

		if awaitingXOAuth2FailureAck {
			awaitingXOAuth2FailureAck = false
			fmt.Fprintf(conn, "%s NO [AUTHENTICATIONFAILED] authentication failed\r\n", pendingXOAuth2FailureTag)
			continue
		}
		if idling {
			if strings.EqualFold(line, "DONE") {
				idling = false
				fmt.Fprintf(conn, "%s OK IDLE terminated\r\n", pendingIdleTag)
			}
			continue
		}

		parts := strings.SplitN(line, " ", 3)
		if len(parts) < 2 {
			continue
		}
		tag := parts[0]
		command := strings.ToUpper(parts[1])

		switch command {
		case "LOGIN":
			s.mu.Lock()
			s.loginCount++
			s.mu.Unlock()
			if s.RejectsLogin {
				fmt.Fprintf(conn, "%s NO [AUTHENTICATIONFAILED] authentication failed\r\n", tag)
			} else {
				fmt.Fprintf(conn, "%s OK LOGIN completed\r\n", tag)
			}

		case "NOOP":
			fmt.Fprintf(conn, "%s OK NOOP completed\r\n", tag)

		case "AUTHENTICATE":
			if len(parts) < 3 {
				fmt.Fprintf(conn, "%s BAD missing AUTHENTICATE argument\r\n", tag)
				break
			}
			mechAndPayload := strings.SplitN(parts[2], " ", 2)
			if len(mechAndPayload) != 2 || !strings.EqualFold(mechAndPayload[0], "XOAUTH2") {
				fmt.Fprintf(conn, "%s BAD unsupported AUTHENTICATE mechanism\r\n", tag)
				break
			}
			decoded, err := base64.StdEncoding.DecodeString(mechAndPayload[1])
			if err != nil {
				fmt.Fprintf(conn, "%s BAD invalid XOAUTH2 payload\r\n", tag)
				break
			}
			payload := string(decoded)
			var accepted bool
			if s.ExpectedXOAuth2AccessToken != "" {
				accepted = strings.Contains(payload, "auth=Bearer "+s.ExpectedXOAuth2AccessToken+"\x01")
			} else {
				accepted = strings.HasPrefix(payload, "user=") && strings.Contains(payload, "auth=Bearer ")
			}
			if accepted {
				fmt.Fprintf(conn, "%s OK AUTHENTICATE completed\r\n", tag)
			} else {
				// RFC 7628 §3.2.2: a rejected token gets a `+` continuation
				// carrying a base64 JSON error challenge; the client must
				// answer with an empty line before the tagged NO arrives.
				challenge := base64.StdEncoding.EncodeToString([]byte(`{"status":"401","schemes":"bearer"}`))
				fmt.Fprintf(conn, "+ %s\r\n", challenge)
				pendingXOAuth2FailureTag = tag
				awaitingXOAuth2FailureAck = true
			}

		case "CAPABILITY":
			idleCap := ""
			if s.SupportsIdle {
				idleCap = " IDLE"
			}
			fmt.Fprintf(conn, "* CAPABILITY IMAP4rev1%s\r\n", idleCap)
			fmt.Fprintf(conn, "%s OK CAPABILITY completed\r\n", tag)

		case "SELECT":
			exists, uidNext := s.currentState()
			fmt.Fprintf(conn, "* %d EXISTS\r\n", exists)
			fmt.Fprintf(conn, "* OK [UIDNEXT %d] next uid\r\n", uidNext)
			fmt.Fprintf(conn, "%s OK [READ-WRITE] SELECT completed\r\n", tag)

		case "STATUS":
			_, uidNext := s.currentState()
			fmt.Fprintf(conn, "* STATUS INBOX (UIDNEXT %d)\r\n", uidNext)
			fmt.Fprintf(conn, "%s OK STATUS completed\r\n", tag)

		case "IDLE":
			pendingIdleTag = tag
			idling = true
			fmt.Fprintf(conn, "+ idling\r\n")

		case "LOGOUT":
			fmt.Fprintf(conn, "* BYE logging out\r\n")
			fmt.Fprintf(conn, "%s OK LOGOUT completed\r\n", tag)

		default:
			fmt.Fprintf(conn, "%s BAD unknown command\r\n", tag)
		}
	}
}

// FloodingMode selects FloodingServer's misbehavior, mirroring
// FloodingIMAPServer.Mode.
type FloodingMode int

const (
	// UntaggedLineFlood sends a normal greeting, then on the first line
	// received from the client floods untagged "* junk" lines forever
	// without ever sending a tagged completion — exercises
	// readUntilTagged's per-command line-count/byte bound.
	UntaggedLineFlood FloodingMode = iota
	// OversizedLine sends a single ~20KB blob with no CRLF anywhere in
	// it, as soon as the connection opens — exercises the line-length
	// bound.
	OversizedLine
)

// FloodingServer is a raw, deliberately misbehaving fake IMAP-shaped TCP
// server used only by the imapclient limits tests.
type FloodingServer struct {
	Mode     FloodingMode
	mu       sync.Mutex
	listener net.Listener
}

func (s *FloodingServer) Start() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	s.mu.Lock()
	s.listener = ln
	s.mu.Unlock()
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go s.handleConn(conn)
		}
	}()
	return ln.Addr().(*net.TCPAddr).Port, nil
}

func (s *FloodingServer) Stop() {
	s.mu.Lock()
	ln := s.listener
	s.mu.Unlock()
	if ln != nil {
		_ = ln.Close()
	}
}

func (s *FloodingServer) handleConn(conn net.Conn) {
	defer conn.Close()
	switch s.Mode {
	case UntaggedLineFlood:
		fmt.Fprintf(conn, "* OK fake IMAP ready\r\n")
		// Wait for the client's first command line (LOGIN), then flood.
		reader := bufio.NewReader(conn)
		if _, err := reader.ReadString('\n'); err != nil {
			return
		}
		var flood strings.Builder
		// Comfortably past the 500-line/256KB bound so the test isn't
		// racing the exact threshold.
		for i := 0; i < 2000; i++ {
			flood.WriteString("* junk untagged response line\r\n")
		}
		_, _ = conn.Write([]byte(flood.String()))
		// Keep the connection open (never send a tagged completion) until
		// the client gives up and closes it.
		_, _ = reader.ReadString('\n')
	case OversizedLine:
		_, _ = conn.Write([]byte(strings.Repeat("A", 20_000)))
		// Hold the connection open so the client's failure is the length
		// bound, not a connection reset.
		buf := make([]byte, 1)
		_, _ = conn.Read(buf)
	}
}
