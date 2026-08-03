import Foundation
import MailCore
import MailTransport
import OtegamiCore

/// Body/attachment extraction policy, split out of
/// `MailCoreIMAPSession+Mapping.swift` (Phase 4 internal cleanup): converts
/// a freshly-parsed `MCOMessageParser` into this package's `MessageBodyContent`/
/// `MIMEPartInfo` value types, plus the RFC 2231 filename fallback and raw
/// attachment-data lookup that ride along with that same M2/M8 sync path.
/// Kept separate from the envelope/mailbox/QRESYNC mapping code (which stays
/// in `MailCoreIMAPSession+Mapping.swift`) because body extraction is a
/// distinct policy concern (what counts as "the" plain text/HTML body of a
/// message, quoted-printable/HTML-rendering pitfalls, RFC 2231 fallback) from
/// IMAP sync bookkeeping (UID ranges, QRESYNC vanished sets) — the two evolve
/// for unrelated reasons and this split makes each easier to read in
/// isolation.
///
/// `private static` (i.e. `nonisolated`) for the same reason as everything in
/// `MailCoreIMAPSession+Mapping.swift`: these run inside MailCore2 completion
/// closures, which fire on MailCore2's own internal thread rather than
/// `MailCoreIMAPSession`'s actor executor, and never touch actor state.
extension MailCoreIMAPSession {
    // MARK: - RFC 2231 filename fallback

    /// Patches `content.parts` with RFC 2231-decoded filenames recovered
    /// from `rawMessage`'s raw `Content-Disposition` headers, for whichever
    /// attachment part(s) mailcore2 left with `filename == nil`
    /// (`docs/roadmap.md`'s "RFC 2231 ファイル名のみのメール" note).
    ///
    /// Matches positionally: the n-th part needing a filename (in `parts`'
    /// order) gets the n-th filename `RFC2231FilenameDecoder
    /// .extendedFilenames` found in `rawMessage` (in document order). This
    /// is safe rather than approximate because `extendedFilenames` only
    /// ever surfaces `Content-Disposition` headers using the *extended*
    /// (`filename*=`) form in the first place — exactly the set mailcore2
    /// fails to parse a `filename` out of — so a plain `filename="..."`
    /// header (which mailcore2 already resolved, leaving that part's
    /// `filename` non-nil) never contributes an entry and never occupies a
    /// slot in either list. The two orderings only need to agree among
    /// *this* subset, and both walk the message's MIME parts in the same
    /// (wire/structural) order.
    ///
    /// If `rawMessage` contains fewer RFC 2231 filenames than there are
    /// parts missing one (e.g. one attachment's header was malformed enough
    /// that `extendedFilenames` skipped it — see its own doc comment), the
    /// remaining part(s) are left with `filename == nil`, same as before
    /// this fallback ran; this never removes information, only adds it.
    static func applyRFC2231FilenameFallback(to content: MessageBodyContent, rawMessage: Data) -> MessageBodyContent {
        let missingIndices = content.parts.indices.filter {
            content.parts[$0].isAttachment && content.parts[$0].filename == nil
        }
        guard !missingIndices.isEmpty else { return content }

        let filenames = RFC2231FilenameDecoder.extendedFilenames(inRawMessage: rawMessage)
        guard !filenames.isEmpty else { return content }

        var patched = content
        for (offset, index) in missingIndices.enumerated() where offset < filenames.count {
            patched.parts[index].filename = filenames[offset]
        }
        return patched
    }

    // MARK: - Body (M2)

    /// `MCOMessageParser.attachments()`/`.htmlInlineAttachments()` return
    /// `MCOAttachment` (a leaf `MCOAbstractPart` subclass) rather than the
    /// `MCOIMAPPart` that `flattenParts(_:)` above works with —
    /// `MCOMessageParser` re-parses the whole RFC822 blob locally rather
    /// than walking the server's `BODYSTRUCTURE`, so its parts have no IMAP
    /// part specifier at all. `uniqueID` (a stable identifier the parser
    /// assigns while walking the MIME tree) stands in as `MIMEPartInfo
    /// .partId` instead; it isn't a `BODY[<partId>]` fetch key, so M8's
    /// attachment *data* download will need its own lookup (`partForUniqueID`
    /// on a freshly-parsed message), not `fetchMessageBody(partId:)`.
    static func bodyContent(from parser: MCOMessageParser) -> MessageBodyContent {
        MessageBodyContent(
            plainText: plainText(from: parser),
            html: html(from: parser),
            parts: parts(from: parser)
        )
    }

    /// 2026-07-30 (実機フィードバック: Okta通知メールがOS標準の翻訳シート
    /// 「言語を自動判定できません」に陥り、候補が Indonesian/Polish という
    /// 無関係な言語だった調査): 実際の eml (アップロード添付、機微情報の
    /// ためコミットしない) を `MCOMessageParser(data:)` へ通し、
    /// `MailCoreIMAPSession.bodyContent(from:)` が実際に生成する
    /// `plainText`/`html` をダンプして比較したところ —
    ///
    /// - `plainText` (既にTask #134で同じ理由により`decodedString()`優先に
    ///   直してある) はクリーン: quoted-printableの残骸(`=`+改行の
    ///   ソフト改行未処理、`=XX`16進残骸) は一切無い。
    /// - **`nonEmpty(parser.htmlBodyRendering())`(このメソッドが直していた
    ///   場所) は汚染されていた**: 生の eml では
    ///   `<td style="...line-height:22px"=` + 改行 + `>PLAID,inc - New
    ///   sign-on detected...` (`=`のソフト改行はタグの`"`と`>`の間) だった
    ///   ものが、`htmlBodyRendering()`の出力では
    ///   `>PLAID,inc` + **改行が本来無いはずの位置** + `- New sign-on
    ///   detected...` という、文中に脈絡なく改行が挿入された形になって
    ///   いた — ソフト改行のマーカー(`=`)そのものは正しく消えているが、
    ///   後続の改行を正しい位置 (タグ境界) で消化せず、本文の途中に
    ///   ずれ込ませてしまう再現性のあるバグ (mailcore2側の描画/再整形
    ///   処理由来と見られる、Task #134の`plainTextBodyRendering()`と
    ///   同系統の問題)。同じ eml の `text/html` リーフパートを
    ///   `firstHTMLPart`経由で直接取り出し`.decodedString()`した結果は
    ///   `PLAID,inc - New sign-on detected...`と正しく1行に繋がって
    ///   おり、汚染は無かった。
    ///
    /// これは翻訳失敗の直接原因の一つ — 文中に混入した改行が、Apple
    /// Translationの言語自動判定 (特に`TranslationSession.Configuration
    /// (source: nil, ...)`の1回だけの判定、あるいは複数段落をまとめて
    /// バッチ送信する`translateBatch`の集約判定) を混乱させ、"Indonesian/
    /// Polish"のような無関係な候補が出る一因になっていたと考えられる
    /// (`AppleTranslationService`のOS標準翻訳シートへのフォールバック
    /// 経路がこのケースで作動していた)。
    ///
    /// `plainText(from:)`と全く同じ方針で修正: `parser.mainPart()`から
    /// text/htmlのリーフパートを優先的に探し、見つかればその
    /// `.decodedString()`(=既にトランスファーエンコーディング/文字コード
    /// をmailcore2がデコード済みの生文字列、`htmlBodyRendering()`のような
    /// 再整形を経ない)を使う。見つからない場合(text/htmlパートが実在
    /// しない、HTMLがどこか別のパートから合成されるような稀なケース)だけ
    /// 従来通り`parser.htmlBodyRendering()`にフォールバックする。
    private static func html(from parser: MCOMessageParser) -> String? {
        if let mainPart = parser.mainPart(),
           let htmlPart = firstHTMLPart(mainPart),
           let decoded = htmlPart.decodedString(),
           !decoded.isEmpty {
            return decoded
        }
        return nonEmpty(parser.htmlBodyRendering())
    }

    /// Depth-first search for the first non-attachment `text/html` leaf
    /// under `part` — mirrors `firstPlainTextPart` immediately below
    /// (same traversal rules: only descends into `MCOAbstractMultipart`
    /// containers, never into a nested `message/rfc822` part).
    private static func firstHTMLPart(_ part: MCOAbstractPart) -> MCOAttachment? {
        if let multipart = part as? MCOAbstractMultipart {
            for child in multipart.parts ?? [] {
                if let found = firstHTMLPart(child) {
                    return found
                }
            }
            return nil
        }
        guard let attachment = part as? MCOAttachment, !attachment.isAttachment else { return nil }
        guard (attachment.mimeType ?? "").lowercased() == "text/html" else { return nil }
        return attachment
    }

    /// Task #134 (実機のみで再現する「引用が要約に混入する」症状の根治):
    /// `plainTextBodyRendering()`はmailcore2側の*描画*で、text/plainパート
    /// が存在しない(HTMLのみの)メールに対してはHTMLタグを剥がして代用の
    /// 平文を合成する — その合成結果は本物のtext/plainパートと似ているが
    /// 同一ではなく、特に`QuoteStripper`の引用マーカー検出("> "などの
    /// 行頭記号)は実機で観測された実際の`plainTextBodyRendering()`出力の
    /// 形状に対して確実には一致しなかった (Mac上のeml再現・HTML剥がし
    /// 近似のどちらでも問題が起きず「実機のmailcore2実描画特有の形状差」
    /// が疑われた調査の結論)。メッセージが実際にtext/plainパートを持つ
    /// 場合は、その*デコード済み生文字列*(引用の`>`をそのまま含む、MIME
    /// が本来持っている形)を使う方が確実 — このメソッドはまず`parser
    /// .mainPart()`をtext/plainのリーフパートを探して優先し、見つから
    /// なければ(HTMLのみのメールなど)従来通り`plainTextBodyRendering()`
    /// にフォールバックする。既存にキャッシュ済みの本文の移行は行わない
    /// (次回フェッチ時から新しい経路に切り替わる)。
    private static func plainText(from parser: MCOMessageParser) -> String? {
        if let mainPart = parser.mainPart(),
           let plainTextPart = firstPlainTextPart(mainPart),
           let decoded = plainTextPart.decodedString(),
           !decoded.isEmpty {
            return decoded
        }
        return nonEmpty(parser.plainTextBodyRendering())
    }

    /// Depth-first search for the first non-attachment `text/plain` leaf
    /// under `part` — mirrors how a typical `multipart/alternative`
    /// (`[text/plain, text/html]`, in that order) lists its plain variant
    /// first. Only descends into `MCOAbstractMultipart` containers
    /// (`multipart/mixed`, `/alternative`, `/related`, ...); deliberately
    /// does *not* descend into a `message/rfc822` embedded-message part
    /// (`MCOAbstractMessagePart`/`MCOMessagePart`) — that would surface an
    /// *attached* forwarded email's own body text as if it were this
    /// message's body, which is a different bug than the one this method
    /// fixes.
    private static func firstPlainTextPart(_ part: MCOAbstractPart) -> MCOAttachment? {
        if let multipart = part as? MCOAbstractMultipart {
            for child in multipart.parts ?? [] {
                if let found = firstPlainTextPart(child) {
                    return found
                }
            }
            return nil
        }
        guard let attachment = part as? MCOAttachment, !attachment.isAttachment else { return nil }
        guard (attachment.mimeType ?? "").lowercased() == "text/plain" else { return nil }
        return attachment
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    /// Attachments and inline (`cid:`-referenced) parts, de-duplicated by
    /// `uniqueID` — `attachments()` and `htmlInlineAttachments()` can both
    /// report the same part in some multipart layouts.
    private static func parts(from parser: MCOMessageParser) -> [MIMEPartInfo] {
        var seenUniqueIDs: Set<String> = []
        var result: [MIMEPartInfo] = []
        for part in (parser.attachments() ?? []) + (parser.htmlInlineAttachments() ?? []) {
            let uniqueID = part.uniqueID ?? ""
            guard seenUniqueIDs.insert(uniqueID).inserted else { continue }
            result.append(mimePartInfo(from: part))
        }
        return result
    }

    // MARK: - Attachment data (M8)

    /// Looks up `uniqueID` (an `AttachmentRecord.partId` value, as stamped
    /// by `parts(from:)` above at body-fetch time) among `parser`'s parts
    /// and returns its raw, decoded bytes — `MCOAbstractPart.getData(_:)`
    /// handles the `Content-Transfer-Encoding` decoding itself, the same
    /// division of labor `bodyContent(from:)` already relies on for the
    /// text parts. `applyUniquePartID` (mailcore2's own uniqueID assignment,
    /// a deterministic breadth-first walk of the MIME tree keyed only by
    /// structural position) reruns identically every time the same RFC 822
    /// bytes are reparsed, which is what makes re-fetching+reparsing the
    /// whole message here — rather than trying to map back to a real IMAP
    /// `BODY[<partId>]` specifier the parser never captured in the first
    /// place — a safe way to resolve this uniqueID back to data on a fresh
    /// `MCOMessageParser` instance (see `MailCoreIMAPSession.fetchMessageBody`'s
    /// doc comment for the full rationale, and `parts(from:)`'s doc comment
    /// above for why `partId` is a uniqueID and not a `BODYSTRUCTURE` path
    /// to begin with). Runs inside a MailCore2 completion closure (MailCore2's
    /// own internal thread), like every other `private static` helper in
    /// this file — never touches actor state.
    static func partData(from parser: MCOMessageParser, uniqueID: String) -> Data? {
        guard let part = parser.partForUniqueID(uniqueID: uniqueID) else { return nil }
        return MCOAbstractPart.getData(part)
    }

    /// Phase 4a (`docs/architecture.md` の Known pitfalls 未収録の背景は
    /// `BodyFetcher.performFetch` のコメント参照): `parser`はこの時点で
    /// `part`のバイト列を既にメモリ上に持っている(`fetchParsedMessageOperation`
    /// がRFC822全文をダウンロード・パース済み)ので、`MIMEPartInfo.data`に
    /// 上限付きで詰めておく — `size`が`0`(空パート)や
    /// `MIMEPartInfo.maxEmbeddedDataSize`超のときは`nil`のまま(従来通り
    /// `AttachmentFetcher`のオンデマンド取得に委ねる)。
    private static func mimePartInfo(from part: MCOAbstractPart) -> MIMEPartInfo {
        let mimeType = part.mimeType ?? "application/octet-stream"
        let components = mimeType.split(separator: "/", maxSplits: 1)
        let type = components.first.map(String.init) ?? mimeType
        let subtype = components.count > 1 ? String(components[1]) : ""
        let rawData = (part as? MCOAttachment)?.data
        let size = rawData?.count ?? 0
        let embeddedData = (size > 0 && size <= MIMEPartInfo.maxEmbeddedDataSize) ? rawData : nil

        return MIMEPartInfo(
            partId: part.uniqueID ?? "",
            mimeType: type,
            mimeSubtype: subtype,
            filename: part.filename,
            contentId: part.contentID,
            isAttachment: part.isAttachment,
            size: size,
            data: embeddedData
        )
    }
}
