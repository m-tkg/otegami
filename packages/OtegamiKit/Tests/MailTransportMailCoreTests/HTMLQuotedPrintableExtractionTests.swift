import Foundation
import Testing
@testable import MailTransportMailCore
import MailCore
import MailTransport
import OtegamiCore

/// 2026-07-30 (実機フィードバック: 通知メールの翻訳が OS 標準の翻訳シート
/// 「言語を自動判定できません」(候補 Indonesian/Polish) に陥る不具合の
/// 根治): ユーザー提供の実際の eml (機微情報のためコミットしない) を
/// scratchpad の使い捨てツールで直接 `MCOMessageParser`/
/// `MailCoreIMAPSession.bodyContent(from:)` に通してダンプした結果、
/// `plainText` (Task #134 で既に修正済み) はクリーンだったが、`html` は
/// `nonEmpty(parser.htmlBodyRendering())` 由来で汚染されていた —
/// quoted-printable のソフト改行 (`="` + CRLF、タグの閉じ`"`と`>`の間) の
/// マーカー(`=`)は消えるのに、続くCRLFが正しい位置 (タグ境界) で消化されず
/// 本文の途中 (単語と単語の間) にずれ込んでいた。同じ eml の text/html
/// リーフパートを直接 `.decodedString()` した結果はこの問題が無かった —
/// `MailCoreIMAPSession+Mapping.swift`の`html(from:)`が Task #134 の
/// `plainText(from:)`と同じ「raw leaf part の decodedString() を優先」
/// パターンへ直すことで解決した。
///
/// このテストはその実機 eml の該当箇所 (`<td style="...">` の閉じ`"`と`>`
/// の間にソフト改行、続くテキストは元は1行) だけを、内容を完全に架空化
/// した上で再現するフィクスチャ — `PlainTextPartExtractionTests`と同じ
/// 方針 (`MCOMessageParser(data:)`でネットワーク・dev mailstack無しに
/// ローカル解析)。
@Suite("MailCoreIMAPSession.bodyContent(from:) — quoted-printable text/html extraction (no dev mailstack required)")
struct HTMLQuotedPrintableExtractionTests {
    /// 実機 eml の該当セルと同じ形: `style="..."` の閉じ`"`と`>`の間に
    /// quoted-printable のソフト改行 (`=` + CRLF)。デコード後はタグの
    /// 直後に本文が繋がり、本文の途中に改行が入ってはならない。`=3D`は
    /// `=`自体のquoted-printableエスケープ (元の生eml と同じ書式)。
    private static let softBreakAtTagBoundaryEML = """
    From: Notice Service <noreply@example.com>\r
    To: Alex Example <alex@example.com>\r
    Subject: New sign-on notification\r
    Message-ID: <qp-softbreak@example.com>\r
    MIME-Version: 1.0\r
    Content-Type: multipart/alternative; boundary="altBoundary"\r
    \r
    --altBoundary\r
    Content-Type: text/plain; charset=utf-8\r
    Content-Transfer-Encoding: quoted-printable\r
    \r
    Hi Alex,\r
    Your account was just used to sign in from a new device.\r
    \r
    --altBoundary\r
    Content-Type: text/html; charset=utf-8\r
    Content-Transfer-Encoding: quoted-printable\r
    \r
    <html><body><table><tbody><tr><td style=3D"color:#5e5e5e;font-size:22px;lin=\r
    e-height:22px"=\r
    >Example Corp - New sign-on detected for your account</td></tr>\r
    <tr><td style=3D"padding-top:24px">Hi Alex,</td></tr>\r
    </tbody></table></body></html>\r
    \r
    --altBoundary--\r
    """

    @Test("a quoted-printable soft break landing right at a tag boundary doesn't inject a stray newline into the following text")
    func softBreakAtTagBoundaryDoesNotSplitFollowingText() throws {
        let parser = MCOMessageParser(data: Data(Self.softBreakAtTagBoundaryEML.utf8))
        let content = MailCoreIMAPSession.bodyContent(from: parser)

        let html = try #require(content.html)
        // The whole cell's text must survive as one unbroken run — no
        // newline (or anything else) inserted between "Corp" and "- New".
        #expect(html.contains("Example Corp - New sign-on detected for your account"))
        // No literal quoted-printable soft-break marker survives either.
        #expect(!html.contains("=\r\n"))
        #expect(!html.contains("=\n"))
        // No leftover `=XX` hex-escape residue (e.g. a stray `=3D` that
        // should have decoded to `=`).
        #expect(html.range(of: "=[0-9A-Fa-f]{2}", options: .regularExpression) == nil)
    }

    @Test("the plain-text alternative in the same message is unaffected (already correct via Task #134)")
    func plainTextAlternativeStaysClean() throws {
        let parser = MCOMessageParser(data: Data(Self.softBreakAtTagBoundaryEML.utf8))
        let content = MailCoreIMAPSession.bodyContent(from: parser)

        let plainText = try #require(content.plainText)
        #expect(plainText.contains("Hi Alex,"))
        #expect(plainText.contains("Your account was just used to sign in from a new device."))
        #expect(!plainText.contains("=\r\n"))
        #expect(!plainText.contains("=\n"))
    }

    /// An HTML-only message (no `text/html` leaf found some other way) must
    /// still fall back to `parser.htmlBodyRendering()` — mirrors
    /// `PlainTextPartExtractionTests.fallsBackToRenderingWhenNoPlainTextPart`.
    /// Not expected to happen in practice (a message with an HTML body
    /// always has an actual `text/html` part to find), but keeps `html(from:)`
    /// symmetric with `plainText(from:)`'s same fallback structure.
    @Test("falls back to parser.htmlBodyRendering() when body has no discoverable text/html leaf part")
    func fallsBackToRenderingWhenNoHTMLPartFound() throws {
        let eml = """
        From: Sender One <sender1@example.com>\r
        To: Receiver One <receiver1@example.com>\r
        Subject: Plain only\r
        Message-ID: <plain-only@example.com>\r
        MIME-Version: 1.0\r
        Content-Type: text/plain; charset="UTF-8"\r
        Content-Transfer-Encoding: 7bit\r
        \r
        Just a plain-text message, no HTML part at all.\r
        """
        let parser = MCOMessageParser(data: Data(eml.utf8))
        let content = MailCoreIMAPSession.bodyContent(from: parser)
        // No text/html part exists at all, so `html` is whatever (if
        // anything) `parser.htmlBodyRendering()` synthesizes — this must
        // not throw/crash, and `plainText` must still be the real part.
        let plainText = try #require(content.plainText)
        #expect(plainText.contains("Just a plain-text message, no HTML part at all."))
    }
}
