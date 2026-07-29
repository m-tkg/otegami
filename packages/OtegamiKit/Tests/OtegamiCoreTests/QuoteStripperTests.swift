import Foundation
import Testing
@testable import OtegamiCore

@Suite("QuoteStripper plain text")
struct QuoteStripperPlainTextTests {
    private let newText = "This is my new reply with enough new content to exceed the forty character threshold."

    @Test("strips a leading '>' quote block")
    func stripsQuoteBlock() {
        let text = "\(newText)\n\n> Original line one\n> Original line two\n> Original line three"
        #expect(trimmed(QuoteStripper.strippingQuotedText(fromPlainText: text)) == newText)
    }

    @Test("strips an 'On ... wrote:' header and everything after it")
    func stripsOnWroteHeader() {
        let text = """
        \(newText)

        On Mon, Jul 27, 2026 at 10:00 AM John Doe <john@example.com> wrote:
        > Original line one
        > Original line two
        """
        #expect(trimmed(QuoteStripper.strippingQuotedText(fromPlainText: text)) == newText)
    }

    @Test("strips a Japanese 'さんは書きました' header and everything after it")
    func stripsJapaneseWroteHeader() {
        let japaneseNewText = "こちらが今回追加した本文です。前回のやり取りとは別の新しい内容をここに書いています。"
        let text = """
        \(japaneseNewText)

        2026年7月27日(月) 10:00 山田太郎<yamada@example.com>さんは書きました:
        > 過去のメッセージ本文
        > 続きの引用行
        """
        #expect(trimmed(QuoteStripper.strippingQuotedText(fromPlainText: text)) == japaneseNewText)
    }

    @Test("strips a '----- Original Message -----' separator and everything after it")
    func stripsOriginalMessageSeparator() {
        let text = """
        \(newText)

        ----- Original Message -----
        From: John Doe <john@example.com>
        Subject: Hello
        """
        #expect(trimmed(QuoteStripper.strippingQuotedText(fromPlainText: text)) == newText)
    }

    @Test("strips an Outlook-style Japanese 差出人 header block and everything after it")
    func stripsJapaneseOutlookHeaderBlock() {
        let japaneseNewText = "ご確認いただきありがとうございます。こちらで対応を進めますので、少々お待ちください。"
        let text = """
        \(japaneseNewText)

        差出人: 山田太郎 <yamada@example.com>
        送信日時: 2026年7月27日 10:00
        宛先: 田中花子 <tanaka@example.com>
        件名: Re: 打ち合わせについて

        過去のメッセージ本文
        """
        #expect(trimmed(QuoteStripper.strippingQuotedText(fromPlainText: text)) == japaneseNewText)
    }

    @Test("strips an Outlook-style English From/Sent/To/Subject header block")
    func stripsEnglishOutlookHeaderBlock() {
        let text = """
        \(newText)

        From: John Doe <john@example.com>
        Sent: Monday, July 27, 2026 10:00 AM
        To: Jane Doe <jane@example.com>
        Subject: Re: Project update

        Original message body here.
        """
        #expect(trimmed(QuoteStripper.strippingQuotedText(fromPlainText: text)) == newText)
    }

    @Test("falls back to the full text when the message is forward-only (nothing but quoted content)")
    func fallsBackWhenOnlyQuotedContent() {
        let text = "> Original line one\n> Original line two\n> Original line three"
        #expect(QuoteStripper.strippingQuotedText(fromPlainText: text) == text)
    }

    @Test("falls back to the full text when there is no quote marker at all")
    func fallsBackWhenNoMarker() {
        #expect(QuoteStripper.strippingQuotedText(fromPlainText: newText) == newText)
    }

    @Test("strips an Apple Mail Japanese 'のメール' header and everything after it")
    func stripsAppleMailJapaneseHeader() {
        let japaneseNewText = "こちらが今回追加した本文です。前回のやり取りとは別の新しい内容をここに書いています。"
        let text = """
        \(japaneseNewText)

        2026/07/28 10:00、山田太郎のメール:
        > 過去のメッセージ本文
        > 続きの引用行
        """
        #expect(trimmed(QuoteStripper.strippingQuotedText(fromPlainText: text)) == japaneseNewText)
    }

    @Test("separatingQuotedText returns both the new text and the quoted history")
    func separatesNewAndQuotedText() {
        let text = "\(newText)\n\n> Original line one\n> Original line two\n> Original line three"
        let separated = QuoteStripper.separatingQuotedText(fromPlainText: text)
        #expect(trimmed(separated.newText) == newText)
        #expect(separated.quotedText == "> Original line one\n> Original line two\n> Original line three")
    }

    @Test("separatingQuotedText returns an empty quotedText when there is no marker")
    func separatingReturnsEmptyQuoteWhenNoMarker() {
        let separated = QuoteStripper.separatingQuotedText(fromPlainText: newText)
        #expect(separated.newText == newText)
        #expect(separated.quotedText.isEmpty)
    }

    @Test("separatingQuotedText falls back to the full text with an empty quotedText when forward-only")
    func separatingFallsBackWhenOnlyQuotedContent() {
        let text = "> Original line one\n> Original line two\n> Original line three"
        let separated = QuoteStripper.separatingQuotedText(fromPlainText: text)
        #expect(separated.newText == text)
        #expect(separated.quotedText.isEmpty)
    }

    @Test("separatingQuotedText reports the matched marker name")
    func separatingReportsDetectedMarkerName() {
        let text = "\(newText)\n\n> Original line one\n> Original line two\n> Original line three"
        let separated = QuoteStripper.separatingQuotedText(fromPlainText: text)
        #expect(separated.detectedMarker == "quoteBlockLine")
    }

    @Test("separatingQuotedText reports a nil marker when there is nothing to split")
    func separatingReportsNilMarkerWhenNoSplit() {
        let separated = QuoteStripper.separatingQuotedText(fromPlainText: newText)
        #expect(separated.detectedMarker == nil)
    }

    // MARK: - Task #90: reply-only header patterns (isReply: true)

    @Test("does NOT strip a bare 'From: Name <addr>' line when isReply is false (default) — too risky on ordinary prose")
    func doesNotStripBareFromLineWhenNotReply() {
        let text = """
        \(newText)

        From: Tokyo Station <info@example.com>
        the itinerary continues here with more plain prose that is not a quote at all.
        """
        #expect(trimmed(QuoteStripper.strippingQuotedText(fromPlainText: text)) == trimmed(text))
    }

    @Test("strips a bare 'From: Name <addr>' line (no Sent/To/Subject block) when isReply is true")
    func stripsBareFromLineWhenReply() {
        let text = """
        \(newText)

        From: John Doe <john@example.com>
        Original message body here, with no Sent/To/Subject block at all.
        """
        let separated = QuoteStripper.separatingQuotedText(fromPlainText: text, isReply: true)
        #expect(trimmed(separated.newText) == newText)
        #expect(separated.detectedMarker == "englishFromLineOnly")
    }

    @Test("strips an 'On ... <addr>' header missing its 'wrote:' verb when isReply is true")
    func stripsOnHeaderMissingWroteVerbWhenReply() {
        let text = """
        \(newText)

        On Mon, Jul 27, 2026 at 10:00 AM John Doe <john@example.com>
        > Original line one
        > Original line two
        """
        let separated = QuoteStripper.separatingQuotedText(fromPlainText: text, isReply: true)
        #expect(trimmed(separated.newText) == newText)
        #expect(separated.detectedMarker == "onWroteAddressOnly")
    }

    @Test("does NOT strip an 'On ... <addr>' header missing 'wrote:' when isReply is false")
    func doesNotStripOnHeaderMissingWroteVerbWhenNotReply() {
        let text = """
        \(newText)

        On Mon, Jul 27, 2026 at 10:00 AM John Doe <john@example.com>
        this is just a plain sentence, not a quote header, mentioning someone by address.
        """
        #expect(trimmed(QuoteStripper.strippingQuotedText(fromPlainText: text)) == trimmed(text))
    }

    @Test("strips a Japanese '送信者:' header line when isReply is true")
    func stripsJapaneseSenderLineWhenReply() {
        let japaneseNewText = "こちらが今回追加した本文です。前回のやり取りとは別の新しい内容をここに書いています。"
        let text = """
        \(japaneseNewText)

        送信者: 山田太郎 <yamada@example.com>
        過去のメッセージ本文
        """
        let separated = QuoteStripper.separatingQuotedText(fromPlainText: text, isReply: true)
        #expect(trimmed(separated.newText) == japaneseNewText)
        #expect(separated.detectedMarker == "japaneseSenderLineOnly")
    }
}

@Suite("QuoteStripper HTML")
struct QuoteStripperHTMLTests {
    private let newText = "This is my new reply with enough new content to exceed the forty character threshold."

    @Test("strips an Apple Mail / generic <blockquote> and its contents")
    func stripsBlockquote() {
        let html = """
        <div>\(newText)</div>
        <blockquote type="cite">
        <div>Original message body that should be dropped entirely.</div>
        </blockquote>
        """
        #expect(QuoteStripper.strippingQuotedText(fromHTML: html) == newText)
    }

    @Test("strips a Gmail gmail_quote wrapper (attribution line + blockquote)")
    func stripsGmailQuoteWrapper() {
        let html = """
        <div dir="ltr">\(newText)</div>
        <br>
        <div class="gmail_quote gmail_quote_container">
        <div class="gmail_attr">On Mon, Jul 27, 2026 at 10:00 AM John Doe &lt;john@example.com&gt; wrote:<br></div>
        <blockquote class="gmail_quote" style="margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex">
        <div>Original message body that should be dropped entirely.</div>
        </blockquote>
        </div>
        """
        #expect(QuoteStripper.strippingQuotedText(fromHTML: html) == newText)
    }

    @Test("strips a Thunderbird moz-cite-prefix + blockquote pair")
    func stripsThunderbirdPrefix() {
        let html = """
        <p>\(newText)</p>
        <div class="moz-cite-prefix">On 2026/07/27 10:00, John Doe wrote:<br></div>
        <blockquote type="cite" cite="mid:abc123@example.com">
        <div>Original message body that should be dropped entirely.</div>
        </blockquote>
        """
        #expect(QuoteStripper.strippingQuotedText(fromHTML: html) == newText)
    }

    @Test("strips an Outlook divRplyFwdMsg container")
    func stripsOutlookReplyContainer() {
        let html = """
        <div>\(newText)</div>
        <div id="divRplyFwdMsg">
        <hr>
        <p><b>From:</b> John Doe &lt;john@example.com&gt;<br>
        <b>Sent:</b> Monday, July 27, 2026 10:00 AM<br>
        <b>Subject:</b> Re: Project update</p>
        <div>Original message body that should be dropped entirely.</div>
        </div>
        """
        #expect(QuoteStripper.strippingQuotedText(fromHTML: html) == newText)
    }

    @Test("strips an <hr> followed by a From: header block with no recognized container id")
    func stripsHRFollowedByFromHeader() {
        let html = """
        <div>\(newText)</div>
        <hr>
        <p>From: John Doe &lt;john@example.com&gt;<br>
        Sent: Monday, July 27, 2026 10:00 AM<br>
        Subject: Re: Project update</p>
        <div>Original message body that should be dropped entirely.</div>
        """
        #expect(QuoteStripper.strippingQuotedText(fromHTML: html) == newText)
    }

    @Test("falls back to the full text when the message is forward-only (nothing but a blockquote)")
    func fallsBackWhenOnlyBlockquote() {
        let html = "<blockquote type=\"cite\"><div>Original message body only, nothing new here.</div></blockquote>"
        let expected = HTMLTextExtractor.plainText(fromHTML: html)
        #expect(QuoteStripper.strippingQuotedText(fromHTML: html) == expected)
    }

    @Test("falls back to the full text when there is no quote marker at all")
    func fallsBackWhenNoMarker() {
        let html = "<div>\(newText)</div>"
        #expect(QuoteStripper.strippingQuotedText(fromHTML: html) == newText)
    }

    @Test("strips a Yahoo Mail yahoo_quoted wrapper")
    func stripsYahooQuotedWrapper() {
        let html = """
        <div>\(newText)</div>
        <div class="yahoo_quoted">
        <div>Original message body that should be dropped entirely.</div>
        </div>
        """
        #expect(QuoteStripper.strippingQuotedText(fromHTML: html) == newText)
    }

    @Test("strips a ProtonMail protonmail_quote wrapper")
    func stripsProtonMailQuotedWrapper() {
        let html = """
        <div>\(newText)</div>
        <div class="protonmail_quote">
        <div>Original message body that should be dropped entirely.</div>
        </div>
        """
        #expect(QuoteStripper.strippingQuotedText(fromHTML: html) == newText)
    }

    @Test("separatingQuotedText returns both the new text and the quoted history")
    func separatesNewAndQuotedText() {
        let html = """
        <div>\(newText)</div>
        <blockquote type="cite">
        <div>Original message body that should be dropped entirely.</div>
        </blockquote>
        """
        let separated = QuoteStripper.separatingQuotedText(fromHTML: html)
        #expect(separated.newText == newText)
        #expect(separated.quotedText == "Original message body that should be dropped entirely.")
    }

    @Test("separatingQuotedText returns an empty quotedText when there is no marker")
    func separatingReturnsEmptyQuoteWhenNoMarker() {
        let html = "<div>\(newText)</div>"
        let separated = QuoteStripper.separatingQuotedText(fromHTML: html)
        #expect(separated.newText == newText)
        #expect(separated.quotedText.isEmpty)
    }

    @Test("separatingQuotedText falls back to the full text with an empty quotedText when forward-only")
    func separatingFallsBackWhenOnlyBlockquote() {
        let html = "<blockquote type=\"cite\"><div>Original message body only, nothing new here.</div></blockquote>"
        let expected = HTMLTextExtractor.plainText(fromHTML: html)
        let separated = QuoteStripper.separatingQuotedText(fromHTML: html)
        #expect(separated.newText == expected)
        #expect(separated.quotedText.isEmpty)
    }

    @Test("strips a class-less border-left-styled quote div (Task #90 gap fix)")
    func stripsBorderLeftStyledQuoteDiv() {
        let html = """
        <div>\(newText)</div>
        <div style="margin-left:8px; border-left: 2px solid #ccc; padding-left: 8px;">
        <div>Original message body that should be dropped entirely.</div>
        </div>
        """
        let separated = QuoteStripper.separatingQuotedText(fromHTML: html)
        #expect(separated.newText == newText)
        #expect(separated.detectedMarker == "borderLeftQuoteDiv")
    }

    @Test("strips an Outlook-mobile-style border-top divider followed by a From: block (Task #90 gap fix)")
    func stripsOutlookMobileBorderTopDivider() {
        let html = """
        <div>\(newText)</div>
        <div style="border-top:solid #E1E1E1 1.0pt; padding:3.0pt 0in 0in 0in">
        <p><b>From:</b> John Doe &lt;john@example.com&gt;<br>
        <b>Sent:</b> Monday, July 27, 2026 10:00 AM<br>
        <b>Subject:</b> Re: Project update</p>
        </div>
        <div>Original message body that should be dropped entirely.</div>
        """
        let separated = QuoteStripper.separatingQuotedText(fromHTML: html)
        #expect(separated.newText == newText)
        #expect(separated.detectedMarker == "borderTopFromBlock")
    }

    // MARK: - separatingQuotedHTML (Task #133)

    @Test("separatingQuotedHTML returns raw, un-flattened HTML on both sides of a gmail_quote split")
    func separatingQuotedHTMLKeepsRawMarkup() throws {
        let html = """
        <div dir="auto">\(newText)</div>
        <div class="gmail_quote">
        <div dir="ltr" class="gmail_attr">2026年7月27日(月) 10:00 山田太郎 &lt;yamada@example.com&gt;:</div>
        <blockquote class="gmail_quote" style="margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex">
        <div dir="auto">Original quoted body, dropped from the WKWebView side but kept intact here.</div>
        </blockquote>
        </div>
        """
        let separated = QuoteStripper.separatingQuotedHTML(fromHTML: html)
        let unwrapped = try #require(separated)
        // Raw markup preserved (not flattened to plain text) — the whole
        // point of this API over `separatingQuotedText(fromHTML:)`.
        #expect(unwrapped.newHTML.contains("<div dir=\"auto\">\(newText)</div>"))
        #expect(unwrapped.quotedHTML.contains("gmail_attr"))
        #expect(unwrapped.quotedHTML.contains("blockquote"))
        #expect(unwrapped.detectedMarker == "gmailQuote")
    }

    @Test("separatingQuotedHTML returns nil when there is no quote marker")
    func separatingQuotedHTMLReturnsNilWhenNoMarker() {
        let html = "<div>\(newText)</div>"
        #expect(QuoteStripper.separatingQuotedHTML(fromHTML: html) == nil)
    }

    @Test("separatingQuotedHTML returns nil when the new-text side is too short (forward-only fallback)")
    func separatingQuotedHTMLReturnsNilWhenForwardOnly() {
        let html = "<blockquote type=\"cite\"><div>Original message body only, nothing new here.</div></blockquote>"
        #expect(QuoteStripper.separatingQuotedHTML(fromHTML: html) == nil)
    }
}

/// The exact trailing whitespace/newline count left behind at a truncation
/// boundary is an implementation detail (it depends on how much blank
/// space separated the new text from the quote marker in the source) —
/// tests assert on the trimmed content actually kept, not that detail.
private func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}
