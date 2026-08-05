// preview_parse.go decodes the two literals UIDFetchPreviews reads —
// BODY.PEEK[HEADER.FIELDS (...)] and BODY.PEEK[TEXT]<0.32768> — into a
// MessagePreview, for RELAY_CONTENT_PREVIEW (opt-in new-mail content
// preview, Phase 2). Deliberately narrow in scope, mirroring
// UIDFetchPreviews's own doc comment: no ENVELOPE/BODYSTRUCTURE grammar.
// Header encoded-words (RFC 2047, `=?charset?B/Q?...?=`) are decoded via
// mimeCharsetReader below, and body text is transcoded to UTF-8 from its
// Content-Type charset parameter via transcodeBody; both resolve charset
// labels through resolveCharset, which covers everything golang.org/x/text/
// encoding/ianaindex resolves to an implemented encoding.Encoding (in
// particular ISO-2022-JP and EUC-JP) plus a small manual alias table for
// common Japanese-mail charset labels ianaindex doesn't wire up or doesn't
// recognize as an IANA name at all (Shift_JIS/CP932/Windows-31J spellings —
// see japaneseCharsetAliases). A charset this can't resolve at all is left
// un-decoded rather than mis-decoded. Every decode step here is
// best-effort: a malformed or truncated header/body degrades to empty/
// partial fields, never an error — see parsePreview's doc comment for why
// the whole batch must not fail over one bad message.
package imapclient

import (
	"bytes"
	"encoding/base64"
	"fmt"
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

	"golang.org/x/text/encoding"
	"golang.org/x/text/encoding/ianaindex"
	"golang.org/x/text/encoding/japanese"
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

	decoder := &mime.WordDecoder{CharsetReader: mimeCharsetReader}
	if subject := header.Get("Subject"); subject != "" {
		preview.Subject = decodeMIMEWords(decoder, subject)
	}
	if from := header.Get("From"); from != "" {
		// mail.Header.AddressList (equivalently mail.ParseAddressList) always
		// parses with its own zero-value internal decoder, which has no way
		// to accept the CharsetReader above — there's no parameter for it.
		// An encoded-word charset it doesn't itself know (anything other
		// than utf-8/iso-8859-1/us-ascii) makes RFC 5322 phrase-parsing fail
		// outright for that word, not just leave it un-decoded, which would
		// otherwise make an ISO-2022-JP (or other non-UTF-8) display name
		// fall all the way through to the "else" branch below even though
		// mimeCharsetReader can decode it just fine. mail.AddressParser is
		// the one entry point that accepts a WordDecoder, so route through
		// it instead with the same decoder Subject/etc. use.
		addrParser := &mail.AddressParser{WordDecoder: decoder}
		if addrs, err := addrParser.ParseList(from); err == nil && len(addrs) > 0 {
			preview.FromName = decodeMIMEWords(decoder, addrs[0].Name)
			preview.FromAddress = addrs[0].Address
		} else {
			// Unparseable From (malformed, or a display name with syntax
			// mail.AddressParser rejects) — still surface something rather
			// than nothing.
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

// japaneseCharsetAliases covers encoded-word charset labels real-world
// Japanese mail clients use that golang.org/x/text/encoding/ianaindex
// either doesn't recognize as an IANA name at all (shift-jis with a hyphen,
// sjis, cp932, ms932 — none of these are registered IANA aliases) or
// recognizes but doesn't wire up to an implemented encoding.Encoding
// (windows-31j is IANA-registered, but ianaindex.MIME.Encoding("windows-31j")
// returns (nil, nil) — "registered but unsupported" per that method's own
// doc comment). All of these are the same Shift_JIS-family charset in
// practice, so they're mapped directly rather than round-tripped through
// ianaindex. Checked before ianaindex below.
var japaneseCharsetAliases = map[string]encoding.Encoding{
	"shift-jis":   japanese.ShiftJIS,
	"sjis":        japanese.ShiftJIS,
	"cp932":       japanese.ShiftJIS,
	"ms932":       japanese.ShiftJIS,
	"windows-31j": japanese.ShiftJIS,
}

// unsupportedCharsetError is mimeCharsetReader's error for a charset label
// it couldn't resolve to any encoding.Encoding — distinct from a nil error
// only in that it carries the charset name for anyone logging it; never
// itself logged today (decodeMIMEWords just falls back to the raw
// un-decoded string), kept as a real error type rather than fmt.Errorf so a
// future caller can errors.As it without string-matching.
type unsupportedCharsetError struct{ charset string }

func (e unsupportedCharsetError) Error() string {
	return fmt.Sprintf("imapclient: unsupported encoded-word charset %q", e.charset)
}

// mimeCharsetReader is mime.WordDecoder.CharsetReader for parsePreview's
// decoder: given an RFC 2047 encoded-word's charset label (already
// lower-cased by the stdlib caller — see mime/encodedword.go's
// WordDecoder.convert) and a reader over that encoded-word's raw decoded
// bytes, returns a reader that transcodes them to UTF-8. The stdlib's
// mime.WordDecoder never calls this for "utf-8"/"iso-8859-1"/"us-ascii" (it
// handles those three itself), so in practice this only ever sees other
// charsets — overwhelmingly ISO-2022-JP, Shift_JIS, or EUC-JP from Japanese
// mail. Returns an error (never a reader over untranscoded bytes) for a
// charset it can't resolve at all, so an unrecognized charset degrades
// exactly like it did before this reader existed: DecodeHeader fails and
// decodeMIMEWords falls back to the original un-decoded encoded-word text,
// rather than this function silently emitting bytes in the wrong charset
// as if they were already UTF-8.
func mimeCharsetReader(charset string, input io.Reader) (io.Reader, error) {
	enc := resolveCharset(charset)
	if enc == nil {
		return nil, unsupportedCharsetError{charset: charset}
	}
	return enc.NewDecoder().Reader(input), nil
}

// resolveCharset maps a MIME charset label (from an RFC 2047 encoded-word
// or a Content-Type charset parameter) to an encoding.Encoding, or nil if
// it can't: japaneseCharsetAliases first, then ianaindex.MIME. Shared by
// mimeCharsetReader (headers) and transcodeBody (body text) so both
// resolve exactly the same set of labels.
func resolveCharset(charset string) encoding.Encoding {
	name := strings.ToLower(strings.TrimSpace(charset))
	if enc, ok := japaneseCharsetAliases[name]; ok {
		return enc
	}
	enc, err := ianaindex.MIME.Encoding(name)
	if err != nil || enc == nil {
		return nil
	}
	return enc
}

// transcodeBody converts s (already CTE-decoded body text) from the given
// Content-Type charset label to UTF-8. A charset that is empty (RFC 2046
// §4.1.2's default is us-ascii), already UTF-8/ASCII, or unresolvable
// returns s unchanged — un-decoded beats mis-decoded, same posture as
// mimeCharsetReader. x/text decoders replace invalid input bytes with
// U+FFFD rather than failing, so a body BODY.PEEK[TEXT]<0.32768> cut off
// mid-sequence (mid-escape for ISO-2022-JP, mid-double-byte for
// Shift_JIS/EUC-JP) degrades to a mangled tail, never an empty preview.
func transcodeBody(s, charset string) string {
	name := strings.ToLower(strings.TrimSpace(charset))
	switch name {
	case "", "utf-8", "utf8", "us-ascii", "ascii":
		return s
	}
	enc := resolveCharset(name)
	if enc == nil {
		return s
	}
	decoded, err := enc.NewDecoder().String(s)
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
	decoded := transcodeBody(decodeBodyBytes(textBytes, topLevelCTE), params["charset"])
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
		decoded := transcodeBody(decodeBodyBytes(data, part.Header.Get("Content-Transfer-Encoding")), params["charset"])
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
// rune, then strips any remaining invalid UTF-8 (e.g. a body whose
// Content-Type charset transcodeBody couldn't resolve, or raw 8-bit bytes
// with no charset declared at all) so the result is always safe to embed
// in a JSON string.
func truncateUTF8(s string, maxBytes int) string {
	if len(s) > maxBytes {
		s = s[:maxBytes]
		for len(s) > 0 && !utf8.RuneStart(s[len(s)-1]) {
			s = s[:len(s)-1]
		}
	}
	return strings.ToValidUTF8(s, "")
}
