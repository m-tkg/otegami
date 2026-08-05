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
	"sort"
	"strconv"
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
	// RateLimitStatusCount, when > 0, makes the next that many STATUS
	// commands answer `NO [LIMIT] STATUS Rate limit hit.` (mirroring the
	// exact Yahoo Japan production response — Task #206) instead of the
	// normal OK reply, decrementing by one per rejected STATUS. The
	// connection itself is left open and otherwise fully functional
	// throughout, matching the real server's behavior: this is used by
	// the watcher pool test that confirms `[LIMIT]` is waited out on the
	// same connection rather than triggering a reconnect+relogin.
	RateLimitStatusCount int

	// RateLimitWindow / RateLimitWindowBudget (Task #215), when both set,
	// reject any command beyond RateLimitWindowBudget received within a
	// RateLimitWindow-long period with `NO [LIMIT] <CMD> Rate limit hit.`
	// — every command (including LOGIN) counts, across every connection,
	// and the budget resets to zero every RateLimitWindow of wall-clock
	// time regardless of connection boundaries. This models the
	// production evidence behind Task #215 (docs/architecture.md pitfall
	// "i." Task #215 addendum): Yahoo Japan hit `[LIMIT]` at almost
	// exactly one hour after LOGIN, twice, at a command volume matching a
	// fixed hourly budget — not a per-connection command count (unlike
	// RateLimitStatusCount above, which is Task #206's narrower "the Nth
	// STATUS on this one connection" fixture). LOGOUT is never rejected
	// (a client giving up its connection shouldn't itself be rate
	// limited).
	RateLimitWindow       time.Duration
	RateLimitWindowBudget int

	// Messages backs UID FETCH (RELAY_CONTENT_PREVIEW's content-preview
	// fetch, Task-#-less Phase 2 addition): a FakeMessage per UID this
	// server will answer a "UID FETCH a:b (...)" range query for, keyed by
	// UID. Tests populate this directly (no IMAP APPEND support here) —
	// see AddMessage.
	Messages map[uint32]FakeMessage

	// ReverseFetchItemOrder, when true, answers a UID FETCH's two data
	// items in BODY[TEXT], then BODY[HEADER.FIELDS] order — the reverse of
	// this client's own request order (imapclient.Client.UIDFetchPreviews
	// always asks for HEADER.FIELDS first) — instead of the default
	// request-matching order. This reproduces the exact response shape
	// observed from imap.gmail.com in production: real servers are free to
	// answer a multi-item FETCH in whatever order they choose (RFC 3501
	// never promises request order), and Gmail is the confirmed case that
	// does so for this exact request. Used by the imapclient test that
	// confirms pairFetchLiterals (client.go) recovers the correct
	// header/body pairing from response order rather than trusting request
	// order.
	ReverseFetchItemOrder bool

	mu              sync.Mutex
	listener        net.Listener
	clientConn      net.Conn
	exists          int
	uidNext         int
	loginCount      int
	windowStart     time.Time
	windowCount     int
	rejectedCount   int
	loginAttemptLog []time.Time
}

// FakeMessage is one UID FETCH-able message this server knows about —
// enough to answer the exact FETCH shape UIDFetchPreviews
// (internal/imapclient/client.go) sends: `UID FETCH a:b (UID
// BODY.PEEK[HEADER.FIELDS (...)] BODY.PEEK[TEXT]<0.32768>)`. HeaderFields
// and Text are sent back as IMAP literals ({N}\r\n<N bytes>), same as a
// real server would for this FETCH shape — this is the one command this
// fake server needs literal support for.
type FakeMessage struct {
	HeaderFields string // raw header block this server returns verbatim for HEADER.FIELDS
	Text         string // raw body text this server returns verbatim for BODY.PEEK[TEXT]<0.32768>
}

// AddMessage registers uid as UID FETCH-able, returning HeaderFields/Text
// verbatim as literals when a client's UID FETCH range includes it.
func (s *FakeServer) AddMessage(uid uint32, msg FakeMessage) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.Messages == nil {
		s.Messages = map[uint32]FakeMessage{}
	}
	s.Messages[uid] = msg
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

// RejectedCount returns how many commands so far were refused with
// `[LIMIT]` under RateLimitWindow/RateLimitWindowBudget — Task #215's
// tests use this to confirm the poll design's real-world command volume
// stays under a simulated hourly budget (zero rejections) versus a
// deliberately tight budget it must recover from without spiraling.
func (s *FakeServer) RejectedCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.rejectedCount
}

// LoginAttempts returns the wall-clock time of every LOGIN command
// received so far (accepted or rejected) — Task #215's rate-limit-recovery
// test uses the gaps between these to confirm a rejected connection
// attempt backs off rather than immediately retrying (the exact pattern
// that turned a rate limit into an hours-long auth lockout in production —
// see Options.RateLimitInitialWait's doc comment).
func (s *FakeServer) LoginAttempts() []time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]time.Time(nil), s.loginAttemptLog...)
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

// consumeRateLimitedStatus decrements RateLimitStatusCount and reports
// whether this STATUS call should be rejected with `[LIMIT]`.
func (s *FakeServer) consumeRateLimitedStatus() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.RateLimitStatusCount <= 0 {
		return false
	}
	s.RateLimitStatusCount--
	return true
}

// admitCommand applies RateLimitWindow/RateLimitWindowBudget (Task #215):
// reports whether the command currently being processed fits within the
// current window's budget, resetting the window (and its count) the
// moment RateLimitWindow has elapsed since it last reset. A zero
// RateLimitWindow or RateLimitWindowBudget always admits (the default,
// matching every test fixture that doesn't opt into this).
func (s *FakeServer) admitCommand() bool {
	if s.RateLimitWindow <= 0 || s.RateLimitWindowBudget <= 0 {
		return true
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	if s.windowStart.IsZero() || now.Sub(s.windowStart) >= s.RateLimitWindow {
		s.windowStart = now
		s.windowCount = 0
	}
	s.windowCount++
	if s.windowCount > s.RateLimitWindowBudget {
		s.rejectedCount++
		return false
	}
	return true
}

// recordLoginAttempt appends now to loginAttemptLog — called for every
// LOGIN received, accepted or rejected (see LoginAttempts's doc comment).
func (s *FakeServer) recordLoginAttempt() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.loginAttemptLog = append(s.loginAttemptLog, time.Now())
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

		// Recorded regardless of admission below — Task #215's
		// spiral-guard test needs the timestamp of every attempt,
		// including ones the rate limiter itself goes on to reject.
		if command == "LOGIN" {
			s.recordLoginAttempt()
		}

		// Task #215: a rate-limited window applies to every command except
		// LOGOUT (a client giving up its connection isn't the kind of load
		// a rate limiter needs to punish) — checked before the normal
		// per-command handling below, mirroring the real Yahoo Japan
		// response shape regardless of which command triggered it.
		if command != "LOGOUT" && !s.admitCommand() {
			fmt.Fprintf(conn, "%s NO [LIMIT] %s Rate limit hit.\r\n", tag, command)
			continue
		}

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
			if s.consumeRateLimitedStatus() {
				fmt.Fprintf(conn, "%s NO [LIMIT] STATUS Rate limit hit.\r\n", tag)
				break
			}
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

		case "UID":
			if len(parts) < 3 {
				fmt.Fprintf(conn, "%s BAD missing UID argument\r\n", tag)
				break
			}
			rest := strings.TrimSpace(parts[2])
			if !strings.HasPrefix(strings.ToUpper(rest), "FETCH ") {
				fmt.Fprintf(conn, "%s BAD unsupported UID subcommand\r\n", tag)
				break
			}
			s.handleUIDFetch(conn, tag, strings.TrimSpace(rest[len("FETCH "):]))

		default:
			fmt.Fprintf(conn, "%s BAD unknown command\r\n", tag)
		}
	}
}

// handleUIDFetch answers the one UID FETCH shape UIDFetchPreviews
// (internal/imapclient/client.go) ever sends — `<range> (UID
// BODY.PEEK[HEADER.FIELDS (...)] BODY.PEEK[TEXT]<0.32768>)` — by returning
// every registered Messages entry within <range> as an untagged FETCH
// response carrying two IMAP literals (HeaderFields, then Text), mirroring
// a real server's literal framing exactly (RFC 3501 §4.3: "{N}\r\n"
// followed by N raw octets). Doesn't attempt to parse the requested item
// list beyond the range — this fake server always answers with both
// literals regardless of exactly which BODY.PEEK items were named, since
// the one client that talks to it only ever asks for these two.
func (s *FakeServer) handleUIDFetch(conn net.Conn, tag, fetchArgs string) {
	rangeStr := fetchArgs
	if idx := strings.IndexAny(fetchArgs, " \t"); idx >= 0 {
		rangeStr = fetchArgs[:idx]
	}
	bounds := strings.SplitN(rangeStr, ":", 2)
	start, err := strconv.ParseUint(bounds[0], 10, 32)
	end := start
	if err == nil && len(bounds) == 2 {
		if bounds[1] == "*" {
			end = ^uint64(0)
		} else {
			end, err = strconv.ParseUint(bounds[1], 10, 32)
		}
	}
	if err != nil {
		fmt.Fprintf(conn, "%s BAD malformed UID FETCH range\r\n", tag)
		return
	}

	s.mu.Lock()
	var uids []uint32
	for uid := range s.Messages {
		if uint64(uid) >= start && uint64(uid) <= end {
			uids = append(uids, uid)
		}
	}
	messages := s.Messages
	s.mu.Unlock()
	sort.Slice(uids, func(i, j int) bool { return uids[i] < uids[j] })

	s.mu.Lock()
	reversed := s.ReverseFetchItemOrder
	s.mu.Unlock()

	for seq, uid := range uids {
		msg := messages[uid]
		header := []byte(msg.HeaderFields)
		text := []byte(msg.Text)
		if reversed {
			fmt.Fprintf(conn, "* %d FETCH (UID %d BODY[TEXT]<0.32768> {%d}\r\n", seq+1, uid, len(text))
			conn.Write(text)
			fmt.Fprintf(conn, " BODY[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] {%d}\r\n", len(header))
			conn.Write(header)
			fmt.Fprintf(conn, ")\r\n")
			continue
		}
		fmt.Fprintf(conn, "* %d FETCH (UID %d BODY[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] {%d}\r\n", seq+1, uid, len(header))
		conn.Write(header)
		fmt.Fprintf(conn, " BODY[TEXT]<0.32768> {%d}\r\n", len(text))
		conn.Write(text)
		fmt.Fprintf(conn, ")\r\n")
	}
	fmt.Fprintf(conn, "%s OK UID FETCH completed\r\n", tag)
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
