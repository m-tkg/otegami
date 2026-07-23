import Testing
@testable import OtegamiCore

@Suite("HTMLTextExtractor")
struct HTMLTextExtractorTests {
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
