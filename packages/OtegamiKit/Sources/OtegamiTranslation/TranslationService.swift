import Foundation

/// `TranslationService.summarizeThread(_:targetLanguage:onProgress:)`'s
/// threshold below which the `refineThreadEntries` polish pass is skipped
/// entirely (task spec: "3通以下の短いスレッドは refine パスをスキップ") —
/// a thread this short is already close to as compact as a refined one
/// would be, so the extra model call isn't worth its latency. A file-scope
/// `let` rather than a `static let` on the protocol extension itself:
/// Swift doesn't support stored static properties in protocol extensions
/// (no storage location to put them in).
private let threadEntryRefinementSkipThreshold = 3

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

    /// Task #153 (スレッド全体のAI要約) → Task #160フォローアップ (実機フィードバック
    /// 「スレッド要約が雑すぎて内容がほとんど抜け落ちている」、二重圧縮の
    /// 根治): 元々は`■経緯`(時系列の経緯) と`■現状`(現在の状態) の2パート
    /// を1回のモデル呼び出しでまとめて生成していたが、reduce段でモデルが
    /// per-message の抽出結果をもう一度圧縮してしまい (map段の圧縮と合わせ
    /// て二重圧縮)、具体的な内容 (数値・固有名詞・決定事項) が経緯から
    /// 抜け落ちる原因になっていた。Task #160フォローアップでこのメソッドの役割を
    /// `■現状`(このスレッドが最終的にどうなったか・未決事項・次のアク
    /// ション、2〜4文) 1パートだけへ縮小した — `■経緯`は
    /// `summarizeThread`がこのメソッドを一切通さず、`summarizeThreadEntry`
    /// (このprotocolの別のrequirement) の結果をアプリ側でそのまま時系列に
    /// 並べるだけになった (`summarizeThread`のdoc comment参照) ので、
    /// reduce段の情報損失はここでは原理的に発生しない。
    ///
    /// このメソッドは今も`summarize`とは別名・別シグネチャの
    /// sibling — 出力が単一メッセージの3パート`summarize`とも、以前の
    /// 2パート版とも異なる、`■現状`1パートだけの構造化出力である点は
    /// 変わらない。
    func summarizeThreadDigest(_ text: String, targetLanguage: TranslationLanguage) async throws -> String

    /// Task #160フォローアップ (二重圧縮の根治): `summarizeThread`のmap段 — 各メッセージ
    /// の新規本文から、削らずに具体的な内容(決定事項・依頼/質問・数値・
    /// 日付・固有名詞)を書き出す「事実抽出」。`summarizePlain`(こちらは
    /// 「圧縮」— 内容を削ってでも短くすることが目的) とは目的が正反対な
    /// ので使い分ける: `summarizePlain`をそのまま流用すると、その指示文
    /// 自体が「短く」を最優先しており、具体的な数値・固有名詞が真っ先に
    /// 削られる (実機報告の直接の原因)。出力は`summarize`/
    /// `summarizeThreadDigest`と違いラベルなしの地の文 — `summarizePlain`
    /// と同じく`SummaryOutputSanitizer`を通さない (ラベル構造が無いので
    /// 対象外)。
    func summarizeThreadEntry(_ text: String, targetLanguage: TranslationLanguage) async throws -> String

    /// Task #160フォローアップ3 (ユーザー要望「要約済みのものを再度読ませて
    /// さらに要約を挟ませて、もう少しシンプルにする」): an optional
    /// "polish" pass between `summarizeThreadEntry`'s per-message facts and
    /// the final `■経緯` — `summarizeThread`'s doc comment has the full
    /// rationale for why this is safe from the Task #160フォローアップ
    /// double-compression bug (this consolidates already-extracted facts;
    /// it never re-reads raw mail bodies). `text` is the same header-
    /// prefixed, newline-joined per-message lines `summarizeThreadDigest`
    /// (■現状) also reads. Output starts with the `ThreadDigestLabel
    /// .progress` label on its own first line (mirrors `summarizeThreadDigest`'s
    /// own `ThreadDigestLabel.currentStatus`-first contract) followed by
    /// however many condensed, chronological lines it collapsed the input
    /// into — unlike the per-message input lines, these no longer carry a
    /// `"[date] sender:"` bracket prefix (a merged line can span several
    /// original messages/dates/senders, so a single bracket wouldn't fit;
    /// real names drawn only from the input are used inline instead when
    /// attribution is needed).
    func refineThreadEntries(_ text: String, targetLanguage: TranslationLanguage) async throws -> String
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
    /// に固定) → Task #160フォローアップ (実機フィードバック「スレッド要約
    /// が雑すぎて内容がほとんど抜け落ちている」、**二重圧縮の根治**):
    /// Task #160はmap段を「文字数ベースのチャンク」から「メッセージ単位」
    /// へ固定したが、それでも情報が抜け落ちる報告が続いた — 原因は
    /// **二重圧縮**だった。(a) map段の`summarizePlain`は「短く」を最優先
    /// する圧縮指示のため、具体的な数値・固有名詞・決定事項を真っ先に削る
    /// (これ自体は単一メッセージの`summarizeLongText`が求める挙動として
    /// 正しい)。(b) それでもなお、reduce段 (`summarizeThreadDigest`) が
    /// 「per-message圧縮結果をまとめて経緯を書く」ため、もう一段モデルが
    /// 圧縮し直していた。2段とも「短くする」方向のモデル呼び出しが直列に
    /// 並んでいれば、情報が生き残る保証はどこにも無い。
    ///
    /// この改修で構造を作り替えた:
    ///
    /// 1. **map段: 圧縮(`summarizePlain`)ではなく事実抽出
    ///    (`summarizeThreadEntry`)** — 新設の`summarizeThreadEntry`(この
    ///    protocolの別のrequirement) は「削らずに書き出す」指示なので、
    ///    決定事項・依頼/質問・数値・日付・固有名詞が生き残る。
    /// 2. **■経緯はモデルで再圧縮しない** — 各メッセージの抽出結果を
    ///    `message.header`(`"[M/d] 差出人:"`) と結合した行を、時系列の
    ///    まま**そのままアプリ側で**箇条書きに整形する。ここにreduce段の
    ///    モデル呼び出しは一切挟まらないので、原理的に情報損失が起きない
    ///    — これが「二重圧縮の根治」の核心。
    /// 3. **■現状だけモデル1回** — 抽出結果全体 (箇条書きと同じ`combined`)
    ///    を入力に、`summarizeThreadDigest`(役割を「■現状のみ生成」へ縮小
    ///    済み、そちらのdoc comment参照) を1回だけ呼ぶ。
    ///
    /// `"[M/d] 差出人:"`ヘッダは、Task #160の設計をそのまま踏襲して
    /// **map段のモデル入力にもモデル出力にも含めない** —
    /// `summarizeThreadEntry`へ渡すのは`message.text`(新規本文) だけで、
    /// ■経緯の箇条書き・reduce段への入力どちらの行も`message.header`
    /// (呼び出し元が信頼できるメタデータから組み立てた文字列) をこちら側
    /// で機械的に前置きする。理由もTask #160と同じ:
    /// `summarizeThreadEntryInstructions`は「差出人・宛先名を行為の主語に
    /// しない」設計のため、ヘッダをモデルへの入力に混ぜるとその名前・日時を
    /// モデルが不確実な言い回しで本文に混ぜて返すリスクがある。
    ///
    /// 1メッセージの本文単体が`TranslationChunker.defaultMaxChunkLength`
    /// を超える場合だけ、`extractThreadEntryText(_:targetLanguage:)`
    /// (下記) がチャンク分割の安全網を通す — ただし`summarizeLongText`/
    /// Task #160の`compactThreadMessageText`と違い、チャンクをまとめて
    /// もう一度モデルへ通す「再圧縮」はしない (それ自体が二重圧縮の一種
    /// になるため) — 各チャンクの抽出結果をそのまま連結するだけ。通常の
    /// メッセージはこの分岐に入らない。
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
    ///
    /// Task #160フォローアップ3 (ユーザー要望「要約済みのものを再度読ませて
    /// さらに要約を挟ませて、もう少しシンプルにする」): after the map step
    /// builds `combined` exactly as before, an optional third pass —
    /// `refineThreadEntries` — now runs over `combined` to condense it into
    /// fewer, chronological lines before it becomes the displayed `■経緯`
    /// (`summarizeThreadDigest`'s `■現状` call still reads the *un*-refined
    /// `combined`, unchanged from Task #160フォローアップ — the "現行どおり"
    /// this feature's own spec asked for). This is deliberately **not** a
    /// third compressing pass over raw content (which is what Task #160
    /// フォローアップ's whole redesign eliminated) — `combined` is already
    /// every message's own extracted facts, so refining it is a
    /// consolidation of already-fact-preserving text, one level up from
    /// "compress the raw email", not a re-run of the same lossy operation.
    ///
    /// Two guards keep this pass from ever being the reason a summary
    /// fails or gets thinner than before:
    ///  - **Skipped entirely for `messages.count <=
    ///    threadEntryRefinementSkipThreshold`** — a short thread's
    ///    unrefined per-message bullet list is already about as short as a
    ///    "refined" one would be, so there's nothing worth spending an
    ///    extra model call to condense.
    ///  - **Falls back to the unrefined `combined`(with the `■経緯` label
    ///    prepended by this method itself, exactly like the pre-refine
    ///    behavior) if `refineThreadEntries` throws** — a transient model
    ///    error during this optional polish pass must never turn an
    ///    otherwise-successful summary into a thrown error the user sees as
    ///    total failure.
    public func summarizeThread(
        _ messages: [ThreadDigestMessage],
        targetLanguage: TranslationLanguage,
        onProgress: (@MainActor @Sendable (_ event: ThreadSummaryProgress) -> Void)? = nil
    ) async throws -> String {
        guard !messages.isEmpty else { return "" }

        var perMessageLines: [String] = []
        perMessageLines.reserveCapacity(messages.count)
        for (index, message) in messages.enumerated() {
            await onProgress?(.extractingMessage(current: index + 1, total: messages.count))
            let extracted = try await extractThreadEntryText(message.text, targetLanguage: targetLanguage)
            perMessageLines.append("\(message.header) \(extracted)")
        }
        let combined = perMessageLines.joined(separator: "\n")

        let progressSection: String
        if messages.count > threadEntryRefinementSkipThreshold {
            await onProgress?(.refining)
            do {
                progressSection = try await refineThreadEntries(combined, targetLanguage: targetLanguage)
            } catch {
                // Best-effort: an unrefined `■経緯` is still a correct,
                // complete summary — only this optional polish pass is
                // lost, not the whole feature.
                progressSection = "\(ThreadDigestLabel.progress)\n\(combined)"
            }
        } else {
            progressSection = "\(ThreadDigestLabel.progress)\n\(combined)"
        }

        // Task #160フォローアップ: `summarizeThreadDigest`(■現状) always
        // reads the *un*-refined `combined` — never `progressSection` —
        // regardless of whether the refine pass ran, succeeded, or was
        // skipped. See this method's own doc comment on why that's
        // unchanged from before this pass existed.
        let currentStatus = try await summarizeThreadDigest(combined, targetLanguage: targetLanguage)
        return "\(progressSection)\n\n\(currentStatus)"
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

/// Task #160フォローアップ (二重圧縮の根治): the `■経緯`/`■現状` label
/// strings shared between `TranslationService.summarizeThread(_:targetLanguage:onProgress:)`
/// (which prepends `progress` itself, in code, never asking a model to
/// produce it) and `FoundationModelsTranslationService`'s
/// `summarizeThreadDigest` instructions/`SummaryOutputSanitizer
/// .sanitize(_:labels:)` call (which asks the model for exactly
/// `currentStatus`) — kept in one place, in this lower-level target, so the
/// two can never drift out of sync with each other (`FoundationModelsTranslationService`
/// already depends on this target, never the other way around).
public enum ThreadDigestLabel {
    public static let progress = "■経緯"
    public static let currentStatus = "■現状"
}

/// Task #160フォローアップ3: `summarizeThread(_:targetLanguage:onProgress:)`'s
/// progress events — a plain `(current: Int, total: Int)` pair (Task #160's
/// original shape) could only describe "which message is being extracted",
/// with no way to signal that the run has moved into the `refineThreadEntries`
/// polish pass afterward. `ThreadDetailView`'s generating sheet switches on
/// this to show either "n/m 通目を要約中…" or "仕上げ中…".
public enum ThreadSummaryProgress: Sendable, Equatable {
    case extractingMessage(current: Int, total: Int)
    case refining
}

/// Task #160: one thread message's map-stage input for
/// `TranslationService.summarizeThread(_:targetLanguage:onProgress:)` —
/// `header` (`"[<date>] <sender>:"`, already fully formatted by the caller
/// from trusted metadata) and `text` (that message's own new, non-quoted
/// body) travel separately so the map step can fact-extract `text` alone
/// (never showing the model `header`, see `summarizeThread`'s doc comment
/// for why) while both the app-built `■経緯` bullet list and the `■現状`
/// reduce step's input still get a `"\(header) \(extracted facts)"` line
/// per message (Task #160フォローアップ renamed this from "compact
/// summary" to "extracted facts" — same struct shape, different map-step
/// contract).
public struct ThreadDigestMessage: Sendable, Equatable {
    public let header: String
    public let text: String

    public init(header: String, text: String) {
        self.header = header
        self.text = text
    }
}
