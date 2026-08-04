// preview_parse.go decodes the two literals UIDFetchPreviews reads —
// BODY.PEEK[HEADER.FIELDS (...)] and BODY.PEEK[TEXT]<0.32768> — into a
// MessagePreview, for RELAY_CONTENT_PREVIEW (opt-in new-mail content
// preview, Phase 2). Deliberately narrow in scope, mirroring
// UIDFetchPreviews's own doc comment: no ENVELOPE/BODYSTRUCTURE grammar,
// no charset transcoding beyond RFC 2047 encoded-words in headers (the
// stdlib's mime.WordDecoder only decodes "us-ascii"/"iso-8859-1"/"utf-8"
// without a CharsetReader this package doesn't register — an encoded-word
// in another charset, e.g. legacy ISO-2022-JP mail, is left un-decoded
// rather than mis-decoded). Every decode step here is best-effort: a
// malformed or truncated header/body degrades to empty/partial fields,
// never an error — see parsePreview's doc comment for why the whole batch
// must not fail over one bad message.
package imapclient

import (
	"bytes"
	"encoding/base64"
	"html"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net/mail"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

// maxPreviewBytes caps MessagePreview.BodyPreview after every decode step
// — the FETCH command itself already caps the raw source at 32KB
// (BODY.PEEK[TEXT]<0.32768>), but decoding (quoted-printable/base64
// expansion, HTML tag stripping) can still leave more than is useful for a
// notification-sized preview.
const maxPreviewBytes = 8192

// maxDecodedPartBytes bounds how much of any single MIME part (multipart
// or the whole body, whichever this ends up reading) this package will
// hold in memory while decoding — generous relative to the 32KB the FETCH
// command already capped the source at, but still a concrete ceiling
// rather than an unbounded io.ReadAll (CLAUDE-SECURITY F8 posture, applied
// here even though the byte source is already small: this package
// shouldn't rely solely on an upstream cap staying exactly what it is
// today).
const maxDecodedPartBytes = 1 << 20

// MessagePreview is what UIDFetchPreviews returns per message: enough to
// show a real sender/subject/snippet in a push notification instead of the
// content-free "you have new mail" the relay sent before
// RELAY_CONTENT_PREVIEW. Field values are best-effort decoded text, never
// raw MIME.
type MessagePreview struct {
	UID         uint32
	FromName    string
	FromAddress string
	Subject     string
	Date        time.Time
	MessageID   string
	BodyPreview string
}

// parsePreview decodes one message's HEADER.FIELDS and TEXT literals into
// a MessagePreview. Never returns an error — every internal decode step
// degrades gracefully (see this file's doc comment) so one malformed
// message can never cost the whole UIDFetchPreviews batch; the worst case
// is a MessagePreview with some empty fields.
func parsePreview(uid uint32, headerBytes, textBytes []byte) MessagePreview {
	preview := MessagePreview{UID: uid}

	// net/mail.ReadMessage wants headers followed by a blank line before
	// it will hand back a Header at all — a HEADER.FIELDS literal from a
	// well-behaved IMAP server already ends in one (RFC 3501 §6.4.5), but
	// tolerate its absence too rather than losing every field over a
	// missing trailing CRLF.
	raw := headerBytes
	if !bytes.HasSuffix(raw, []byte("\r\n\r\n")) {
		raw = append(append([]byte(nil), raw...), []byte("\r\n\r\n")...)
	}
	var header mail.Header
	if msg, err := mail.ReadMessage(bytes.NewReader(raw)); err == nil {
		header = msg.Header
	}

	decoder := new(mime.WordDecoder)
	if subject := header.Get("Subject"); subject != "" {
		preview.Subject = decodeMIMEWords(decoder, subject)
	}
	if from := header.Get("From"); from != "" {
		if addrs, err := header.AddressList("From"); err == nil && len(addrs) > 0 {
			preview.FromName = decodeMIMEWords(decoder, addrs[0].Name)
			preview.FromAddress = addrs[0].Address
		} else {
			// Unparseable From (malformed, or a display name with syntax
			// mail.ParseAddressList rejects) — still surface something
			// rather than nothing.
			preview.FromName = decodeMIMEWords(decoder, from)
		}
	}
	if dateStr := header.Get("Date"); dateStr != "" {
		if t, err := mail.ParseDate(dateStr); err == nil {
			preview.Date = t
		}
	}
	preview.MessageID = strings.Trim(header.Get("Message-Id"), "<>")

	body := extractTextPreview(header.Get("Content-Type"), header.Get("Content-Transfer-Encoding"), textBytes)
	preview.BodyPreview = truncateUTF8(body, maxPreviewBytes)

	return preview
}

// decodeMIMEWords best-effort RFC 2047-decodes s (mail header encoded
// words, e.g. `=?UTF-8?B?...?=` — the shape a Japanese subject line
// arrives in from virtually every modern mail client). Returns s unchanged
// if it isn't (or this decoder can't handle) encoded-word syntax, rather
// than dropping the header value.
func decodeMIMEWords(decoder *mime.WordDecoder, s string) string {
	decoded, err := decoder.DecodeHeader(s)
	if err != nil {
		return s
	}
	return decoded
}

// extractTextPreview turns the raw BODY.PEEK[TEXT] bytes into a plain-text
// snippet, given the message's (or, for a multipart part, that part's)
// Content-Type and Content-Transfer-Encoding. text/plain and text/html are
// decoded directly; multipart delegates to extractFromMultipart to find a
// text/plain part (falling back to a stripped text/html part); anything
// else (an unrecognized/missing Content-Type) is treated as text/plain per
// RFC 2045 §5.2's default.
func extractTextPreview(contentType, topLevelCTE string, textBytes []byte) string {
	mediaType, params, err := mime.ParseMediaType(contentType)
	if err != nil || mediaType == "" {
		return decodeBodyBytes(textBytes, topLevelCTE)
	}
	if strings.HasPrefix(mediaType, "multipart/") {
		boundary := params["boundary"]
		if boundary == "" {
			return decodeBodyBytes(textBytes, topLevelCTE)
		}
		if text, ok := extractFromMultipart(textBytes, boundary); ok {
			return text
		}
		// BODY.PEEK[TEXT]<0.32768> may have truncated the multipart body
		// mid-part, which multipart.Reader can't parse at all — fall back
		// to whatever plain text is recoverable rather than an empty
		// preview.
		return stripHTMLTags(string(textBytes))
	}
	decoded := decodeBodyBytes(textBytes, topLevelCTE)
	if mediaType == "text/html" {
		return stripHTMLTags(decoded)
	}
	return decoded
}

// extractFromMultipart walks a multipart body's parts looking for the
// first text/plain part; failing that, the first text/html part
// (tag-stripped). Recurses one level into a nested multipart part (e.g.
// multipart/alternative inside multipart/mixed, a common shape). Returns
// ok == false if no usable text was found at all — including when
// multipart.Reader itself fails, which happens routinely here since
// BODY.PEEK[TEXT]<0.32768> can (and for any message over 32KB, will) cut
// the MIME body off mid-part.
func extractFromMultipart(textBytes []byte, boundary string) (string, bool) {
	reader := multipart.NewReader(bytes.NewReader(textBytes), boundary)
	htmlFallback := ""
	for {
		part, err := reader.NextPart()
		if err != nil {
			break
		}
		partContentType := part.Header.Get("Content-Type")
		mediaType, params, parseErr := mime.ParseMediaType(partContentType)
		if parseErr != nil || mediaType == "" {
			mediaType = "text/plain"
		}
		if strings.HasPrefix(mediaType, "multipart/") {
			if boundary := params["boundary"]; boundary != "" {
				data, _ := io.ReadAll(io.LimitReader(part, maxDecodedPartBytes))
				if nested, ok := extractFromMultipart(data, boundary); ok {
					return nested, true
				}
			}
			continue
		}
		data, _ := io.ReadAll(io.LimitReader(part, maxDecodedPartBytes))
		decoded := decodeBodyBytes(data, part.Header.Get("Content-Transfer-Encoding"))
		switch mediaType {
		case "text/plain":
			return decoded, true
		case "text/html":
			if htmlFallback == "" {
				htmlFallback = stripHTMLTags(decoded)
			}
		}
	}
	if htmlFallback != "" {
		return htmlFallback, true
	}
	return "", false
}

// decodeBodyBytes reverses Content-Transfer-Encoding: quoted-printable or
// base64, or the raw bytes unchanged for anything else (7bit/8bit/binary,
// or no CTE header at all — RFC 2045 §6.1's default is 7bit, which is
// already what "unchanged" gives). Both decoders tolerate truncated input
// (BODY.PEEK[TEXT]<0.32768> can cut either encoding off mid-sequence)
// rather than returning nothing.
func decodeBodyBytes(data []byte, cte string) string {
	switch strings.ToLower(strings.TrimSpace(cte)) {
	case "quoted-printable":
		decoded, err := io.ReadAll(quotedprintable.NewReader(bytes.NewReader(data)))
		if err == nil {
			return string(decoded)
		}
		// quotedprintable.Reader stops at the first malformed escape
		// (typically the truncated tail) without handing back what it
		// decoded up to that point — re-decode everything except a
		// shrinking tail until it succeeds, same tolerance strategy as
		// decodeBase64Tolerant below.
		for cut := 3; cut <= len(data) && cut <= 3+8; cut++ {
			decoded, err := io.ReadAll(quotedprintable.NewReader(bytes.NewReader(data[:len(data)-cut])))
			if err == nil {
				return string(decoded)
			}
		}
		return string(data)
	case "base64":
		return decodeBase64Tolerant(data)
	default:
		return string(data)
	}
}

// decodeBase64Tolerant decodes standard base64, shrinking the input by
// whole 4-byte groups from the end until it decodes cleanly — a
// BODY.PEEK[TEXT]<0.32768>-truncated base64 body almost never ends on a
// 4-byte boundary, and the stdlib decoder rejects the whole input rather
// than returning a partial result.
func decodeBase64Tolerant(data []byte) string {
	compact := strings.Map(func(r rune) rune {
		if r == '\r' || r == '\n' || r == ' ' || r == '\t' {
			return -1
		}
		return r
	}, string(data))
	for n := len(compact) - len(compact)%4; n > 0; n -= 4 {
		if decoded, err := base64.StdEncoding.DecodeString(compact[:n]); err == nil {
			return string(decoded)
		}
	}
	return ""
}

var (
	htmlTagPattern         = regexp.MustCompile(`(?is)<[^>]*>`)
	htmlScriptStylePattern = regexp.MustCompile(`(?is)<(script|style)\b[^>]*>.*?</(script|style)>`)
	whitespacePattern      = regexp.MustCompile(`\s+`)
)

// stripHTMLTags reduces an HTML body to a plain-text snippet: drop
// script/style blocks wholesale, strip every remaining tag, unescape HTML
// entities, and collapse whitespace. This is a preview-quality strip, not
// a sanitizer or renderer — the result only ever reaches a push
// notification's text and this package's own tests, never anything that
// interprets HTML/JS, so a crude regex-based approach is an intentional
// scope choice, not an oversight.
func stripHTMLTags(s string) string {
	s = htmlScriptStylePattern.ReplaceAllString(s, " ")
	s = htmlTagPattern.ReplaceAllString(s, " ")
	s = html.UnescapeString(s)
	s = whitespacePattern.ReplaceAllString(s, " ")
	return strings.TrimSpace(s)
}

// truncateUTF8 cuts s to at most maxBytes without splitting a multi-byte
// rune, then replaces any remaining invalid UTF-8 (e.g. a body whose
// actual charset wasn't UTF-8 — charset transcoding beyond RFC 2047
// header encoded-words is out of scope here, see this file's doc comment)
// so the result is always safe to embed in a JSON string.
func truncateUTF8(s string, maxBytes int) string {
	if len(s) > maxBytes {
		s = s[:maxBytes]
		for len(s) > 0 && !utf8.RuneStart(s[len(s)-1]) {
			s = s[:len(s)-1]
		}
	}
	return strings.ToValidUTF8(s, "")
}
