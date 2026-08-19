import Foundation

/// 返信・転送本文の `> ` 引用を組み立てる純関数 (`ComposerView` の
/// `quotedBody(from:)` が使う)。`SubjectNormalizer` と同じ「Composer の
/// 送信前処理のうち、UI に依存しない部分だけを OtegamiCore に置いて
/// `make test` 圏内でテストする」形。
///
/// 行分割の前に改行を `\n` に正規化する — 保存済み本文の改行が `\r` /
/// `\r\n` のことがあり (実例: eki-net からの予約通知メール)、`"\n"` だけで
/// split すると全体が 1 行扱いになって `> ` が先頭にしか付かないうえ、
/// 本文に残った生の `\r` が送信時の HTML パートに混入し、MailCore2
/// (libetpan) の quoted-printable エンコーダが `\r` 直後のバイトを壊して
/// 不正 UTF-8 を出力する実バグがあった (受信側では本文全体が Latin-1
/// フォールバックで文字化けする)。
public enum ReplyQuoter {
    public static func quote(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
    }
}
