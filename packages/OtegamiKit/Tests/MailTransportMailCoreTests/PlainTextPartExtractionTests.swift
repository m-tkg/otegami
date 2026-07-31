import Foundation
import Testing
@testable import MailTransportMailCore
import MailCore
import MailTransport
import OtegamiCore

/// Task #134 (実機のみで再現する「引用が要約に混入する」症状の根治):
/// `MailCoreIMAPSession.bodyContent(from:)`は以前、text/plainパートが実在
/// するかどうかに関わらず常に`parser.plainTextBodyRendering()`(mailcore2の
/// HTML優先タグ剥がしレンダリング)を`plainText`に使っていた。ローカル
/// (Mac)での再現ではこの合成結果でも`QuoteStripper`の引用マーカー検出
/// (`> `などの行頭記号)が問題なく機能したが、実機でだけ「気をつけて
/// 帰ってね」以降の過去のやり取りが要約に混入する症状が a43c07e (Task
/// #132のプロンプト強化) 後も継続した — 実機の`bodyRecord.plainText`が
/// 本物のtext/plainパートの内容とは微妙に異なる形状の合成レンダリング
/// だった疑いが濃厚。
///
/// `CalendarInviteMIMEParsingTests`と同じ方針: `MCOMessageParser(data:)`が
/// 生RFC822バイト列をネットワーク・dev mailstack無しでローカルに解析
/// できることを利用し、`MailCoreIMAPSession.bodyContent(from:)`(実際に
/// `MailCoreIMAPSession.fetchBody`が呼ぶ関数そのもの)へ直接フィクスチャを
/// 通す。フィクスチャは実際のメール(yoyaku.eml、機微につきコミット禁止)
/// の構造 — 新規本文の下に">"引用マーカー付きの過去のやり取りが続く
/// multipart/alternative — を、内容を完全に架空化した上で模したもの。
@Suite("MailCoreIMAPSession.bodyContent(from:) — text/plain part extraction (no dev mailstack required)")
struct PlainTextPartExtractionTests {
    /// `multipart/alternative` > `[text/plain (quoted reply), text/html]`
    /// — yoyaku.eml と同じ形: 新規本文の下に空行を挟んで">"始まりの引用
    /// 行が続く。
    private static let quotedReplyEML = """
    From: Sender One <sender1@example.com>\r
    To: Receiver One <receiver1@example.com>\r
    Subject: Re: Weekend meetup\r
    Message-ID: <quoted-reply@example.com>\r
    MIME-Version: 1.0\r
    Content-Type: multipart/alternative; boundary="altBoundary"\r
    \r
    --altBoundary\r
    Content-Type: text/plain; charset="UTF-8"\r
    Content-Transfer-Encoding: 7bit\r
    \r
    Sounds good, thanks so much — take care on the way home!\r
    \r
    > Thanks for today.\r
    > Let's meet at the station next time.\r
    > See you then.\r
    \r
    --altBoundary\r
    Content-Type: text/html; charset="UTF-8"\r
    Content-Transfer-Encoding: 7bit\r
    \r
    <html><body><p>Sounds good, thanks so much — take care on the way home!</p><blockquote>Thanks for today.<br>Let's meet at the station next time.<br>See you then.</blockquote></body></html>\r
    \r
    --altBoundary--\r
    """

    @Test("uses the real text/plain part's decoded content, quote markers intact, instead of the synthesized HTML-derived rendering")
    func usesRealPlainTextPartWhenPresent() throws {
        let parser = MCOMessageParser(data: Data(Self.quotedReplyEML.utf8))
        let content = MailCoreIMAPSession.bodyContent(from: parser)

        let plainText = try #require(content.plainText)
        #expect(plainText.contains("Sounds good, thanks so much — take care on the way home!"))
        // The quote marker is exactly what `QuoteStripper`'s marker
        // patterns look for — this is the crux of Task #134's fix.
        #expect(plainText.contains("> Thanks for today."))
        #expect(plainText.contains("> Let's meet at the station next time."))
        #expect(plainText.contains("> See you then."))
    }

    @Test("still separates the same message's new text from its quoted history via QuoteStripper once real plain text is used")
    func quoteStripperSeparatesRealPlainTextCorrectly() throws {
        let parser = MCOMessageParser(data: Data(Self.quotedReplyEML.utf8))
        let content = MailCoreIMAPSession.bodyContent(from: parser)
        let plainText = try #require(content.plainText)

        let separated = QuoteStripper.separatingQuotedText(fromPlainText: plainText, isReply: true)
        #expect(separated.newText.contains("Sounds good, thanks so much — take care on the way home!"))
        #expect(!separated.newText.contains("Thanks for today."))
        #expect(separated.quotedText.contains("Thanks for today."))
    }

    /// `multipart/mixed` > `multipart/alternative` > `[text/plain,
    /// text/html]`, one container deeper — confirms the search recurses
    /// through nested multipart containers the same way
    /// `CalendarInviteMIMEParsingTests` confirms for attachment discovery.
    @Test("finds the text/plain part even nested inside an outer multipart/mixed")
    func findsPlainTextPartNestedInsideMixed() throws {
        let eml = """
        From: Sender One <sender1@example.com>\r
        To: Receiver One <receiver1@example.com>\r
        Subject: Re: Weekend meetup\r
        Message-ID: <nested-quoted-reply@example.com>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="mixedBoundary"\r
        \r
        --mixedBoundary\r
        Content-Type: multipart/alternative; boundary="altBoundary"\r
        \r
        --altBoundary\r
        Content-Type: text/plain; charset="UTF-8"\r
        Content-Transfer-Encoding: 7bit\r
        \r
        Sounds good, take care on the way home!\r
        \r
        > Thanks for today.\r
        \r
        --altBoundary\r
        Content-Type: text/html; charset="UTF-8"\r
        Content-Transfer-Encoding: 7bit\r
        \r
        <html><body><p>Sounds good, take care on the way home!</p></body></html>\r
        \r
        --altBoundary--\r
        --mixedBoundary\r
        Content-Type: application/pdf; name="notes.pdf"\r
        Content-Disposition: attachment; filename="notes.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        JVBERi0xLjQK\r
        \r
        --mixedBoundary--\r
        """
        let parser = MCOMessageParser(data: Data(eml.utf8))
        let content = MailCoreIMAPSession.bodyContent(from: parser)

        let plainText = try #require(content.plainText)
        #expect(plainText.contains("> Thanks for today."))
    }

    /// An HTML-only message (no `text/plain` alternative at all) must still
    /// fall back to `plainTextBodyRendering()` — Task #134 only changes
    /// which source is *preferred* when a real text/plain part exists, not
    /// what happens when one doesn't.
    @Test("falls back to plainTextBodyRendering() when no text/plain part exists")
    func fallsBackToRenderingWhenNoPlainTextPart() throws {
        let eml = """
        From: Sender One <sender1@example.com>\r
        To: Receiver One <receiver1@example.com>\r
        Subject: HTML only\r
        Message-ID: <html-only@example.com>\r
        MIME-Version: 1.0\r
        Content-Type: text/html; charset="UTF-8"\r
        Content-Transfer-Encoding: 7bit\r
        \r
        <html><body><p>Hello from an HTML-only message.</p></body></html>\r
        """
        let parser = MCOMessageParser(data: Data(eml.utf8))
        let content = MailCoreIMAPSession.bodyContent(from: parser)

        let plainText = try #require(content.plainText)
        #expect(plainText.contains("Hello from an HTML-only message."))
    }
}
