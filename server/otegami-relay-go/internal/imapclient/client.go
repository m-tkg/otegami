// Package imapclient is a deliberately tiny IMAP client covering exactly
// what the watcher pool needs: LOGIN, AUTHENTICATE XOAUTH2, SELECT, STATUS
// (UIDNEXT), IDLE/DONE, LOGOUT. Mirrors MinimalIMAPClient.swift
// (server/otegami-relay/Sources/OtegamiRelay/Watcher/MinimalIMAPClient.swift)
// — see that file's doc comment for the full rationale on why this isn't
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
// deadline.
func (c *Client) readUntilTagged(tag string, perLineTimeout, overallDeadline time.Duration) ([]string, error) {
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
		if len(untagged) > maxUntaggedLinesPerCommand || totalBytes > maxUntaggedBytesPerCommand {
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
