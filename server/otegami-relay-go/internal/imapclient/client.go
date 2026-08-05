// Package imapclient is a deliberately tiny IMAP client covering exactly
// what the watcher pool needs: LOGIN, AUTHENTICATE XOAUTH2, SELECT, STATUS
// (UIDNEXT), IDLE/DONE, LOGOUT. Mirrors the retired Swift relay's
// MinimalIMAPClient. This isn't
// built on a general-purpose IMAP library (github.com/emersion/go-imap):
// none of the commands here ever involve IMAP literals, so a plain
// CRLF-line-oriented reader is sufficient, and the CLAUDE-SECURITY F2/F3/
// F4/F8 defenses (SSRF re-validation per connect, control-character
// rejection, response size/line-count/deadline bounds) need to sit
// directly on this type's read/write path.
//
// Unlike the Swift version, this port doesn't need the elaborate
// actor-based LineBuffer the Swift file's doc comment describes at
// length: that machinery existed only to work around
// AsyncStream/structured-concurrency cancellation semantics (a timed-out
// read permanently killing the stream). Go's net.Conn deadlines don't
// have that problem — SetReadDeadline expiring just fails that one Read
// call with a timeout error; the connection and any subsequent Read
// remain perfectly usable after resetting the deadline. So every "wait up
// to N seconds for the next line" operation below is a plain
// SetReadDeadline + Read, no persistent pump goroutine required.
package imapclient

import (
	"bufio"
	"crypto/tls"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/m-tkg/otegami-relay-go/internal/security"
)

// CLAUDE-SECURITY F4/F8 bounds — identical values to MinimalIMAPClient's.
const (
	maxLineLength              = 8192
	maxUntaggedLinesPerCommand = 500
	maxUntaggedBytesPerCommand = 262_144
)

// CLAUDE-SECURITY F4/F8 bounds for UIDFetchPreviews (RELAY_CONTENT_PREVIEW,
// opt-in) — the only command this client issues that can carry IMAP
// literals. Kept separate from maxUntaggedBytesPerCommand/
// maxUntaggedLinesPerCommand above (every other command this client speaks
// stays on the original, smaller bound — see readUntilTagged's now-
// parameterized bounds) since a handful of message previews (headers +
// 32KB-capped body excerpts each) legitimately needs a larger budget than
// the plain STATUS/SELECT/CAPABILITY responses those bounds were sized
// for.
const (
	// maxLiteralBytes caps a single IMAP literal ({N}\r\n<N bytes>) this
	// client will read. Comfortably above the ~32KB BODY.PEEK[TEXT]<0.32768>
	// range this client itself requests, with headroom for the
	// HEADER.FIELDS literal alongside it; a server claiming a larger N is
	// refused outright before any read is attempted (CLAUDE-SECURITY F8 —
	// no allocation sized by unchecked attacker input).
	maxLiteralBytes = 65_536
	// maxFetchBytesPerCommand bounds the total bytes (plain-text response
	// lines plus every literal's payload) read across one whole UID FETCH
	// command's untagged responses.
	maxFetchBytesPerCommand = 524_288
	// maxFetchRecordsPerCommand bounds how many untagged "* n FETCH (...)"
	// responses one UIDFetchPreviews call collects — the watcher pool never
	// requests more than a handful of UIDs at once, so this is a generous
	// ceiling against a misbehaving/hostile peer claiming far more.
	maxFetchRecordsPerCommand = 200
	// maxLiteralsPerLogicalLine bounds how many literals a single untagged
	// FETCH response line may contain before this client gives up on it —
	// this client's own FETCH command only ever requests two (the header
	// fields literal, then the body-text literal), so anything past a
	// small multiple of that is unambiguously a misbehaving peer, not a
	// slow/fragmented legitimate response. Without this bound, a peer that
	// keeps ending physical lines in a valid-but-tiny "{1}\r\nX" literal
	// spec forever could otherwise make readLiteralAwareLine loop
	// unbounded — each iteration is itself time- and size-bounded, but the
	// iteration count was not.
	maxLiteralsPerLogicalLine = 8
)

var (
	ErrNotConnected     = errors.New("IMAP client is not connected")
	ErrConnectionClosed = errors.New("IMAP connection closed unexpectedly")
	ErrTimedOut         = errors.New("IMAP command timed out")
	ErrResponseTooLarge = errors.New("IMAP response exceeded the relay's size/line-count limit")
)

// CommandFailedError mirrors IMAPClientError.commandFailed.
type CommandFailedError struct {
	Tag      string
	Response string
}

func (e *CommandFailedError) Error() string {
	return fmt.Sprintf("IMAP command %s failed: %s", e.Tag, e.Response)
}

// UnexpectedResponseError mirrors IMAPClientError.unexpectedResponse.
type UnexpectedResponseError struct{ Line string }

func (e *UnexpectedResponseError) Error() string {
	return fmt.Sprintf("unexpected IMAP response: %s", e.Line)
}

// SelectResult mirrors MinimalIMAPClient.SelectResult.
type SelectResult struct {
	Exists  int
	UidNext *int
}

// Client is a single IMAP connection. Command methods are not safe for
// concurrent use from multiple goroutines (mirrors MinimalIMAPClient's
// single-connection, single-caller usage from one watch's loop) — but
// Close specifically IS safe to call concurrently with an in-flight
// command: the watcher pool uses that (via context.AfterFunc) to unblock
// a Read that's mid-IDLE the moment a watch is removed, the same prompt
// teardown Swift's Task cancellation gives WatcherPool.removeWatch.
type Client struct {
	// mu guards conn's pointer only (assignment in Connect, nil-out in
	// Close). The reader/partial/tagCounter state is touched exclusively
	// by the single command-issuing goroutine.
	mu         sync.Mutex
	conn       net.Conn
	reader     *bufio.Reader
	tagCounter int
	// partial holds bytes of a line whose terminator hadn't arrived yet
	// when a read deadline expired — preserved so the next nextLine call
	// continues the same line instead of silently truncating it (the
	// Swift client's frame decoder holds partial frames the same way).
	partial []byte
}

// currentConn snapshots the connection under mu — every use of the conn
// outside Connect/Close goes through this so a concurrent Close can't
// race the pointer read.
func (c *Client) currentConn() net.Conn {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.conn
}

// New creates an unconnected Client.
func New() *Client {
	return &Client{}
}

// Connect dials host:port (resolved and validated via networkPolicy,
// re-checked on every call — CLAUDE-SECURITY F2, closes the DNS-rebinding
// gap the same way MinimalIMAPClient.connect does), optionally negotiates
// TLS, and consumes the server's untagged greeting.
func (c *Client) Connect(host string, port int, useTLS bool, timeout time.Duration, networkPolicy security.NetworkPolicy) error {
	resolvedIP, err := networkPolicy.ResolveAndValidate(host, port)
	if err != nil {
		return err
	}

	dialer := net.Dialer{Timeout: timeout}
	address := net.JoinHostPort(resolvedIP.String(), strconv.Itoa(port))
	conn, err := dialer.Dial("tcp", address)
	if err != nil {
		return err
	}

	if useTLS {
		// serverHostname (SNI/certificate verification) must stay the
		// original hostname, not the resolved IP — mirrors
		// NIOSSLClientHandler(context:serverHostname:) in the Swift
		// client.
		tlsConn := tls.Client(conn, &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12})
		if err := tlsConn.SetDeadline(time.Now().Add(timeout)); err != nil {
			conn.Close()
			return err
		}
		if err := tlsConn.Handshake(); err != nil {
			conn.Close()
			return err
		}
		_ = tlsConn.SetDeadline(time.Time{})
		conn = tlsConn
	}

	c.mu.Lock()
	c.conn = conn
	c.mu.Unlock()
	c.reader = bufio.NewReaderSize(conn, maxLineLength+16)
	c.partial = nil

	// Consume the server's untagged greeting ("* OK ... ready").
	if _, err := c.nextLine(timeout); err != nil {
		_ = c.Close()
		return err
	}
	return nil
}

// Close is safe to call from any goroutine, including concurrently with
// an in-flight command — closing the conn unblocks a pending Read, which
// surfaces as ErrConnectionClosed to the command's caller. It deliberately
// does not touch reader/partial (owned by the command goroutine).
func (c *Client) Close() error {
	c.mu.Lock()
	conn := c.conn
	c.conn = nil
	c.mu.Unlock()
	if conn == nil {
		return nil
	}
	return conn.Close()
}

func (c *Client) nextTag() string {
	c.tagCounter++
	return fmt.Sprintf("A%d", c.tagCounter)
}

func (c *Client) write(line string) error {
	conn := c.currentConn()
	if conn == nil {
		return ErrNotConnected
	}
	_, err := conn.Write([]byte(line + "\r\n"))
	return err
}

// nextLine waits up to timeout for the next CRLF-terminated line (CRLF
// stripped), bounded to maxLineLength — mirroring the Swift client's
// LineBasedFrameDecoder with maximumBufferSize (CLAUDE-SECURITY F8).
//
// Implementation note: this uses bufio.Reader.ReadSlice, NOT ReadString/
// ReadBytes — those two accumulate fragments across buffer refills
// without any bound, so a peer that never sends a line terminator would
// grow the relay's memory without limit, which is exactly the attack F8
// bounds against. ReadSlice caps a line at the reader's buffer size
// (maxLineLength+16 — bufio.ErrBufferFull → ErrResponseTooLarge), and the
// small partial-accumulation below is itself bounded by the same cap.
func (c *Client) nextLine(timeout time.Duration) (string, error) {
	conn := c.currentConn()
	if conn == nil {
		return "", ErrNotConnected
	}
	if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		return "", err
	}
	defer func() { _ = conn.SetReadDeadline(time.Time{}) }()

	for {
		chunk, err := c.reader.ReadSlice('\n')
		if len(chunk) > 0 {
			if len(c.partial)+len(chunk) > maxLineLength {
				c.partial = nil
				return "", ErrResponseTooLarge
			}
			c.partial = append(c.partial, chunk...)
		}
		switch {
		case err == nil:
			line := string(c.partial)
			c.partial = nil
			return strings.TrimRight(line, "\r\n"), nil
		case errors.Is(err, bufio.ErrBufferFull):
			// No terminator within the buffer — loop to keep consuming;
			// the length check above errors out once past maxLineLength.
			continue
		default:
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				// Keep c.partial: the line may complete after the caller's
				// next read (a timeout mid-line must not truncate it).
				return "", ErrTimedOut
			}
			c.partial = nil
			return "", ErrConnectionClosed
		}
	}
}

// readUntilTagged reads lines until a tagged response for tag arrives,
// collecting every untagged (*) line seen along the way. Mirrors
// MinimalIMAPClient.readUntilTagged's three-way bound (CLAUDE-SECURITY
// F4): untagged line count, total untagged bytes, and overall wall-clock
// deadline. Thin wrapper over readUntilTaggedBounded fixing the bounds
// every command except UIDFetchPreviews uses.
func (c *Client) readUntilTagged(tag string, perLineTimeout, overallDeadline time.Duration) ([]string, error) {
	return c.readUntilTaggedBounded(tag, perLineTimeout, overallDeadline, maxUntaggedLinesPerCommand, maxUntaggedBytesPerCommand)
}

// readUntilTaggedBounded is readUntilTagged with the line-count/byte
// bounds taken as arguments rather than the maxUntaggedLinesPerCommand/
// maxUntaggedBytesPerCommand constants directly — pulled out so
// UIDFetchPreviews's larger maxFetchRecordsPerCommand/
// maxFetchBytesPerCommand bounds (RELAY_CONTENT_PREVIEW's handful of
// message previews legitimately needs more room than a plain STATUS/
// SELECT response) can share this exact bounding logic instead of
// duplicating it, without loosening the bound every other command still
// gets.
func (c *Client) readUntilTaggedBounded(tag string, perLineTimeout, overallDeadline time.Duration, maxLines, maxBytes int) ([]string, error) {
	var untagged []string
	totalBytes := 0
	deadline := time.Now().Add(overallDeadline)
	for {
		if time.Now().After(deadline) || time.Now().Equal(deadline) {
			return nil, ErrTimedOut
		}
		remaining := time.Until(deadline)
		if remaining > perLineTimeout {
			remaining = perLineTimeout
		}
		if remaining <= 0 {
			remaining = time.Millisecond
		}
		line, err := c.nextLine(remaining)
		if err != nil {
			return nil, err
		}
		if strings.HasPrefix(line, tag+" ") {
			if !strings.HasPrefix(line, tag+" OK") {
				return nil, &CommandFailedError{Tag: tag, Response: line}
			}
			return untagged, nil
		}
		untagged = append(untagged, line)
		totalBytes += len(line)
		if len(untagged) > maxLines || totalBytes > maxBytes {
			return nil, ErrResponseTooLarge
		}
	}
}

// Login issues a plain LOGIN — the .password auth path. Mirrors
// MinimalIMAPClient.login(username:password:).
func (c *Client) Login(username, password string) error {
	quotedUsername, err := quoted(username)
	if err != nil {
		return err
	}
	quotedPassword, err := quoted(password)
	if err != nil {
		return err
	}
	tag := c.nextTag()
	if err := c.write(fmt.Sprintf("%s LOGIN %s %s", tag, quotedUsername, quotedPassword)); err != nil {
		return err
	}
	_, err = c.readUntilTagged(tag, 35*time.Second, 90*time.Second)
	return err
}

// AuthenticateXOAuth2 mirrors
// MinimalIMAPClient.authenticateXOAuth2(username:accessToken:) — RFC
// 7628's SASL-IR XOAUTH2, Task #175's Gmail/Outlook auth path.
func (c *Client) AuthenticateXOAuth2(username, accessToken string) error {
	if err := security.ValidateNoControlCharacters(username, "imapUsername"); err != nil {
		return err
	}
	if err := security.ValidateNoControlCharacters(accessToken, "OAuth access token"); err != nil {
		return err
	}

	tag := c.nextTag()
	saslResponse := fmt.Sprintf("user=%s\x01auth=Bearer %s\x01\x01", username, accessToken)
	encoded := base64.StdEncoding.EncodeToString([]byte(saslResponse))
	if err := c.write(fmt.Sprintf("%s AUTHENTICATE XOAUTH2 %s", tag, encoded)); err != nil {
		return err
	}

	for i := 0; i < 8; i++ {
		line, err := c.nextLine(35 * time.Second)
		if err != nil {
			return err
		}
		if strings.HasPrefix(line, "+") {
			// A rejected token gets a `+` continuation carrying a base64
			// JSON error payload (RFC 7628 §3.2.2) — respond with an empty
			// line so the server completes the exchange with a tagged
			// NO/BAD.
			if err := c.write(""); err != nil {
				return err
			}
			continue
		}
		if strings.HasPrefix(line, tag+" ") {
			if !strings.HasPrefix(line, tag+" OK") {
				return &CommandFailedError{Tag: tag, Response: line}
			}
			return nil
		}
		// Untagged chatter around AUTHENTICATE — ignored.
	}
	return ErrResponseTooLarge
}

var existsPattern = regexp.MustCompile(`^\* (\d+) EXISTS`)
var uidNextPattern = regexp.MustCompile(`UIDNEXT (\d+)`)

// Select mirrors MinimalIMAPClient.select(mailbox:).
func (c *Client) Select(mailbox string) (SelectResult, error) {
	quotedMailbox, err := quoted(mailbox)
	if err != nil {
		return SelectResult{}, err
	}
	tag := c.nextTag()
	if err := c.write(fmt.Sprintf("%s SELECT %s", tag, quotedMailbox)); err != nil {
		return SelectResult{}, err
	}
	untagged, err := c.readUntilTagged(tag, 35*time.Second, 90*time.Second)
	if err != nil {
		return SelectResult{}, err
	}
	result := SelectResult{}
	for _, line := range untagged {
		if m := existsPattern.FindStringSubmatch(line); m != nil {
			if v, err := strconv.Atoi(m[1]); err == nil {
				result.Exists = v
			}
		}
		if m := uidNextPattern.FindStringSubmatch(line); m != nil {
			if v, err := strconv.Atoi(m[1]); err == nil {
				result.UidNext = &v
			}
		}
	}
	return result, nil
}

// StatusUIDNext mirrors MinimalIMAPClient.statusUIDNext(mailbox:) — the
// polling fallback for servers without IDLE, and the belt-and-suspenders
// re-check after every IDLE wake.
func (c *Client) StatusUIDNext(mailbox string) (int, error) {
	quotedMailbox, err := quoted(mailbox)
	if err != nil {
		return 0, err
	}
	tag := c.nextTag()
	if err := c.write(fmt.Sprintf("%s STATUS %s (UIDNEXT)", tag, quotedMailbox)); err != nil {
		return 0, err
	}
	untagged, err := c.readUntilTagged(tag, 35*time.Second, 90*time.Second)
	if err != nil {
		return 0, err
	}
	for _, line := range untagged {
		if m := uidNextPattern.FindStringSubmatch(line); m != nil {
			if v, err := strconv.Atoi(m[1]); err == nil {
				return v, nil
			}
		}
	}
	return 0, &UnexpectedResponseError{Line: strings.Join(untagged, " | ")}
}

// Noop issues a plain IMAP NOOP — the lightest possible round-trip that
// still counts as client traffic to a server watching for inactivity.
// Task #201: used by the watcher pool's polling fallback to keep a
// connection to an IDLE-incapable server (Yahoo Japan) from being dropped
// between STATUS checks.
func (c *Client) Noop() error {
	tag := c.nextTag()
	if err := c.write(fmt.Sprintf("%s NOOP", tag)); err != nil {
		return err
	}
	_, err := c.readUntilTagged(tag, 35*time.Second, 90*time.Second)
	return err
}

// CapabilitiesIncludeIdle mirrors MinimalIMAPClient.capabilitiesIncludeIdle().
func (c *Client) CapabilitiesIncludeIdle() (bool, error) {
	tag := c.nextTag()
	if err := c.write(fmt.Sprintf("%s CAPABILITY", tag)); err != nil {
		return false, err
	}
	untagged, err := c.readUntilTagged(tag, 35*time.Second, 90*time.Second)
	if err != nil {
		return false, err
	}
	for _, line := range untagged {
		upper := strings.ToUpper(line)
		if strings.Contains(upper, " IDLE") || strings.HasSuffix(upper, "IDLE") {
			return true, nil
		}
	}
	return false, nil
}

// Idle starts IDLE, then blocks until either an untagged EXISTS arrives or
// maxWait elapses (RFC 2177 recommends re-issuing IDLE at least every 29
// minutes; the caller passes that as the cap). Always sends DONE before
// returning. Mirrors MinimalIMAPClient.idle(mailbox:maxWaitSeconds:).
func (c *Client) Idle(mailbox string, maxWait time.Duration) (bool, error) {
	tag := c.nextTag()
	if err := c.write(fmt.Sprintf("%s IDLE", tag)); err != nil {
		return false, err
	}
	continuationLine, err := c.nextLine(35 * time.Second)
	if err != nil {
		return false, err
	}
	if !strings.HasPrefix(continuationLine, "+") {
		return false, &UnexpectedResponseError{Line: continuationLine}
	}

	sawExists := false
	deadline := time.Now().Add(maxWait)
	for time.Now().Before(deadline) {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			break
		}
		line, err := c.nextLine(remaining)
		if err != nil {
			if errors.Is(err, ErrTimedOut) {
				break
			}
			return false, err
		}
		if existsPattern.MatchString(line) {
			sawExists = true
			break
		}
		// Other untagged chatter during IDLE (EXPUNGE, FETCH flag
		// updates, "* 0 RECENT", ...) is ignored.
	}

	if err := c.write("DONE"); err != nil {
		return false, err
	}
	// An EXISTS slipping in right around the DONE/tagged-completion
	// handshake must still count.
	doneUntagged, err := c.readUntilTagged(tag, 35*time.Second, 90*time.Second)
	if err != nil {
		return false, err
	}
	if !sawExists {
		for _, line := range doneUntagged {
			if existsPattern.MatchString(line) {
				sawExists = true
				break
			}
		}
	}
	return sawExists, nil
}

// Logout mirrors MinimalIMAPClient.logout() — best-effort, errors ignored
// by the caller (the connection is being torn down regardless).
func (c *Client) Logout() error {
	tag := c.nextTag()
	if err := c.write(fmt.Sprintf("%s LOGOUT", tag)); err != nil {
		return err
	}
	_, err := c.readUntilTagged(tag, 5*time.Second, 5*time.Second)
	return err
}

// literalSuffixPattern matches an IMAP literal spec ("{123}") trailing a
// response line whose terminator has already been stripped by nextLine —
// RFC 3501 §4.3: a literal is introduced by "{octet-count}" immediately
// followed by CRLF, then exactly that many raw octets (which may contain
// anything, including CR/LF/NUL — this is IMAP's only length-prefixed,
// binary-safe framing, unlike every other line this client parses).
var literalSuffixPattern = regexp.MustCompile(`\{(\d+)\}$`)

// fetchRecord is one untagged "* n FETCH (...)" response's parsed shape,
// as read by readFetchResponses: the plain-text portions of the line
// (with literal spans removed) plus the literal byte blobs found, in the
// order they appeared. This package deliberately does not parse IMAP's
// full parenthesized-list response grammar (no ENVELOPE/BODYSTRUCTURE
// parser here) — UIDFetchPreviews only ever asks for UID plus two
// specific BODY.PEEK literals, so pairing "the Nth literal seen" with
// "which BODY.PEEK[...] item requested it" by request order is sufficient
// and far simpler than a general parser.
type fetchRecord struct {
	Text     string
	Literals [][]byte
}

// readLiteralBytes reads exactly n raw bytes directly off the buffered
// connection reader — unlike nextLine, this must not stop at any
// embedded CR/LF/NUL, since a literal's payload is arbitrary MIME bytes
// (RFC 3501 §4.3). n is always pre-validated by the caller against
// maxLiteralBytes before this is called (CLAUDE-SECURITY F8: no
// allocation sized directly by unchecked attacker input).
func (c *Client) readLiteralBytes(n int, timeout time.Duration) ([]byte, error) {
	conn := c.currentConn()
	if conn == nil {
		return nil, ErrNotConnected
	}
	if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		return nil, err
	}
	defer func() { _ = conn.SetReadDeadline(time.Time{}) }()
	buf := make([]byte, n)
	if _, err := io.ReadFull(c.reader, buf); err != nil {
		if ne, ok := err.(net.Error); ok && ne.Timeout() {
			return nil, ErrTimedOut
		}
		return nil, ErrConnectionClosed
	}
	return buf, nil
}

// readLiteralAwareLine reads one IMAP "logical line" — a plain nextLine
// read that, if it ends in a literal spec ("{N}"), is followed by reading
// exactly N raw literal bytes and then resuming line-reading for the
// remainder of the same logical response, repeating until a physical line
// is read that does NOT end in a literal spec (RFC 3501 §4.3: nothing
// distinguishes "the line is over" from "a literal follows" until you've
// looked at its last token). Bounded per literal (maxLiteralBytes, checked
// before any read is attempted) and per logical line (
// maxLiteralsPerLogicalLine — see that constant's doc comment for why an
// iteration bound is needed here that plain nextLine calls don't need).
func (c *Client) readLiteralAwareLine(timeout time.Duration) (string, [][]byte, error) {
	var text strings.Builder
	var literals [][]byte
	for {
		line, err := c.nextLine(timeout)
		if err != nil {
			return "", nil, err
		}
		if m := literalSuffixPattern.FindStringSubmatch(line); m != nil {
			n, convErr := strconv.Atoi(m[1])
			if convErr != nil || n < 0 || n > maxLiteralBytes {
				return "", nil, ErrResponseTooLarge
			}
			text.WriteString(line[:len(line)-len(m[0])])
			data, err := c.readLiteralBytes(n, timeout)
			if err != nil {
				return "", nil, err
			}
			literals = append(literals, data)
			if len(literals) > maxLiteralsPerLogicalLine {
				return "", nil, ErrResponseTooLarge
			}
			continue
		}
		text.WriteString(line)
		return text.String(), literals, nil
	}
}

// readFetchResponses reads UID FETCH's untagged responses until tag's
// tagged completion, using readLiteralAwareLine instead of plain nextLine
// for each response — the only place in this client where that's
// necessary, since BODY.PEEK[...] literals are the only literals this
// client's own commands ever provoke a server into sending. Bounded like
// readUntilTaggedBounded (record count, total bytes including every
// literal payload, overall wall-clock deadline) but via its own
// maxRecords/maxTotalBytes so UIDFetchPreviews can use a larger budget
// than every other command without loosening theirs (CLAUDE-SECURITY
// F4/F8).
func (c *Client) readFetchResponses(tag string, perLineTimeout, overallDeadline time.Duration, maxRecords, maxTotalBytes int) ([]fetchRecord, error) {
	var records []fetchRecord
	totalBytes := 0
	deadline := time.Now().Add(overallDeadline)
	for {
		if time.Now().After(deadline) || time.Now().Equal(deadline) {
			return nil, ErrTimedOut
		}
		remaining := time.Until(deadline)
		if remaining > perLineTimeout {
			remaining = perLineTimeout
		}
		if remaining <= 0 {
			remaining = time.Millisecond
		}
		text, literals, err := c.readLiteralAwareLine(remaining)
		if err != nil {
			return nil, err
		}
		if strings.HasPrefix(text, tag+" ") {
			if !strings.HasPrefix(text, tag+" OK") {
				return nil, &CommandFailedError{Tag: tag, Response: text}
			}
			return records, nil
		}
		totalBytes += len(text)
		for _, l := range literals {
			totalBytes += len(l)
		}
		records = append(records, fetchRecord{Text: text, Literals: literals})
		if len(records) > maxRecords || totalBytes > maxTotalBytes {
			return nil, ErrResponseTooLarge
		}
	}
}

// fetchUIDPattern extracts the "UID <n>" atom from an untagged FETCH
// response's plain-text portion. Requires a literal space right after
// "UID" so this can never accidentally match an unrelated atom sharing
// the prefix (there is none in this client's own FETCH response, but the
// guard costs nothing).
var fetchUIDPattern = regexp.MustCompile(`\bUID (\d+)`)

// UIDFetchPreviews issues one `UID FETCH <start>:<end> (UID
// BODY.PEEK[HEADER.FIELDS (...)] BODY.PEEK[TEXT]<0.32768>)` (RELAY_CONTENT_
// PREVIEW's content-preview fetch — see MessagePreview/preview_parse.go)
// and returns one MessagePreview per untagged FETCH response this client
// could make sense of. A response missing its UID atom or either expected
// literal is skipped rather than failing the whole batch — a handful of
// new messages arriving between the watcher's UIDNEXT check and this FETCH
// (or an unrelated FETCH flag-update line some servers interleave) should
// not cost every other message's preview. The caller (watcher pool) treats
// a wholly empty result the same as an error: fall back to the
// content-free push payload for this cycle.
func (c *Client) UIDFetchPreviews(start, end uint32, timeout time.Duration) ([]MessagePreview, error) {
	tag := c.nextTag()
	cmd := fmt.Sprintf(
		"%s UID FETCH %d:%d (UID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT]<0.32768>)",
		tag, start, end,
	)
	if err := c.write(cmd); err != nil {
		return nil, err
	}
	perLine := timeout
	if perLine > 35*time.Second {
		perLine = 35 * time.Second
	}
	records, err := c.readFetchResponses(tag, perLine, timeout, maxFetchRecordsPerCommand, maxFetchBytesPerCommand)
	if err != nil {
		return nil, err
	}
	previews := make([]MessagePreview, 0, len(records))
	for _, rec := range records {
		m := fetchUIDPattern.FindStringSubmatch(rec.Text)
		if m == nil {
			continue
		}
		uid, err := strconv.ParseUint(m[1], 10, 32)
		if err != nil {
			continue
		}
		if len(rec.Literals) < 2 {
			continue
		}
		header, body := pairFetchLiterals(rec.Text, rec.Literals)
		previews = append(previews, parsePreview(uint32(uid), header, body))
	}
	return previews, nil
}

// pairFetchLiterals decides which of rec.Literals[0]/[1] is the
// HEADER.FIELDS literal and which is the TEXT literal, based on which data
// item name appears first in rec.Text — not on the order this client itself
// requested them in the UID FETCH command above. RFC 3501 never promises a
// server answers a multi-item FETCH in request order, and imap.gmail.com is
// observed doing exactly that for this exact request shape: it answers
// BODY[TEXT] before BODY[HEADER.FIELDS]. Blindly assuming
// literals[0]=header/literals[1]=text against such a response silently
// swaps header and body — every parsed field (from/subject/date/message-id)
// comes out empty and bodyPreview ends up holding raw header text, which is
// exactly the corruption this function exists to prevent (confirmed against
// production Gmail watches). Matching is case-insensitive: Gmail answers in
// upper-case, but nothing in RFC 3501 requires that of every server.
func pairFetchLiterals(text string, literals [][]byte) (header, body []byte) {
	upper := strings.ToUpper(text)
	headerIdx := strings.Index(upper, "BODY[HEADER.FIELDS")
	textIdx := strings.Index(upper, "BODY[TEXT")
	if headerIdx >= 0 && textIdx >= 0 && headerIdx > textIdx {
		return literals[1], literals[0]
	}
	// Fallback for the case either item name wasn't found (shouldn't happen
	// for a well-formed response to this client's own request) or header
	// legitimately precedes text: assume request order, same as before this
	// function existed.
	return literals[0], literals[1]
}

// quoted mirrors MinimalIMAPClient.quoted(_:) — RFC 3501 §9 quoted-string
// escaping of `\` and `"`. Rejects (rather than escapes) any CR/LF/NUL/
// other control character, since quoted-string simply cannot carry one
// (CLAUDE-SECURITY F3).
func quoted(value string) (string, error) {
	if err := security.ValidateNoControlCharacters(value, "IMAP command argument"); err != nil {
		return "", err
	}
	escaped := strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(value)
	return `"` + escaped + `"`, nil
}
