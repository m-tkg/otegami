package imapclient

import (
	"encoding/base64"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"golang.org/x/text/encoding/japanese"

	"github.com/m-tkg/otegami-relay-go/internal/imaptest"
)

func headerFields(from, subject, date, messageID, contentType, cte string) string {
	var b strings.Builder
	if from != "" {
		b.WriteString("From: " + from + "\r\n")
	}
	if subject != "" {
		b.WriteString("Subject: " + subject + "\r\n")
	}
	if date != "" {
		b.WriteString("Date: " + date + "\r\n")
	}
	if messageID != "" {
		b.WriteString("Message-ID: " + messageID + "\r\n")
	}
	if contentType != "" {
		b.WriteString("Content-Type: " + contentType + "\r\n")
	}
	if cte != "" {
		b.WriteString("Content-Transfer-Encoding: " + cte + "\r\n")
	}
	b.WriteString("\r\n")
	return b.String()
}

func TestUIDFetchPreviewsBasicPlainText(t *testing.T) {
	server := imaptest.NewFakeServer()
	server.AddMessage(100, imaptest.FakeMessage{
		HeaderFields: headerFields(
			"Alice Example <alice@example.test>",
			"Hello there",
			"Mon, 1 Jan 2024 00:00:00 +0000",
			"<msg-100@example.test>",
			"text/plain; charset=utf-8",
			"7bit",
		),
		Text: "This is the body of the message.",
	})
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}

	previews, err := c.UIDFetchPreviews(100, 100, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 1 {
		t.Fatalf("got %d previews: %+v", len(previews), previews)
	}
	p := previews[0]
	if p.UID != 100 {
		t.Fatalf("got uid %d", p.UID)
	}
	if p.FromName != "Alice Example" || p.FromAddress != "alice@example.test" {
		t.Fatalf("got from %+v", p)
	}
	if p.Subject != "Hello there" {
		t.Fatalf("got subject %q", p.Subject)
	}
	if p.MessageID != "msg-100@example.test" {
		t.Fatalf("got messageId %q", p.MessageID)
	}
	if p.Date.IsZero() {
		t.Fatal("expected a parsed date")
	}
	if p.BodyPreview != "This is the body of the message." {
		t.Fatalf("got body %q", p.BodyPreview)
	}
}

func TestUIDFetchPreviewsMultipleUIDsInRange(t *testing.T) {
	server := imaptest.NewFakeServer()
	for _, uid := range []uint32{10, 11, 12} {
		server.AddMessage(uid, imaptest.FakeMessage{
			HeaderFields: headerFields("a@example.test", "subj", "", "", "", ""),
			Text:         "body",
		})
	}
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	previews, err := c.UIDFetchPreviews(10, 12, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 3 {
		t.Fatalf("got %d previews", len(previews))
	}
	seen := map[uint32]bool{}
	for _, p := range previews {
		seen[p.UID] = true
	}
	for _, uid := range []uint32{10, 11, 12} {
		if !seen[uid] {
			t.Fatalf("missing uid %d in %+v", uid, previews)
		}
	}
}

func TestUIDFetchPreviewsEmptyRangeReturnsEmptySlice(t *testing.T) {
	server := imaptest.NewFakeServer()
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	previews, err := c.UIDFetchPreviews(500, 510, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 0 {
		t.Fatalf("got %+v", previews)
	}
}

func TestUIDFetchPreviewsJapaneseEncodedWordSubject(t *testing.T) {
	server := imaptest.NewFakeServer()
	// "こんにちは" (konnichiwa) as a UTF-8 base64 RFC 2047 encoded-word —
	// the shape virtually every modern client (Gmail, Apple Mail, ...)
	// sends a non-ASCII subject in.
	server.AddMessage(1, imaptest.FakeMessage{
		HeaderFields: headerFields("a@example.test", "=?UTF-8?B?44GT44KT44Gr44Gh44Gv?=", "", "", "text/plain", ""),
		Text:         "body",
	})
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	previews, err := c.UIDFetchPreviews(1, 1, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 1 || previews[0].Subject != "こんにちは" {
		t.Fatalf("got %+v", previews)
	}
}

// TestUIDFetchPreviewsISO2022JPEncodedWordSubjectAndFrom covers the
// charset mimeCharsetReader (preview_parse.go) was added for: an
// RFC 2047 encoded-word whose charset is ISO-2022-JP rather than UTF-8 —
// the shape legacy/older Japanese mail clients (and some Japan-market
// webmail) still send. Before mimeCharsetReader existed, mime.WordDecoder
// had no CharsetReader registered, so DecodeHeader failed for any charset
// other than utf-8/iso-8859-1/us-ascii and decodeMIMEWords fell back to
// returning the raw, still-encoded "=?ISO-2022-JP?B?...?=" string.
//
// The base64 payload below is a real ISO-2022-JP byte sequence (produced
// with golang.org/x/text/encoding/japanese.ISO2022JP, the same family of
// encoder real mail clients use) for the Japanese text "日本語の件名です"
// ("This is a Japanese-language subject"), not a hand-crafted string, so
// this exercises the actual ISO-2022-JP escape-sequence decoding path
// (ESC $ B ... ESC ( B) rather than a degenerate all-ASCII case.
func TestUIDFetchPreviewsISO2022JPEncodedWordSubjectAndFrom(t *testing.T) {
	server := imaptest.NewFakeServer()
	const isoSubjectB64 = "GyRCRnxLXDhsJE43b0w+JEckORsoQg=="
	server.AddMessage(1, imaptest.FakeMessage{
		HeaderFields: headerFields(
			"=?ISO-2022-JP?B?"+isoSubjectB64+"?= <sender@example.test>",
			"=?ISO-2022-JP?B?"+isoSubjectB64+"?=",
			"", "", "text/plain", "",
		),
		Text: "body",
	})
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	previews, err := c.UIDFetchPreviews(1, 1, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 1 {
		t.Fatalf("got %d previews: %+v", len(previews), previews)
	}
	const want = "日本語の件名です"
	p := previews[0]
	if p.Subject != want {
		t.Fatalf("got subject %q, want %q", p.Subject, want)
	}
	if p.FromName != want {
		t.Fatalf("got fromName %q, want %q", p.FromName, want)
	}
	if p.FromAddress != "sender@example.test" {
		t.Fatalf("got fromAddress %q", p.FromAddress)
	}
}

func TestUIDFetchPreviewsQuotedPrintableBody(t *testing.T) {
	server := imaptest.NewFakeServer()
	server.AddMessage(1, imaptest.FakeMessage{
		HeaderFields: headerFields("a@example.test", "s", "", "", "text/plain; charset=utf-8", "quoted-printable"),
		Text:         "Caf=C3=A9 au lait",
	})
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	previews, err := c.UIDFetchPreviews(1, 1, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 1 || previews[0].BodyPreview != "Café au lait" {
		t.Fatalf("got %+v", previews)
	}
}

func TestUIDFetchPreviewsBase64Body(t *testing.T) {
	server := imaptest.NewFakeServer()
	// base64("Hello, base64 body!") = SGVsbG8sIGJhc2U2NCBib2R5IQ==
	server.AddMessage(1, imaptest.FakeMessage{
		HeaderFields: headerFields("a@example.test", "s", "", "", "text/plain", "base64"),
		Text:         "SGVsbG8sIGJhc2U2NCBib2R5IQ==",
	})
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	previews, err := c.UIDFetchPreviews(1, 1, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 1 || previews[0].BodyPreview != "Hello, base64 body!" {
		t.Fatalf("got %+v", previews)
	}
}

func TestUIDFetchPreviewsMultipartAlternativePrefersPlain(t *testing.T) {
	server := imaptest.NewFakeServer()
	body := "" +
		"--BOUNDARY\r\n" +
		"Content-Type: text/html\r\n\r\n" +
		"<p>html <b>version</b></p>\r\n" +
		"--BOUNDARY\r\n" +
		"Content-Type: text/plain\r\n\r\n" +
		"plain version\r\n" +
		"--BOUNDARY--\r\n"
	server.AddMessage(1, imaptest.FakeMessage{
		HeaderFields: headerFields("a@example.test", "s", "", "", `multipart/alternative; boundary="BOUNDARY"`, ""),
		Text:         body,
	})
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	previews, err := c.UIDFetchPreviews(1, 1, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 1 || previews[0].BodyPreview != "plain version" {
		t.Fatalf("got %+v", previews)
	}
}

func TestUIDFetchPreviewsHTMLOnlyFallsBackToStrippedText(t *testing.T) {
	server := imaptest.NewFakeServer()
	server.AddMessage(1, imaptest.FakeMessage{
		HeaderFields: headerFields("a@example.test", "s", "", "", "text/html; charset=utf-8", ""),
		Text:         "<html><body><p>Hello <b>world</b></p><script>evil()</script></body></html>",
	})
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	previews, err := c.UIDFetchPreviews(1, 1, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 1 || previews[0].BodyPreview != "Hello world" {
		t.Fatalf("got %+v", previews)
	}
}

// encodeISO2022JP / encodeShiftJIS produce real Japanese-charset byte
// sequences for body-charset fixtures with the same x/text encoders the
// production decode path reverses — no hand-crafted byte strings.
func encodeISO2022JP(t *testing.T, s string) string {
	t.Helper()
	out, err := japanese.ISO2022JP.NewEncoder().String(s)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func encodeShiftJIS(t *testing.T, s string) string {
	t.Helper()
	out, err := japanese.ShiftJIS.NewEncoder().String(s)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// TestUIDFetchPreviewsISO2022JPQuotedPrintableBody reproduces the confirmed
// production bug behind the 2026-08-06 Sony Bank notification: a text/plain
// body with charset=ISO-2022-JP and Content-Transfer-Encoding:
// quoted-printable. decodeBodyBytes reversed the QP layer but nothing
// transcoded the charset, so the push notification showed the raw
// escape-sequence text ("$B%=%K!<..." — the ESC bytes themselves get eaten
// by iOS's notification rendering, everything else is printable ASCII and
// sailed straight through truncateUTF8's ToValidUTF8).
func TestUIDFetchPreviewsISO2022JPQuotedPrintableBody(t *testing.T) {
	server := imaptest.NewFakeServer()
	const want = "ソニー銀行からのお知らせ"
	// QP-encode the ISO-2022-JP bytes: ESC (0x1B) is the only byte outside
	// the printable-ASCII range QP passes through literally.
	qpBody := strings.ReplaceAll(encodeISO2022JP(t, want), "\x1b", "=1B")
	server.AddMessage(1, imaptest.FakeMessage{
		HeaderFields: headerFields("a@example.test", "s", "", "", "text/plain; charset=ISO-2022-JP", "quoted-printable"),
		Text:         qpBody,
	})
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	previews, err := c.UIDFetchPreviews(1, 1, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 1 || previews[0].BodyPreview != want {
		t.Fatalf("got %+v, want body %q", previews, want)
	}
}

func TestUIDFetchPreviewsShiftJISBase64Body(t *testing.T) {
	server := imaptest.NewFakeServer()
	const want = "こんにちは、世界"
	b64Body := base64.StdEncoding.EncodeToString([]byte(encodeShiftJIS(t, want)))
	server.AddMessage(1, imaptest.FakeMessage{
		HeaderFields: headerFields("a@example.test", "s", "", "", "text/plain; charset=Shift_JIS", "base64"),
		Text:         b64Body,
	})
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	previews, err := c.UIDFetchPreviews(1, 1, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 1 || previews[0].BodyPreview != want {
		t.Fatalf("got %+v, want body %q", previews, want)
	}
}

func TestUIDFetchPreviewsMultipartISO2022JPPlainPart(t *testing.T) {
	server := imaptest.NewFakeServer()
	const want = "円リッチプログラム上乗せ金利のご案内"
	body := "" +
		"--BOUNDARY\r\n" +
		"Content-Type: text/html; charset=utf-8\r\n\r\n" +
		"<p>html version</p>\r\n" +
		"--BOUNDARY\r\n" +
		"Content-Type: text/plain; charset=ISO-2022-JP\r\n\r\n" +
		encodeISO2022JP(t, want) + "\r\n" +
		"--BOUNDARY--\r\n"
	server.AddMessage(1, imaptest.FakeMessage{
		HeaderFields: headerFields("a@example.test", "s", "", "", `multipart/alternative; boundary="BOUNDARY"`, ""),
		Text:         body,
	})
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	previews, err := c.UIDFetchPreviews(1, 1, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 1 || previews[0].BodyPreview != want {
		t.Fatalf("got %+v, want body %q", previews, want)
	}
}

// TestUIDFetchPreviewsUnknownBodyCharsetLeftAlone pins the degrade path:
// a charset resolveCharset can't map returns the CTE-decoded bytes
// unchanged (for an all-ASCII body that means an intact preview), exactly
// the pre-transcodeBody behavior — un-decoded beats mis-decoded.
func TestUIDFetchPreviewsUnknownBodyCharsetLeftAlone(t *testing.T) {
	server := imaptest.NewFakeServer()
	server.AddMessage(1, imaptest.FakeMessage{
		HeaderFields: headerFields("a@example.test", "s", "", "", "text/plain; charset=x-mystery-charset", "7bit"),
		Text:         "plain ascii body",
	})
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	previews, err := c.UIDFetchPreviews(1, 1, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 1 || previews[0].BodyPreview != "plain ascii body" {
		t.Fatalf("got %+v", previews)
	}
}

// TestUIDFetchPreviewsTruncatedISO2022JPBody covers the
// BODY.PEEK[TEXT]<0.32768> truncation case: the ISO-2022-JP byte stream
// cut off mid-double-byte-sequence must still yield the intact prefix
// (x/text decoders emit U+FFFD for the dangling tail rather than failing),
// never an error or an empty preview.
func TestUIDFetchPreviewsTruncatedISO2022JPBody(t *testing.T) {
	server := imaptest.NewFakeServer()
	const full = "ソニー銀行からのお知らせ"
	encoded := encodeISO2022JP(t, full)
	// Cut inside the double-byte JIS region: past the leading ESC $ B (3
	// bytes) plus an odd number of content bytes, so the last character is
	// split and there is no trailing ESC ( B either.
	truncated := encoded[:3+5]
	server.AddMessage(1, imaptest.FakeMessage{
		HeaderFields: headerFields("a@example.test", "s", "", "", "text/plain; charset=ISO-2022-JP", "7bit"),
		Text:         truncated,
	})
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	previews, err := c.UIDFetchPreviews(1, 1, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 1 {
		t.Fatalf("got %+v", previews)
	}
	got := previews[0].BodyPreview
	if !utf8.ValidString(got) {
		t.Fatalf("body is not valid UTF-8: %q", got)
	}
	if !strings.HasPrefix(got, "ソニ") {
		t.Fatalf("got body %q, want intact %q prefix", got, "ソニ")
	}
}

// TestUIDFetchPreviewsReversedItemOrderStillParses reproduces the confirmed
// production bug: imap.gmail.com answers this client's `UID BODY.PEEK[HEADER.
// FIELDS (...)] BODY.PEEK[TEXT]<0.32768>` request with BODY[TEXT] before
// BODY[HEADER.FIELDS] — the reverse of request order. Before pairFetchLiterals
// (client.go) existed, UIDFetchPreviews assumed literals[0]=header/
// literals[1]=text unconditionally, so against this exact response shape
// every envelope field came out empty and BodyPreview held raw header text.
func TestUIDFetchPreviewsReversedItemOrderStillParses(t *testing.T) {
	server := imaptest.NewFakeServer()
	server.ReverseFetchItemOrder = true
	server.AddMessage(1, imaptest.FakeMessage{
		HeaderFields: headerFields(
			"Alice Example <alice@example.test>",
			"Hello from Gmail",
			"Mon, 1 Jan 2024 00:00:00 +0000",
			"<msg-1@example.test>",
			"text/plain; charset=utf-8",
			"7bit",
		),
		Text: "This is the body of the message.",
	})
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}

	previews, err := c.UIDFetchPreviews(1, 1, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 1 {
		t.Fatalf("got %d previews: %+v", len(previews), previews)
	}
	p := previews[0]
	if p.FromName != "Alice Example" || p.FromAddress != "alice@example.test" {
		t.Fatalf("got from %+v (header/body pairing likely swapped)", p)
	}
	if p.Subject != "Hello from Gmail" {
		t.Fatalf("got subject %q (header/body pairing likely swapped)", p.Subject)
	}
	if p.MessageID != "msg-1@example.test" {
		t.Fatalf("got messageId %q", p.MessageID)
	}
	if p.Date.IsZero() {
		t.Fatal("expected a parsed date")
	}
	if p.BodyPreview != "This is the body of the message." {
		t.Fatalf("got body %q (header/body pairing likely swapped)", p.BodyPreview)
	}
}

// TestPairFetchLiterals directly exercises pairFetchLiterals (client.go)
// against the response-text shapes it needs to disambiguate, independent of
// the fake server plumbing — covers the two orders a real server could send
// data items in, plus the "can't tell" fallback cases the doc comment
// promises fall back to request order.
func TestPairFetchLiterals(t *testing.T) {
	headerLit := []byte("header-bytes")
	bodyLit := []byte("body-bytes")

	cases := []struct {
		name       string
		text       string
		wantHeader []byte
		wantBody   []byte
	}{
		{
			name:       "request order: header item first",
			text:       "* 1 FETCH (UID 1 BODY[HEADER.FIELDS (FROM SUBJECT)] BODY[TEXT]<0.32768> )",
			wantHeader: headerLit,
			wantBody:   bodyLit,
		},
		{
			name:       "Gmail order: text item first",
			text:       "* 1 FETCH (UID 1 BODY[TEXT]<0.32768> BODY[HEADER.FIELDS (FROM SUBJECT)] )",
			wantHeader: bodyLit,
			wantBody:   headerLit,
		},
		{
			name:       "lower-case item names still detected",
			text:       "* 1 FETCH (UID 1 body[text]<0.32768> body[header.fields (from subject)] )",
			wantHeader: bodyLit,
			wantBody:   headerLit,
		},
		{
			name:       "neither item name found: falls back to request order",
			text:       "* 1 FETCH (UID 1 SOMETHING UNEXPECTED )",
			wantHeader: headerLit,
			wantBody:   bodyLit,
		},
		{
			name:       "only header item name found: falls back to request order",
			text:       "* 1 FETCH (UID 1 BODY[HEADER.FIELDS (FROM SUBJECT)] )",
			wantHeader: headerLit,
			wantBody:   bodyLit,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gotHeader, gotBody := pairFetchLiterals(tc.text, [][]byte{headerLit, bodyLit})
			if string(gotHeader) != string(tc.wantHeader) || string(gotBody) != string(tc.wantBody) {
				t.Fatalf("pairFetchLiterals(%q) = (%q, %q), want (%q, %q)",
					tc.text, gotHeader, gotBody, tc.wantHeader, tc.wantBody)
			}
		})
	}
}

func TestUIDFetchPreviewsUnknownAuthOrMissingResponse(t *testing.T) {
	// A UID range with no matching messages must not error — this is the
	// "new mail arrived and was already expunged again" / "nothing to
	// preview" case the watcher pool's fallback logic relies on being a
	// clean empty result, not an error.
	server := imaptest.NewFakeServer()
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	previews, err := c.UIDFetchPreviews(1, 1, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 0 {
		t.Fatalf("got %+v", previews)
	}
}
