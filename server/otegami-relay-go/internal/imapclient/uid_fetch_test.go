package imapclient

import (
	"strings"
	"testing"
	"time"

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
