import Foundation

/// The single seam between "otegami translates mail" and any particular
/// engine that does the translating. Everything above this protocol
/// (`TranslationEngine`'s cache-aware `MessageTranslator`, and eventually
/// the UI phase's views) talks only to `TranslationService` — never to
/// `FoundationModels` directly — so:
///
///  - `FakeTranslationService` (this target) can stand in for tests and
///    previews with deterministic, instant output.
///  - `FoundationModelsTranslationService` (`OtegamiTranslationFoundationModels`,
///    a separate Apple-only target) is the only file in this codebase that
///    imports `FoundationModels`. A build without that framework — an
///    older SDK, a hypothetical Linux tool — never needs to know it exists.
///  - A future engine (a different on-device model, a opt-in cloud
///    fallback, ...) is a new conformer, not a rewrite of every call site.
///
/// This mirrors `MailTransport`'s `IMAPSessionProtocol`/
/// `SMTPSessionProtocol` split from `MailTransportMailCore`'s MailCore2
/// implementation — same shape, same reason.
///
/// All methods are `async` even though `FakeTranslationService` could
/// answer synchronously: `FoundationModelsTranslationService` always has
/// real latency (on-device inference, not instant), and a protocol that's
/// sometimes-sync-sometimes-async would force every caller to abstract over
/// that difference anyway. Better to make the async cost visible everywhere
/// from the start.
///
/// Task #159 (メール翻訳を Apple Translation フレームワークの専用 NMT へ切替):
/// refines `TranslationOnlyService` (this target) rather than re-declaring
/// `translate`/`translateParagraphs`/`translateStream`/`availability` itself
/// — those three methods are the half of this contract a translation-only
/// engine (`OtegamiTranslationApple`'s `AppleTranslationService`) can
/// conform to without also implementing summarization, which stays on
/// `FoundationModelsTranslationService` (`HybridTranslationService`, this
/// target, is what recombines the two into a single `TranslationService`
/// `AppEnvironment` hands out). Every existing conformer here already
/// implements all of `TranslationOnlyService`'s requirements, so this
/// refinement needed no changes to `FakeTranslationService`/
/// `FoundationModelsTranslationService` themselves.
public protocol TranslationService: TranslationOnlyService {
    /// A short summary of `text` in `targetLanguage`, roughly
    /// `sentenceCount` sentences — the design handoff's 1e list-row summary
    /// treatment ("英文行は...日本語要約2行"). `sentenceCount` is a
    /// request, not a guarantee; engines should treat it as a strong hint
    /// about desired length rather than a hard constraint the caller can
    /// rely on for layout.
    func summarize(_ text: String, targetLanguage: TranslationLanguage, sentenceCount: Int) async throws -> String

    /// A short, **unlabeled** summary of `text` — no fixed output structure,
    /// unlike `summarize` (whose `FoundationModelsTranslationService`
    /// implementation always requests a 3-part ■要約/■伝えたいこと/
    /// ■アクション structure). Exists solely as the "map" half of
    /// `summarizeLongText`'s map-reduce over long input: each
    /// `TranslationChunker` piece is compressed to about `sentenceCount`
    /// plain sentences here, and only the final, combined "reduce" step
    /// calls `summarize` — exactly once — for the real structured output.
    ///
    /// Task #122: before this method existed, `summarizeLongText` called the
    /// *structured* `summarize` once per chunk. For a multi-chunk email that
    /// produced the 3-part structure once per chunk, all joined together —
    /// and fed that already-■-labeled text back into one more structured
    /// `summarize` call as its literal input. A real-device report showed
    /// exactly the resulting failure: the labeled structure repeated, and
    /// the model — primed by ■-labeled text already present in its own
    /// input — went on to echo `summarizeInstructions`'s own label-
    /// definition wording verbatim after the real answer. Splitting the
    /// map (plain) from the reduce (structured, exactly once) removes the
    /// repeated-structure input that triggered this; `SummaryOutputSanitizer`
    /// (`OtegamiCore`) is the remaining defense-in-depth layer.
    func summarizePlain(_ text: String, targetLanguage: TranslationLanguage, sentenceCount: Int) async throws -> String

    /// Task #160フォローアップ (二重圧縮の根治): `summarizeThread`のmap段 — 各メッセージ
    /// の新規本文から、削らずに具体的な内容(決定事項・依頼/質問・数値・
    /// 日付・固有名詞)を書き出す「事実抽出」。`summarizePlain`(こちらは
    /// 「圧縮」— 内容を削ってでも短くすることが目的) とは目的が正反対な
    /// ので使い分ける: `summarizePlain`をそのまま流用すると、その指示文
    /// 自体が「短く」を最優先しており、具体的な数値・固有名詞が真っ先に
    /// 削られる (実機報告の直接の原因)。出力はラベルなしの地の文 —
    /// `summarizePlain`と同じく`SummaryOutputSanitizer`を通さない
    /// (ラベル構造が無いので対象外) が、`ThreadEntryMetaCommentaryStripper`
    /// (`OtegamiCore`) は通す — このメソッドの実装(`FoundationModelsTranslationService`)
    /// のdoc comment参照。
    ///
    /// Task #160フォローアップ5 (ユーザー指示「スレッド要約の最終形への
    /// 簡素化」): このメソッドが`summarizeThread`のパイプライン全体になった
    /// — reduce段の`summarizeThreadDigest`(■現状) とその間の
    /// `refineThreadEntries`(仕上げパス) は撤去済み。以前はmap
    /// (このメソッド) → refine (任意の統合パス) → reduce (■現状生成)
    /// という3段構成だったが、ユーザーからの一連の実機フィードバック
    /// (Task #160フォローアップ2〜4、いずれもreduce/refine段の指示文が
    /// 例文の題材を出力へ漏らしたり、入力に無い内容を作り出したりする
    /// 「モデルにもう一段書かせる」ことそのものに起因する問題だった) を
    /// 経て、「per-messageの事実抽出結果をそのまま時系列に並べるだけで
    /// 十分」という結論に至った。このメソッド (map) だけが生き残った
    /// のはそのため — `summarizeThread`のdoc comment参照。
    func summarizeThreadEntry(_ text: String, targetLanguage: TranslationLanguage) async throws -> String
}

extension TranslationService {
    /// Most callers want a 2-sentence summary (the 1e list-row treatment) —
    /// this default keeps call sites from repeating that number.
    public func summarize(_ text: String, targetLanguage: TranslationLanguage) async throws -> String {
        try await summarize(text, targetLanguage: targetLanguage, sentenceCount: 2)
    }

    /// A `summarize` that stays safe for arbitrarily long mail bodies —
    /// design-phase-3's real-device finding: `summarize` on a long English
    /// mail could hit the same context-window overflow `translate` did
    /// (`TranslationChunker`'s doc comment), and `MessageView`'s "AI要約"
    /// button has no paragraph-alignment requirement forcing it through
    /// `MessageTranslator`'s cache the way message translation does, so
    /// this lives here as a plain protocol extension any conformer gets for
    /// free. Map-reduce for oversized input: summarize each
    /// `TranslationChunker` piece to about one sentence via the *unlabeled*
    /// `summarizePlain` (Task #122 — see its doc comment for why the map
    /// step must not be the structured, 3-part `summarize`), then always
    /// run the combined partial summaries through exactly one final
    /// `summarize` call for the real 3-part structure. Short input (the
    /// common case) is a single, un-chunked `summarize` call, unchanged
    /// from before this existed.
    public func summarizeLongText(_ text: String, targetLanguage: TranslationLanguage, sentenceCount: Int = 2) async throws -> String {
        guard text.count > TranslationChunker.defaultMaxChunkLength else {
            return try await summarize(text, targetLanguage: targetLanguage, sentenceCount: sentenceCount)
        }

        let chunks = TranslationChunker.chunk(text)
        var partialSummaries: [String] = []
        partialSummaries.reserveCapacity(chunks.count)
        for chunk in chunks {
            partialSummaries.append(try await summarizePlain(chunk, targetLanguage: targetLanguage, sentenceCount: 1))
        }
        let combined = partialSummaries.joined(separator: " ")
        // Task #122: always run `combined` through the structured
        // `summarize` — even when there was only a single chunk. Before
        // this fix, a single-chunk input returned `combined` (that one
        // chunk's own already-structured `summarize` output) directly,
        // skipping this call; now that the map step is unlabeled, skipping
        // it here would return a summary with no ■要約/■伝えたいこと/
        // ■アクション structure at all, breaking `summarizeLongText`'s
        // contract that its output always has that shape (same as the
        // un-chunked short-input path above). This combined text is itself
        // short (a handful of sentences) even for a huge source email, so
        // it's always safely under the chunk threshold — no risk of *this*
        // call recursing into another split.
        return try await summarize(combined, targetLanguage: targetLanguage, sentenceCount: sentenceCount)
    }

    /// Task #153 (スレッド全体のAI要約) → Task #160 (map段をメッセージ単位
    /// に固定) → Task #160フォローアップ (二重圧縮の根治) → Task #160
    /// フォローアップ2 (メタ言及調の除去) → Task #160フォローアップ3
    /// (仕上げ=refineパスの追加) → Task #160フォローアップ4 (■現状の
    /// ハルシネーション対策) → **Task #160フォローアップ5 (ユーザー指示
    /// 「スレッド要約の最終形への簡素化」、このdoc commentが現行の設計)**:
    ///
    /// これまでの経緯 (フォローアップ2〜4) は、いずれも
    /// 「per-messageの事実抽出結果を、モデルにもう一段読ませて何かを
    /// 書かせる」(旧`refineThreadEntries`の■経緯統合、旧
    /// `summarizeThreadDigest`の■現状生成) こと自体に起因する問題
    /// だった — 指示文の例文の題材が出力に漏れる、入力に無い後続アクション
    /// を作り出す、■現状が入力と無関係な内容になる、等。ユーザーの最終
    /// 判断は「その2段目自体が要らない」というもの: **per-messageの
    /// 事実抽出結果 (`summarizeThreadEntry`の出力) をそのまま時系列に
    /// 並べるだけ**が最終形になった。
    ///
    /// 現在の実装はシンプルな1段のmapのみ:
    /// `messages`の各メッセージについて`summarizeThreadEntry`(必ず削らず
    /// 書き出す事実抽出、`extractThreadEntryText(_:targetLanguage:)`
    /// 経由でチャンク安全網も適用) を1回ずつ呼び、
    /// `"\(header) \(extracted)"`という行を組み立てて**空行区切りで**
    /// 連結するだけ — reduce/refine段のモデル呼び出しは一切無い。
    /// `■経緯`/`■現状`のようなラベルも付けない (ラベルは2パート構造を
    /// 前提にしたUIだったが、今は単一の時系列リストなのでラベル自体が
    /// 不要になった)。これにより、旧reduce/refine段が持っていた
    /// 「モデルがもう一段何かを書く」ことに起因するあらゆるハルシネーション
    /// 経路が構造的に消える — 出力に含まれる文はすべて、いずれかの
    /// `summarizeThreadEntry`呼び出しが実際に返した文字列そのもの
    /// (+ アプリ側が組み立てたヘッダ) でしかあり得ない。
    ///
    /// `"[M/d] 差出人:"`ヘッダは、Task #160の設計をそのまま踏襲して
    /// **map段のモデル入力にもモデル出力にも含めない** —
    /// `summarizeThreadEntry`へ渡すのは`message.text`(新規本文) だけで、
    /// 出力の各行のヘッダは`message.header`(呼び出し元が信頼できる
    /// メタデータから組み立てた文字列) をこちら側で機械的に前置きする。
    /// 理由もTask #160と同じ: `summarizeThreadEntryInstructions`は
    /// 「差出人・宛先名を行為の主語にしない」設計のため、ヘッダをモデルへ
    /// の入力に混ぜるとその名前・日時をモデルが不確実な言い回しで本文に
    /// 混ぜて返すリスクがある。
    ///
    /// `onProgress`は「今n通目/m通中」だけを報告する — 旧
    /// `ThreadSummaryProgress`(`.extractingMessage`/`.refining`の2ケース)
    /// はrefine段の廃止に伴い不要になったので、Task #160時代の単純な
    /// `(current: Int, total: Int)`タプルに戻した。`@MainActor @Sendable`
    /// である理由は変わらない: `Optional`のクロージャ引数は暗黙に
    /// `@escaping`になる (`AccountSyncer.performInitialSync(auth:onProgress:)`
    /// の`onProgress`と同じ理由でSendable化が要る) 上、`@MainActor`も
    /// 付けることで`ThreadDetailView`(`View`、MainActor隔離) がこの
    /// クロージャを`self`キャプチャ込みでそのまま書けるようになる —
    /// `@MainActor`隔離自体が`Sendable`の求める安全性の裏付けになる。
    /// 呼び出し側 (下記) が`await`するのはこのため。
    public func summarizeThread(
        _ messages: [ThreadDigestMessage],
        targetLanguage: TranslationLanguage,
        onProgress: (@MainActor @Sendable (_ current: Int, _ total: Int) -> Void)? = nil
    ) async throws -> String {
        guard !messages.isEmpty else { return "" }

        var perMessageLines: [String] = []
        perMessageLines.reserveCapacity(messages.count)
        for (index, message) in messages.enumerated() {
            await onProgress?(index + 1, messages.count)
            let extracted = try await extractThreadEntryText(message.text, targetLanguage: targetLanguage)
            perMessageLines.append("\(message.header) \(extracted)")
        }
        // Task #160フォローアップ5: 各メッセージの行の間に空行を1行挟んで
        // 連結するだけ — reduce/refine段は無いので、これがそのまま最終的な
        // 出力になる。
        return perMessageLines.joined(separator: "\n\n")
    }

    /// The oversized-single-message safety net `summarizeThread(_:targetLanguage:onProgress:)`'s
    /// doc comment describes — chunks via `TranslationChunker` and calls
    /// `summarizeThreadEntry` once per chunk, exactly like
    /// `summarizeLongText`'s map step does for `summarizePlain`, but
    /// **does not** run the joined chunk results through one more model
    /// call the way `summarizeLongText`/Task #160's `compactThreadMessageText`
    /// did — that extra pass would itself be a second compression step,
    /// re-introducing the exact double-compression this whole redesign
    /// exists to remove. A simple concatenation of already-fact-preserving
    /// chunk extractions is the correct combination here. Ordinary messages
    /// (the overwhelming majority in practice) never enter this branch at
    /// all — a single `summarizeThreadEntry` call handles them.
    private func extractThreadEntryText(_ text: String, targetLanguage: TranslationLanguage) async throws -> String {
        guard text.count > TranslationChunker.defaultMaxChunkLength else {
            return try await summarizeThreadEntry(text, targetLanguage: targetLanguage)
        }

        let chunks = TranslationChunker.chunk(text)
        var parts: [String] = []
        parts.reserveCapacity(chunks.count)
        for chunk in chunks {
            parts.append(try await summarizeThreadEntry(chunk, targetLanguage: targetLanguage))
        }
        return parts.joined(separator: " ")
    }
}

/// Task #160: one thread message's map-stage input for
/// `TranslationService.summarizeThread(_:targetLanguage:onProgress:)` —
/// `header` (`"[<date>] <sender>:"`, already fully formatted by the caller
/// from trusted metadata) and `text` (that message's own new, non-quoted
/// body) travel separately so the map step can fact-extract `text` alone
/// (never showing the model `header`, see `summarizeThread`'s doc comment
/// for why), and the final output's per-message line is always
/// `"\(header) \(extracted facts)"`.
public struct ThreadDigestMessage: Sendable, Equatable {
    public let header: String
    public let text: String

    public init(header: String, text: String) {
        self.header = header
        self.text = text
    }
}
