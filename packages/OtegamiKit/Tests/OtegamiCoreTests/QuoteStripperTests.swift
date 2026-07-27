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
}

/// The exact trailing whitespace/newline count left behind at a truncation
/// boundary is an implementation detail (it depends on how much blank
/// space separated the new text from the quote marker in the source) —
/// tests assert on the trimmed content actually kept, not that detail.
private func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}
