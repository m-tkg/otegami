import OtegamiCore
import Testing
@testable import Otegami

/// 送信時の段落分割 (`RichTextAttributedString.makeDocument`) の改行終端
/// まわりの回帰テスト。`ReplyQuoter` 側の引用テストは
/// `OtegamiCoreTests/ReplyQuoterTests` にある。
///
/// 実バグ (2026-08): `paragraphRange(for:)` は `\r` / `\r\n` / U+0085 /
/// U+2028 / U+2029 でも段落を区切るのに、終端の除去が `\n` だけだったため、
/// `\r\n` / `\r` 終端の段落テキストに生 CR が残り、送信 HTML パートに混入。
/// MailCore2 (libetpan) の quoted-printable エンコーダが CR 直後のバイトを
/// 壊して不正 UTF-8 を出力 → 受信側で本文全体が Latin-1 フォールバックで
/// 文字化けした。
@Suite("Composer body newline normalization")
struct ComposerBodyNewlineTests {
    @Test("makeDocument strips CR / CRLF paragraph terminators")
    func makeDocumentStripsCarriageReturnTerminators() {
        let attributed = RichTextAttributedString.plainAttributedString("高木\r\nさま\rです\n了")
        let document = RichTextAttributedString.makeDocument(from: attributed)
        let texts = document.paragraphs.map { paragraph in
            paragraph.runs.map(\.text).joined()
        }
        #expect(texts == ["高木", "さま", "です", "了"])
        let html = RichTextHTMLCoder.encode(document)
        #expect(!html.contains("\r"))
    }

    @Test("makeDocument strips the U+2029 paragraph separator")
    func makeDocumentStripsParagraphSeparator() {
        // U+2028 (line separator) / U+0085 は `paragraphRange(for:)` の段落
        // 区切りではない (実測) — 段落区切りになるのは \n / \r / \r\n /
        // U+2029 のみ。
        let attributed = RichTextAttributedString.plainAttributedString("a\u{2029}b")
        let document = RichTextAttributedString.makeDocument(from: attributed)
        let texts = document.paragraphs.map { paragraph in
            paragraph.runs.map(\.text).joined()
        }
        #expect(texts == ["a", "b"])
    }

    @Test("makeDocument does not duplicate the final paragraph of terminator-less text")
    func makeDocumentDoesNotDuplicateFinalParagraph() {
        // 既存バグ: 終端改行の無いテキストで `<=` ループが最終段落をもう一度
        // 拾い、送信 HTML の最終行が重複していた。
        let attributed = RichTextAttributedString.plainAttributedString("hello")
        let document = RichTextAttributedString.makeDocument(from: attributed)
        #expect(document.paragraphs.map { $0.runs.map(\.text).joined() } == ["hello"])
    }

    @Test("makeDocument keeps the trailing blank line of terminator-final text")
    func makeDocumentKeepsTrailingBlankLine() {
        let attributed = RichTextAttributedString.plainAttributedString("hello\n")
        let document = RichTextAttributedString.makeDocument(from: attributed)
        #expect(document.paragraphs.map { $0.runs.map(\.text).joined() } == ["hello", ""])
    }
}
