import Foundation
import Testing
@testable import OtegamiCore

@Suite("HTMLTextExtractor")
struct HTMLTextExtractorTests {
    /// Regression bound for Task #168 (SEC-C, `CLAUDE-SECURITY` F11/F6):
    /// `plainText(fromHTML:)` used to be a chain of backtracking regexes
    /// plus an unbounded-rescan entity decoder, both worst-case quadratic
    /// in input length. Confirmed against the pre-fix code (via a
    /// standalone repro outside the shared work tree, not by mutating
    /// this file's history) that these payloads did not complete within
    /// 25s; post-fix they complete in well under 1s. The bound below is
    /// generous on purpose — this asserts "doesn't hang for a very long
    /// time", not a tight performance budget.
    private static let maliciousInputTimeBound: TimeInterval = 10

    @Test("a ~1MB unclosed <script> flood does not hang HTML→text extraction")
    func scriptFloodDoesNotHang() {
        let payload = String(repeating: "<script", count: 150_000) // ~1.05MB, never closed, no '>' at all.
        let start = Date()
        _ = HTMLTextExtractor.plainText(fromHTML: payload)
        #expect(Date().timeIntervalSince(start) < Self.maliciousInputTimeBound)
    }

    @Test("a flood of '&' with a single trailing ';' does not hang entity decoding")
    func entityFloodDoesNotHang() {
        let payload = String(repeating: "&", count: 300_000) + ";"
        let start = Date()
        _ = HTMLTextExtractor.plainText(fromHTML: payload)
        #expect(Date().timeIntervalSince(start) < Self.maliciousInputTimeBound)
    }

    @Test("input far beyond the internal length cap is still bounded and doesn't crash")
    func oversizedInputIsCappedAndSafe() {
        let payload = String(repeating: "<script", count: 2_000_000) // ~14MB, well past the internal cap.
        let start = Date()
        _ = HTMLTextExtractor.plainText(fromHTML: payload)
        #expect(Date().timeIntervalSince(start) < Self.maliciousInputTimeBound)
    }
    @Test("strips tags and preserves text")
    func stripsTags() {
        let html = "<p>Hello <b>World</b></p>"
        #expect(HTMLTextExtractor.plainText(fromHTML: html) == "Hello World")
    }

    @Test("turns block boundaries into newlines")
    func blockBoundaries() {
        let html = "<p>First</p><p>Second</p>"
        #expect(HTMLTextExtractor.plainText(fromHTML: html) == "First\nSecond")
    }

    @Test("br becomes a newline")
    func brBecomesNewline() {
        let html = "Line one<br>Line two<br/>Line three"
        #expect(HTMLTextExtractor.plainText(fromHTML: html) == "Line one\nLine two\nLine three")
    }

    @Test("drops script and style content entirely")
    func dropsScriptAndStyle() {
        let html = "<style>body{color:red}</style><p>Visible</p><script>alert(1)</script>"
        #expect(HTMLTextExtractor.plainText(fromHTML: html) == "Visible")
    }

    @Test("decodes named and numeric entities")
    func decodesEntities() {
        let html = "<p>&lt;otegami&gt; &amp; friends &mdash; &#12371;&#x3093;&#12395;&#12385;&#12399;</p>"
        #expect(HTMLTextExtractor.plainText(fromHTML: html) == "<otegami> & friends \u{2014} こんにちは")
    }

    @Test("Japanese HTML-only body renders as readable text")
    func japaneseBody() {
        let html = "<html><body><p>こんにちは、otegami です。</p><p>これはHTML専用の日本語メールです。</p></body></html>"
        #expect(HTMLTextExtractor.plainText(fromHTML: html) == "こんにちは、otegami です。\nこれはHTML専用の日本語メールです。")
    }

    /// 2026-07-30 (Phase 5続報、実機 eml 再現): 通知系メール (Okta の
    /// サインオン通知が実例) にありがちな、`<p>`を1つも使わず
    /// `<table>`/`<tbody>`/`<tr>`/`<td>`だけで組んだレイアウトの HTML —
    /// 本文テキストは全て`<td>`直下、行区切りは`<br />`。
    /// `HTMLTranslationController`のDOM抽出 (WKWebView 側 JS) がこの構造で
    /// 空を返すケースが実機で確認され、`MessageView.requestTranslation`は
    /// その場合 plain 本文が無ければこの`HTMLTextExtractor.plainText`
    /// (HTMLからの) フォールバックへ流れる — フォールバック先そのものが
    /// table レイアウトから読める本文を作れることを確認しておく。
    /// (この eml の実内容は実名/実メールアドレスを含むため、フィクスチャは
    /// 架空の宛名/ドメインで同じ構造だけ再現している。)
    @Test("table-layout HTML with no <p> tags still extracts readable text, from cells and <br>-separated lines")
    func tableLayoutNotificationEmailExtractsText() {
        let html = """
        <html><body>
        <table><tbody>
          <tr><td>Example Corp - New sign-on detected for your account</td></tr>
          <tr><td>Hi Alex,</td></tr>
          <tr><td>Your Example Corp account alex@example.com was just used to sign in from a new device.</td></tr>
          <tr><td>Sign-In Details</td></tr>
          <tr><td>SAFARI - Mac OS X (iPhone) <br /> Monday, January 1, 2026 <br /> Example City, Example Country <br /> IP: 203.0.113.5</td></tr>
        </tbody></table>
        </body></html>
        """
        let extracted = HTMLTextExtractor.plainText(fromHTML: html)
        #expect(!extracted.isEmpty)
        #expect(extracted.contains("Hi Alex,"))
        #expect(extracted.contains("was just used to sign in from a new device."))
        // The `<br />`-separated lines inside one `<td>` each survive as
        // their own line, not collapsed into one run-on sentence.
        #expect(extracted.contains("SAFARI - Mac OS X (iPhone)"))
        #expect(extracted.contains("Monday, January 1, 2026"))
        #expect(extracted.contains("IP: 203.0.113.5"))
    }
}

@Suite("SnippetBuilder")
struct SnippetBuilderTests {
    @Test("nil input yields nil")
    func nilInput() {
        #expect(SnippetBuilder.make(from: nil) == nil)
    }

    @Test("whitespace-only input yields nil")
    func whitespaceOnlyInput() {
        #expect(SnippetBuilder.make(from: "   \n\t  ") == nil)
    }

    @Test("collapses internal whitespace and newlines to single spaces")
    func collapsesWhitespace() {
        #expect(SnippetBuilder.make(from: "Hello\n\n  World   \t again") == "Hello World again")
    }

    @Test("short text is unchanged")
    func shortTextUnchanged() {
        #expect(SnippetBuilder.make(from: "test1 さん\n\notegami の開発用メールスタックへようこそ。") == "test1 さん otegami の開発用メールスタックへようこそ。")
    }

    @Test("truncates to maxLength characters")
    func truncatesToMaxLength() {
        let long = String(repeating: "あ", count: 200)
        let snippet = SnippetBuilder.make(from: long, maxLength: 120)
        #expect(snippet?.count == 120)
    }
}

@Suite("HTMLExternalResourceScanner")
struct HTMLExternalResourceScannerTests {
    @Test("detects an external image src")
    func detectsExternalImage() {
        let html = "<html><body><img src=\"http://example.com/x.png\"></body></html>"
        #expect(HTMLExternalResourceScanner.containsExternalResource(html: html))
    }

    @Test("detects an https background-image url()")
    func detectsCSSBackgroundImage() {
        let html = "<div style=\"background-image:url('https://example.com/bg.jpg')\"></div>"
        #expect(HTMLExternalResourceScanner.containsExternalResource(html: html))
    }

    @Test("does not flag inline cid: images")
    func doesNotFlagInlineCID() {
        let html = "<html><body><img src=\"cid:logo@otegami.test\"></body></html>"
        #expect(!HTMLExternalResourceScanner.containsExternalResource(html: html))
    }

    @Test("does not flag plain text with no markup")
    func doesNotFlagPlainText() {
        #expect(!HTMLExternalResourceScanner.containsExternalResource(html: "Just some plain text, no HTML here."))
    }
}

/// Task #207: `containsPlaintextHTTPImage` — the narrower, image-only,
/// http-only detector that gates the「保護されていない画像」confirmation
/// (`HTMLMessageView`), distinct from the broader `containsExternalResource`
/// above.
@Suite("HTMLExternalResourceScanner.containsPlaintextHTTPImage")
struct HTMLExternalResourceScannerPlaintextHTTPImageTests {
    @Test("detects a plaintext http image src")
    func detectsHTTPImage() {
        let html = "<html><body><img src=\"http://example.com/x.png\"></body></html>"
        #expect(HTMLExternalResourceScanner.containsPlaintextHTTPImage(html: html))
    }

    @Test("does not flag an https image src")
    func doesNotFlagHTTPSImage() {
        let html = "<html><body><img src=\"https://example.com/x.png\"></body></html>"
        #expect(!HTMLExternalResourceScanner.containsPlaintextHTTPImage(html: html))
    }

    @Test("does not flag a plaintext http link (no image)")
    func doesNotFlagHTTPLink() {
        let html = "<html><body><a href=\"http://example.com\">click</a></body></html>"
        #expect(!HTMLExternalResourceScanner.containsPlaintextHTTPImage(html: html))
    }

    @Test("detects a plaintext http CSS background-image url()")
    func detectsHTTPBackgroundImage() {
        let html = "<div style=\"background-image:url('http://example.com/bg.jpg')\"></div>"
        #expect(HTMLExternalResourceScanner.containsPlaintextHTTPImage(html: html))
    }

    @Test("detects a plaintext http background attribute")
    func detectsHTTPBackgroundAttribute() {
        let html = "<td background=\"http://example.com/bg.gif\"></td>"
        #expect(HTMLExternalResourceScanner.containsPlaintextHTTPImage(html: html))
    }

    @Test("does not flag inline cid: images")
    func doesNotFlagInlineCID() {
        let html = "<html><body><img src=\"cid:logo@otegami.test\"></body></html>"
        #expect(!HTMLExternalResourceScanner.containsPlaintextHTTPImage(html: html))
    }

    @Test("does not flag plain text with no markup")
    func doesNotFlagPlainText() {
        #expect(!HTMLExternalResourceScanner.containsPlaintextHTTPImage(html: "Just some plain text, no HTML here."))
    }
}
