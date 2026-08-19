import Foundation
import Testing
@testable import MailTransportMailCore
import MailCore
import MailTransport
import OtegamiCore

/// 2026-08 の転送文字化け (docs/architecture.md 落とし穴 u.) の表示側の
/// 回帰テスト: 修正前の Otegami が送った転送メールは、mailcore2 の QP
/// エンコーダの裸 CR バグで charset=utf-8 の HTML パートに不正 UTF-8
/// バイトが 1 個混入していることがある。mailcore2 の `decodedString()`
/// (charset 変換) は UTF-8 デコード失敗で Latin-1 系にフォールバックし、
/// 1 バイトの破損が本文全体の文字化けに波及していた —
/// `MailCoreBodyExtraction.decodedText(from:)` が UTF-8 宣言パートを
/// lossy デコード (不正バイトのみ U+FFFD) で救うことをピン留めする。
extension MailCoreLocalSuite {
    @Suite("MailCoreIMAPSession.bodyContent(from:) — invalid UTF-8 in a declared-utf-8 part (no dev mailstack required)")
    struct InvalidUTF8BodyExtractionTests {
        /// 実際に破損した転送メールの HTML パートと同じ形: QP 本文の中に
        /// 生の 0xE9 (UTF-8 継続バイトを伴わない不正バイト) が 1 個だけ
        /// 混入している。ヘッダ・plain パートは正常。
        private static func corruptedForwardEML() -> Data {
            let head = """
            From: Fictional Sender <sender@otegami.test>\r
            To: Fictional Receiver <receiver@otegami.test>\r
            Subject: Fwd: corrupted\r
            Message-ID: <invalid-utf8@otegami.test>\r
            MIME-Version: 1.0\r
            Content-Type: multipart/alternative; boundary="altBoundary"\r
            \r
            --altBoundary\r
            Content-Type: text/plain; charset="utf-8"\r
            Content-Transfer-Encoding: quoted-printable\r
            \r
            =E9=AB=98=E6=9C=A8=E3=81=95=E3=81=BE\r
            \r
            --altBoundary\r
            Content-Type: text/html; charset="utf-8"\r
            Content-Transfer-Encoding: quoted-printable\r
            \r
            <p>&gt;  =0D/p><p>
            """
            let tail = """
            =E9=AB=98=E6=9C=A8=E3=80=80=E3=81=95=E3=81=BE=0D</p><p>=E4=BC=9A=E5=93=A1=\r
            =E7=95=AA=E5=8F=B7=EF=BC=9A127159722=0D</p>\r
            \r
            --altBoundary--\r
            """
            var data = Data(head.utf8)
            data.append(0xE9) // 裸の不正バイト (QP エンコード破壊の再現)
            data.append(Data(tail.utf8))
            return data
        }

        @Test("one invalid byte no longer garbles the whole HTML part — lossy UTF-8 keeps the rest readable")
        func invalidByteDoesNotGarbleWholeHTMLPart() throws {
            let parser = MCOMessageParser(data: Self.corruptedForwardEML())
            let content = MailCoreIMAPSession.bodyContent(from: parser)

            let html = try #require(content.html)
            // 破損バイト以降の本文が正しく読めること (Latin-1 フォール
            // バックだと「高木」は「é«˜æœ¨」のような別文字列になる)。
            #expect(html.contains("高木　さま"))
            #expect(html.contains("会員番号：127159722"))
            // 破損箇所は U+FFFD 1 文字に置換される。
            #expect(html.contains("\u{FFFD}"))
        }

        @Test("the intact plain-text alternative in the same message decodes exactly")
        func intactPlainTextPartDecodesExactly() throws {
            let parser = MCOMessageParser(data: Self.corruptedForwardEML())
            let content = MailCoreIMAPSession.bodyContent(from: parser)

            let plainText = try #require(content.plainText)
            #expect(plainText.contains("高木さま"))
            #expect(!plainText.contains("\u{FFFD}"))
        }
    }
}
