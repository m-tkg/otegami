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

    /// Task #153 (スレッド全体のAI要約): the single, structured "reduce" call
    /// behind `summarizeThread`'s map-reduce (this method's own doc comment)
    /// — always produces exactly two `■`-prefixed sections, `■経緯`
    /// (chronological narrative) then `■現状` (current state), unlike
    /// `summarize`'s single-message 3-part ■要約/■伝えたいこと/■アクション
    /// shape. A sibling of `summarize`, not an overload of it: the two
    /// produce genuinely different output structures for genuinely
    /// different inputs (one message vs. a whole thread's digest), and
    /// giving them distinct names keeps a caller's intent explicit at every
    /// call site rather than relying on which overload got resolved.
    func summarizeThreadDigest(_ text: String, targetLanguage: TranslationLanguage) async throws -> String
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

    /// Task #153 (スレッド全体のAI要約) → Task #160 (実機フィードバック
    /// 2026-07-29「■経緯/■現状が短すぎるし内容も少し変」、ユーザー指示
    /// 「複数回 FoundationModel 実行していいから、時系列で経緯をまとめて
    /// 欲しい」): 元の実装 (git history 参照) は`TranslationChunker.chunk`
    /// の**文字数ベース**の境界でマップ段を回しており、短いスレッド
    /// (合計の新規本文が`TranslationChunker.defaultMaxChunkLength`未満)
    /// では丸ごと1回の`summarizeThreadDigest`呼び出しに委ねていた —
    /// 実機で6通のスレッドが「■経緯が合計5〜6文」にしかならなかった原因
    /// (`docs/translation.md`のTask #153節にある実FM確認ログ参照。文字数が
    /// 閾値を超えないかぎりメッセージ数に関係なくモデル呼び出しは常に1回
    /// だけだった)。
    ///
    /// この改修でマップ段を**メッセージ単位**に固定する:
    /// `TranslationChunker`の文字数境界はもう使わず、`messages`
    /// (`ThreadDigestMessage`、呼び出し元 — `ThreadDetailView
    /// .threadSummarySourceEntries()` — が時系列順に組み立てる配列) の
    /// 各要素を必ず1回ずつ`summarizePlain`へ個別に渡し、1-3文へ圧縮する。
    /// メッセージ数が多いほどモデル実行回数が増える (`onProgress`で「今
    /// n通目/m通中」を呼び出し元へ伝えられる — `ThreadDetailView`が生成中
    /// シートの進捗表示に使う) が、■経緯にスレッド内の**すべての**メッセ
    /// ージが最低1行分は反映されることが、文字数がどうであれ保証される。
    ///
    /// `"[日時] 差出人:"`ヘッダは**マップ段のモデル入力にもモデル出力にも
    /// 含めない** — `summarizePlain`へ渡すのは`message.text`(新規本文)
    /// だけで、reduce段 (`summarizeThreadDigest`) へ渡す各行のヘッダは常に
    /// `message.header`(呼び出し元が信頼できるメタデータから組み立てた
    /// 文字列) をこちら側で機械的に前置きする。`summarizePlainInstructions`
    /// は「本文中に差出人・宛先名が出てきても主語にせず『この返信』を
    /// 主語にする」設計 (Task #122/#134) のため、ヘッダをモデルへの入力に
    /// 混ぜるとその名前・日時をモデルが不確実な言い回しで本文に混ぜて
    /// 返す (二重に言及される、あるいは不正確に言い換えられる) リスクが
    /// ある — ヘッダをコード側で確定させることで、reduce段の指示文
    /// (`summarizeThreadInstructions`の【入力の構造】) が前提とする
    /// `"[日時] 差出人: 本文"`という行フォーマットを型として保証できる。
    ///
    /// 1メッセージの本文単体が`TranslationChunker.defaultMaxChunkLength`
    /// を超える場合だけ、`compactThreadMessageText(_:targetLanguage:)`
    /// (下記) が`summarizeLongText`と同じ安全網 (チャンク分割 → 各チャン
    /// クを`summarizePlain`で圧縮 → 結合してもう一度`summarizePlain`) を
    /// 通す — 通常のメッセージはこの分岐に入らない。
    ///
    /// `onProgress` is `@MainActor @Sendable`, not plain `@Sendable` — an
    /// `Optional` closure parameter is implicitly `@escaping` (a well-known
    /// Swift quirk), and an escaping closure crossing this `async` method's
    /// `await` points needs `Sendable` under strict concurrency
    /// (`AccountSyncer.performInitialSync(auth:onProgress:)`'s identical
    /// `@Sendable (Progress) -> Void)?` is the existing precedent for that
    /// half). Pinning it to `@MainActor` as well is what actually lets
    /// `ThreadDetailView` (a `View`, MainActor-isolated) form this closure
    /// as a plain non-`Sendable`-capture-of-`self` literal — `@MainActor`
    /// isolation is itself the safety proof `Sendable` asks for, so the two
    /// annotations together are strictly more permissive for the caller
    /// than `@Sendable` alone would be. Called with `await` below since
    /// this method itself has no actor affinity.
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
            let compact = try await compactThreadMessageText(message.text, targetLanguage: targetLanguage)
            perMessageLines.append("\(message.header) \(compact)")
        }
        let combined = perMessageLines.joined(separator: "\n")
        return try await summarizeThreadDigest(combined, targetLanguage: targetLanguage)
    }

    /// The oversized-single-message safety net `summarizeThread(_:targetLanguage:onProgress:)`'s
    /// doc comment describes — the same map-reduce shape `summarizeLongText`
    /// uses for a whole long mail, just scoped to one thread message's own
    /// text instead. Ordinary messages (the overwhelming majority in
    /// practice) never enter the chunking branch at all — a single
    /// `summarizePlain` call handles them.
    private func compactThreadMessageText(_ text: String, targetLanguage: TranslationLanguage) async throws -> String {
        guard text.count > TranslationChunker.defaultMaxChunkLength else {
            return try await summarizePlain(text, targetLanguage: targetLanguage, sentenceCount: 2)
        }

        let chunks = TranslationChunker.chunk(text)
        var partialSummaries: [String] = []
        partialSummaries.reserveCapacity(chunks.count)
        for chunk in chunks {
            partialSummaries.append(try await summarizePlain(chunk, targetLanguage: targetLanguage, sentenceCount: 1))
        }
        return try await summarizePlain(partialSummaries.joined(separator: " "), targetLanguage: targetLanguage, sentenceCount: 2)
    }
}

/// Task #160: one thread message's map-stage input for
/// `TranslationService.summarizeThread(_:targetLanguage:onProgress:)` —
/// `header` (`"[<date>] <sender>:"`, already fully formatted by the caller
/// from trusted metadata) and `text` (that message's own new, non-quoted
/// body) travel separately so the map step can summarize `text` alone
/// (never showing the model `header`, see `summarizeThread`'s doc comment
/// for why) while the reduce step still gets a `"\(header) \(compact
/// summary)"` line per message, exactly like `ThreadDetailView`'s previous
/// single joined-string input did.
public struct ThreadDigestMessage: Sendable, Equatable {
    public let header: String
    public let text: String

    public init(header: String, text: String) {
        self.header = header
        self.text = text
    }
}
