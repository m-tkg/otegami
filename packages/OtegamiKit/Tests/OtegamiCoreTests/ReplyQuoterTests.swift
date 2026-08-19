import OtegamiCore
import Testing

/// `ReplyQuoter` の回帰テスト。
///
/// 実バグ (2026-08): 保存済み本文の改行が `\r` / `\r\n` だと、`"\n"` だけの
/// split では分割されず `> ` 引用が先頭にしか付かないうえ、本文に残った生の
/// `\r` が送信時の HTML パートに混入し、MailCore2 (libetpan) の
/// quoted-printable エンコーダが `\r` 直後のバイトを壊して不正 UTF-8 を出力
/// → 受信側で本文全体が Latin-1 フォールバックで文字化けした。
@Suite("ReplyQuoter")
struct ReplyQuoterTests {
    @Test("LF line endings get a quote prefix on every line")
    func quotesEveryLineForLFInput() {
        #expect(ReplyQuoter.quote("一行目\n二行目") == "> 一行目\n> 二行目")
    }

    @Test("CR-only line endings still get a quote prefix on every line")
    func quotesEveryLineForCROnlyInput() {
        #expect(ReplyQuoter.quote("一行目\r二行目\r三行目") == "> 一行目\n> 二行目\n> 三行目")
    }

    @Test("CRLF line endings are normalized and quoted per line")
    func quotesEveryLineForCRLFInput() {
        #expect(ReplyQuoter.quote("一行目\r\n\r\n三行目") == "> 一行目\n> \n> 三行目")
    }

    @Test("quoted output never contains a carriage return")
    func emitsNoCarriageReturn() {
        let quoted = ReplyQuoter.quote("a\rb\r\nc\nd")
        #expect(!quoted.contains("\r"))
        #expect(quoted == "> a\n> b\n> c\n> d")
    }
}
