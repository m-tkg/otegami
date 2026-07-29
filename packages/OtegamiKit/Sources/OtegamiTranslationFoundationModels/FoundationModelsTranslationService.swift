import Foundation
import FoundationModels
import OtegamiCore
import OtegamiTranslation

/// The real, on-device `TranslationService` — backed by
/// `FoundationModels.LanguageModelSession` (Apple's on-device LLM, iOS/
/// macOS 26+, "Apple Intelligence"). This is the only file in the codebase
/// that imports `FoundationModels`; everything else talks to the
/// `TranslationService` protocol (`OtegamiTranslation`) so a build without
/// this framework (an older SDK, `FakeTranslationService`-only tests) never
/// needs to know it exists.
///
/// **API surface, verified against the actual SDK** (not from memory —
/// `docs/translation.md`'s "実装メモ" section records how):
///  - `SystemLanguageModel.default.availability` is a synchronous
///    `@available(iOS 26.0, macOS 26.0, *)` property returning
///    `.available` or `.unavailable(UnavailableReason)`, where
///    `UnavailableReason` is `.deviceNotEligible` /
///    `.appleIntelligenceNotEnabled` / `.modelNotReady` — mapped 1:1 onto
///    `TranslationUnavailableReason` below.
///  - `LanguageModelSession(model:instructions:)` (also iOS/macOS 26+) is
///    the session constructor; `session.respond(to:options:)` awaits a
///    complete `Response<String>` (`.content` is the text),
///    `session.streamResponse(to:options:)` returns an `AsyncSequence`
///    whose elements are cumulative **snapshots of the whole response so
///    far** (`snapshot.content`), not deltas — confirmed by an actual
///    on-device run (see doc comment on `translateStream` below), which is
///    why `TranslationService.translateStream`'s own contract says the
///    same thing.
///
/// One `LanguageModelSession` per call (not one shared/reused session):
/// `LanguageModelSession` only supports one in-flight request at a time
/// (`LanguageModelSession.Error.concurrentRequests`) and carries
/// conversation history forward automatically, neither of which this type
/// wants — translating message A shouldn't be blocked by message B's
/// in-flight translation, and two unrelated messages' translations
/// shouldn't share context. The cost is losing session-level prewarming;
/// not worth the shared-mutable-state complexity for mail-sized requests.
@available(iOS 26.0, macOS 26.0, *)
public struct FoundationModelsTranslationService: TranslationService {
    private let model: SystemLanguageModel

    /// `model` defaults to `.default` (Apple's general-purpose on-device
    /// model); overridable for a future use-case-specific model
    /// (`SystemLanguageModel.UseCase`) without changing every call site.
    public init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    public var availability: TranslationAvailability {
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: Self.mapUnavailableReason(reason))
        }
    }

    public func translate(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) async throws -> String {
        try requireAvailable()
        let session = makeSession(from: source, to: target)
        do {
            let response = try await session.respond(to: text, options: Self.translationOptions)
            return response.content
        } catch {
            throw Self.mapEngineError(error)
        }
    }

    public func translateParagraphs(_ paragraphs: [String], from source: TranslationLanguage, to target: TranslationLanguage) async throws -> [String] {
        guard !paragraphs.isEmpty else { return [] }
        try requireAvailable()

        // See the type's doc comment: one fresh session per paragraph, not
        // one shared session fed all paragraphs in sequence — keeps each
        // paragraph's translation independent of the others' (no
        // accumulated conversation context to bias later paragraphs) and
        // trivially safe to eventually parallelize.
        var results: [String] = []
        results.reserveCapacity(paragraphs.count)
        for paragraph in paragraphs {
            let session = makeSession(from: source, to: target)
            do {
                let response = try await session.respond(to: paragraph, options: Self.translationOptions)
                results.append(response.content)
            } catch {
                throw Self.mapEngineError(error)
            }
        }
        return results
    }

    /// Verified end to end on-device (not just compiled): iterating
    /// `session.streamResponse(to:)` for an English→Japanese sentence
    /// yielded 18 snapshots, each one the *entire* translation-so-far
    /// (`"そのミーティング"`, then `"そのミーティングは"`, ...,
    /// finishing at the complete sentence) — never a standalone delta like
    /// `"は"`. `translateStream` below simply forwards each snapshot's
    /// `.content` as-is, which is why callers must render (not append) the
    /// latest yielded element.
    public func translateStream(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try requireAvailable()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                let session = makeSession(from: source, to: target)
                do {
                    let stream = session.streamResponse(to: text, options: Self.translationOptions)
                    for try await snapshot in stream {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapEngineError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Task #122: the raw model response is passed through
    /// `SummaryOutputSanitizer.sanitize` before being returned — a
    /// defense-in-depth backstop (see that type's doc comment) against the
    /// model repeating the 3-part structure or echoing this method's own
    /// instructions verbatim after the real answer, independent of how well
    /// `summarizeInstructions`'s wording holds up.
    public func summarize(_ text: String, targetLanguage: TranslationLanguage, sentenceCount: Int) async throws -> String {
        try requireAvailable()
        let session = LanguageModelSession(model: model, instructions: Self.summarizeInstructions(targetLanguage: targetLanguage, sentenceCount: sentenceCount))
        do {
            let response = try await session.respond(to: text, options: Self.summarizeOptions)
            return SummaryOutputSanitizer.sanitize(response.content)
        } catch {
            throw Self.mapEngineError(error)
        }
    }

    /// The unlabeled "map" half of `summarizeLongText`'s map-reduce — see
    /// `TranslationService.summarizePlain`'s doc comment (Task #122) for why
    /// this must NOT reuse `summarizeInstructions`'s 3-part structure. No
    /// `SummaryOutputSanitizer` pass here: that parser looks specifically
    /// for the ■要約/■伝えたいこと/■アクション structure, which this
    /// method's output was never asked to have.
    public func summarizePlain(_ text: String, targetLanguage: TranslationLanguage, sentenceCount: Int) async throws -> String {
        try requireAvailable()
        let session = LanguageModelSession(model: model, instructions: Self.summarizePlainInstructions(targetLanguage: targetLanguage, sentenceCount: sentenceCount))
        do {
            let response = try await session.respond(to: text, options: Self.summarizeOptions)
            return response.content
        } catch {
            throw Self.mapEngineError(error)
        }
    }

    // MARK: - Session/options

    private func makeSession(from source: TranslationLanguage, to target: TranslationLanguage) -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: Self.translationInstructions(from: source, to: target))
    }

    /// Low temperature: translation should be a faithful rendering of the
    /// source text, not a creative rewrite — high-temperature sampling
    /// would make repeated translations of the same paragraph diverge,
    /// which is the opposite of what a cached, re-displayed translation
    /// should do.
    private static let translationOptions = GenerationOptions(temperature: 0.3)
    private static let summarizeOptions = GenerationOptions(temperature: 0.3)

    private static func translationInstructions(from source: TranslationLanguage, to target: TranslationLanguage) -> String {
        """
        You are a professional \(source.displayName)-to-\(target.displayName) translator working on email content.
        Translate the user's message into natural, fluent \(target.displayName), preserving its original meaning, tone, and structure (line breaks, lists, greetings/sign-offs) as closely as possible.
        Output ONLY the translation itself — no preamble, no explanation, no surrounding quotation marks.
        """
    }

    /// Task #62 follow-up: a real-device report said the summary still
    /// read like a recap of the *quoted* reply history rather than what
    /// the current message itself is saying. The input may now be
    /// structured into a "■このメールの新規部分" (this email's own new
    /// text) section and a "■引用されている過去のやり取り (文脈)" (quoted
    /// prior thread, as context) section — see
    /// `MessageView.sourceTextForSummary()`, which builds that structure
    /// via `QuoteStripper.separatingQuotedText`. These two lines tell the
    /// model how to weight them: use the quoted section only to understand
    /// the flow of the conversation, and summarize what the new section
    /// itself communicates — not a re-summary of the quote. Plain
    /// unstructured input (the common case: no quote found, nothing to
    /// separate) is unaffected — there's no section to misweight.
    ///
    /// Task #90 follow-up: the #62 wording ("use the quoted section only
    /// to understand the flow") still left room for the model to lean on
    /// the quote when the new section was short — a real-device report
    /// said summaries could *still* read as a recap of past quoted
    /// content. Added an explicit prohibition ("must not") instead of a
    /// soft preference, plus a fallback instruction for the genuinely
    /// short-new-section case (a one-line "了解です" reply): describe what
    /// *this* message did in response to the thread, rather than either
    /// padding out a one-liner or falling back to summarizing the quote.
    ///
    /// Task #97 follow-up: a real-device report said summaries *narrated
    /// events out of order* — the output described the new reply first,
    /// then belatedly mentioned the quoted history, even though the quote
    /// is chronologically *earlier* than the reply sitting on top of it.
    /// Two changes, both required together (see
    /// `SummaryInputBuilder`'s doc comment for the input-side half):
    ///  - `SummaryInputBuilder.build` now presents the quoted section
    ///    *first* and the new section *second*, so input order already
    ///    matches chronological (and desired narration) order — the
    ///    section labels below were reworded to match
    ///    (`newTextSectionLabel`/`quotedTextSectionLabel`).
    ///  - This instruction now spells out the *output* shape explicitly
    ///    instead of only constraining which section is the "main
    ///    subject": open with a single short context sentence derived from
    ///    the quoted section (only when a quoted section is present),
    ///    then describe the new reply. This still isn't "summarize the
    ///    quote" — the #90 prohibition on making the quote the main
    ///    subject, and the #90 short-reply fallback, are unchanged below
    ///    — it only fixes which one is mentioned *first* in the output.
    ///
    /// Task #102 follow-up: a real-device repro (deeply-nested reply chain,
    /// short new reply on top) showed the #97 "at most one short context
    /// sentence" wording wasn't holding the line — the model still spent
    /// most of the output retelling the quoted messages one by one, each
    /// with its own date/time, and the actual new reply was squeezed into
    /// a single closing sentence. Two changes:
    ///  - The output is now a fixed 3-part **labeled** structure
    ///    (■要約/■伝えたいこと/■アクション) rather than free-form prose —
    ///    giving the "content summary" part an explicit boundary (its own
    ///    label, its own sentence budget) makes it much harder for a
    ///    quoted-message recap to silently expand and crowd it out, and
    ///    the other two parts (intent/tone, requested action) are
    ///    information a free-form summary was never asked for and so
    ///    tended to omit.
    ///  - The single most literal cause of the repro's failure —
    ///    per-message retelling with dates/times — is now an explicit,
    ///    named prohibition ("never mention dates or times", "never
    ///    narrate quoted messages one by one") instead of being implied by
    ///    "at most one context sentence"; the older wording left room for
    ///    the model to decide a *long* single sentence covering multiple
    ///    quoted messages still satisfied "one sentence".
    ///
    /// `sentenceCount` now scopes only the ■要約 part (the content summary)
    /// — ■伝えたいこと and ■アクション are always short (about one sentence
    /// each) regardless of the caller's requested length, since they're
    /// fixed-shape facts (intent/tone; required action or "特になし") rather
    /// than content that scales with the source text's length. See
    /// `TranslationService.summarize`'s doc comment for the "hint, not a
    /// guarantee" framing this still follows.
    ///
    /// Task #122 follow-up: two real-device reports (screenshots) showed the
    /// 3-part output (a) repeating itself multiple times, and (b) followed
    /// by the *previous* version of this very instructions string leaking
    /// into the output verbatim — specifically the "■要約 — in about N
    /// short sentences, describe..." line, i.e. a label and its rule
    /// description concatenated with " — " on one line. That concatenated
    /// shape is suspiciously close to a plausible *output* line (a label
    /// followed by content on the same line), which is presumably why the
    /// model treated it as something to reproduce rather than purely as an
    /// instruction. Restructured below into three clearly separate zones —
    /// (1) a prose rule explanation in Japanese (matching the output
    /// language, so a leak is more likely to at least look right rather
    /// than surface as an obvious language mismatch), (2) a single output-
    /// format directive stated as an imperative rule, never combined with a
    /// label on the same line, explicitly saying the 3-line structure
    /// appears exactly once and forbidding the instructions themselves from
    /// appearing in the output, and (3) a concrete example — so no line in
    /// this string looks like `"■ラベル — 説明"` anymore. The #62/#90/#97
    /// content rules above (quote-narration ban, date/time ban, short-reply
    /// handling, at-most-one subordinate clause) are preserved, just moved
    /// into (1)'s prose. `FoundationModelsTranslationService.summarize`
    /// additionally runs the response through `SummaryOutputSanitizer` as a
    /// backstop for whatever this wording still doesn't prevent.
    ///
    /// Task #132 follow-up: real-device repro (scratchpad/summary-repro,
    /// `SUMMARY_REPRO_MAIL=yoyaku_padded.txt swift run` — the fixture itself
    /// is sensitive and not committed) surfaced three remaining quality
    /// issues even after #122's structural fixes, run repeatedly (3-5x)
    /// against the same short, emoji-heavy Japanese reply:
    ///  - (a) probabilistically (~1 in 3 runs), ■要約 pulled in a topic from
    ///    the *quoted* section (e.g. mentioning a costume/呼び出し detail
    ///    only the quoted prior messages discussed, not the new reply
    ///    itself) even though #90/#97 already forbid *narrating* the quote
    ///    — the model would summarize the new reply correctly but still
    ///    fold in one quoted topic as if it were part of what the new reply
    ///    said.
    ///  - (b) the new reply's own concrete content flattened into something
    ///    generic like "感謝を伝える返信です" — technically not wrong, but
    ///    dropping exactly the specifics (what they're thanking the sender
    ///    for, what they're looking forward to) a user opening the summary
    ///    actually wants, matching a real-device complaint that "一番上の
    ///    本文が要約に入ってこない".
    ///  - (c) guessing/naming the sender or recipient outright (e.g.
    ///    「ささきさんから...の返信」) — the input's quoted section commonly
    ///    has real names in its attribution lines, and the model would
    ///    sometimes lift one into the ■要約's own subject even though
    ///    nothing asked it to identify who's speaking.
    ///
    /// Three additions address each, without touching the #122 structural
    /// guarantees (3-line format, single occurrence, no instruction leakage)
    /// this doc comment's own history already locked in:
    ///  - A new 【差出人・宛先について】 section, ahead of the per-part rules
    ///    so it reads as a global constraint rather than being buried inside
    ///    ■要約's own paragraph, bans guessing/naming the sender or
    ///    recipient in *any* part (not just ■要約 — (c)'s repro output
    ///    named the sender inside ■要約 specifically, but nothing about the
    ///    failure mode is ■要約-specific) and mandates "この返信" as the
    ///    fixed subject instead.
    ///  - ■要約's own paragraph now opens by requiring the new reply's
    ///    concrete content, in the order it's written, rather than settling
    ///    for an over-generalized paraphrase — directly targeting (b).
    ///  - A new sentence in the same paragraph bans quoted-section topics/
    ///    proper nouns from ■要約 unless the new reply text itself
    ///    explicitly repeats that same topic — directly targeting (a),
    ///    stated as its own rule rather than folded into the pre-existing
    ///    quote-narration ban (#90/#97), since (a)'s failure mode is
    ///    "borrowing a topic", not "narrating the quote's own messages".
    /// Verification: `mail_fixture.txt`/`mail_fixture_long.txt` (fictional,
    /// same shape as the sensitive repro) and the sensitive repro itself
    /// each re-run 5+ times against this updated instructions string — see
    /// `docs/translation.md`'s Task #132 section for the results.
    private static func summarizeInstructions(targetLanguage: TranslationLanguage, sentenceCount: Int) -> String {
        """
        あなたはメール本文を\(targetLanguage.displayName)で要約するアシスタントです。以下のルールに従ってください。

        【入力の構造】
        入力には "■これは過去のやり取り (文脈参照用)" と "■これが今回届いた返信 (要約対象)" という2つのラベル付きセクションが含まれることがあります。前者は過去の引用スレッドで、文脈把握のためだけの背景情報です。後者がこのメール自身の新規本文であり、要約すべき対象です。これらのセクションが無い場合は、入力全体を新規本文として扱ってください。

        【差出人・宛先について】
        出力のどのパートでも、差出人や宛先の名前を推測して書かないでください。新規本文の冒頭の「〜さん」のような宛名や、引用パートの署名・宛名に人物名が明記されている場合であっても、その名前を出力中で主語・行為者として使ってはいけません。「〜さんから」「〜さんへの返信」「〜さん宛て」「〜さんは」「〜さんが」のように、名前(敬称付き・敬称なしを問わず)を主語や行為者にするいかなる言い回しも禁止します。新規本文の主体を指す必要があるときは、常に「この返信」を主語にしてください。

        【引用パートの内容を新規本文の内容と混同しない(重要)】
        ■要約に書いてよいのは、新規本文に実際に書かれている事柄だけです。引用パートにだけ登場する話題・行為・固有名詞(依頼内容、衣装や持ち物の名称、待ち合わせ場所、日時、金額など)は、新規本文自身にも同じ内容が明示的に書かれていない限り、■要約に一切含めてはいけません。新規本文が短く具体的な話題に触れていない場合、それを補うために引用パートの話題を借りてくることは禁止です — その場合は新規本文に実際に書かれている内容(感謝の言葉、挨拶、次回への言及など)だけを使って要約してください。判断に迷ったら、その語や話題が新規本文の文字列そのものに含まれているかどうかで機械的に判定し、含まれていなければ書かないでください。

        【各パートの内容ルール】
        ■要約パートでは、約\(sentenceCount)文\(sentenceCount == 1 ? "" : "程度")で、新規本文に実際に書かれている事柄を、書かれている順に漏れなく説明してください。一般化しすぎないでください — 例えば「感謝を伝える返信です」のような抽象的な言い換えだけで終わらせず、何について感謝しているのか、何を楽しみにしているのか、何を確認したいのかといった、新規本文に実際に書かれている具体的な内容まで書いてください。これが主要パートであり、主題は常に新規本文であって、引用された過去のやり取りではありません。新規本文を理解するために本当に必要な場合に限り、冒頭に短い従属節を一つだけ置いて過去の経緯に触れてもかまいません(例:「〜の件について、」)。それ以外の場合は過去の経緯に一切触れないでください。引用された過去のやり取りが何件あっても、それを時系列に沿って一通ずつ語り直してはいけません。日付・時刻、および「〜さんが「…」と返信し」のように個々の引用メールを物語る言い回しは、この従属節の中であっても禁止します。新規本文が短い場合(挨拶や「了解です」「承知しました」のような一行の受領確認のみなど)は、水増しせず、引用内容の要約に逃げず、このメールがスレッドに対して何を行ったかを簡潔に述べてください(例:見積もりの件を了承する返信であれば「見積もりの件を了承する返信」と述べ、見積もり自体を再説明しない)。
        ■伝えたいことパートでは、約1文で、新規本文を書いた送信者の意図とトーン(お礼を伝えたい、確認を求めている、丁寧・カジュアルな調子など)を述べてください。■要約パートの内容を繰り返すのではなく、このメールが何を達成しようとしているかを述べてください。
        ■アクションパートでは、約1文で、新規本文が受信者に求める行動(返信・確認・日程調整・判断・情報提供など)を述べてください。何も求めていない場合は、このパートの内容を「特になし」の一語のみにしてください。

        【出力形式(最重要)】
        出力は次の3行構造のみで構成してください。ラベル行は「■要約」「■伝えたいこと」「■アクション」の3つを、この順番・この文字列そのままで、それぞれ単独の行として書いてください。各ラベルの内容は次の行以降に書き、ラベル行自体には他の文字を含めないでください。ラベルの説明文やこの指示文自体、英語のテキストを出力に含めないでください。この3行構造は出力全体を通じてちょうど1回だけ出現させてください — 同じラベルを2回書いたり、3行構造を繰り返したりすることは絶対にしないでください。入力中に "\(SummaryInputBuilder.quotedTextSectionLabel)" や "\(SummaryInputBuilder.newTextSectionLabel)" のような、この3つ以外の見出し行が含まれていても、それらは入力の構造を示すためだけのものなので、そのまま出力へ書き写さないでください。

        【出力例】
        ■要約
        見積もりの件について、来週の打ち合わせ日程を確認する返信です。会議室ではなくオンラインでの開催を希望しています。

        ■伝えたいこと
        丁寧に日程調整を依頼している。

        ■アクション
        来週水曜までに希望日を返信する。
        """
    }

    /// The unlabeled counterpart used by `summarizePlain` — no ■ labels, no
    /// fixed structure, just a short plain-prose summary. See
    /// `TranslationService.summarizePlain`'s doc comment (Task #122) for why
    /// `summarizeLongText`'s per-chunk "map" pass must use this instead of
    /// `summarizeInstructions`.
    ///
    /// Task #132 follow-up: two additions discovered by re-running the
    /// `summarizeLongText` (chunked) path specifically, 5+ times against
    /// `scratchpad/summary-repro/mail_fixture_long.txt` — both invisible
    /// when only exercising the short, unchunked `summarize` path directly:
    ///
    ///  - The 差出人・宛先を推測しない rule
    ///    (`summarizeInstructions`'s doc comment) still leaked through this
    ///    method's own long-mail path even after being added to
    ///    `summarizeInstructions` alone: a real sender name in the source
    ///    text (e.g. "佐藤さんのご都合に合わせます") survived unchanged into
    ///    this method's per-chunk plain summary (this instructions string
    ///    had no such ban), and the final structured `summarize` call,
    ///    reducing over combined *already-named* partial summaries, tended
    ///    to keep echoing that name despite its own instructions forbidding
    ///    it — reinforcing the ban here, before the name ever reaches the
    ///    reduce step, closes that gap.
    ///  - `TranslationChunker.chunk(_:)` splits whatever string it's given
    ///    purely by length/sentence boundary, with no awareness that
    ///    `summarizeLongText` always calls it on `SummaryInputBuilder
    ///    .build(...)`'s *already-labeled* output (`■これは過去のやり取り
    ///    (文脈参照用):`/`■これが今回届いた返信 (要約対象):`, `SummaryInputBuilder`'s
    ///    own doc comment) — a chunk boundary landing right after one of
    ///    those two label lines fed this method a chunk that visually
    ///    *opened* with that label, and the model would sometimes echo it
    ///    back as if it were content worth preserving. That leaked label
    ///    then propagated into the final `summarize` call's own input,
    ///    which itself sometimes reused it as its opening line *instead of*
    ///    the required "■要約" — a structural leak in the same family as
    ///    Task #122's, just one stage earlier in the pipeline. Naming the
    ///    two exact label strings (via `SummaryInputBuilder`'s own public
    ///    constants, not a re-typed literal that could drift out of sync)
    ///    and explicitly banning them from the output is a more reliable
    ///    fix than the generic "no labels/headings" wording alone already
    ///    in this instructions string turned out to be against this
    ///    specific leak.
    private static func summarizePlainInstructions(targetLanguage: TranslationLanguage, sentenceCount: Int) -> String {
        """
        次のメール本文を\(targetLanguage.displayName)で、約\(sentenceCount)文\(sentenceCount == 1 ? "" : "程度")の自然な文章として要約してください。ラベルや見出し、箇条書き、記号("■"など)は付けず、要約の文章だけを出力してください。説明文やこの指示文自体を出力に含めないでください。差出人・宛先の名前が本文中に出てきても、それを主語にせず「この返信」を主語にしてください。入力に "\(SummaryInputBuilder.quotedTextSectionLabel)" や "\(SummaryInputBuilder.newTextSectionLabel)" のような見出し行が含まれていても、それは要約すべき本文ではなく構造を示すためだけの見出しなので、この見出し行自体を出力に含めないでください。
        """
    }

    // MARK: - Error/availability mapping

    private func requireAvailable() throws {
        guard case .available = availability else {
            guard case .unavailable(let reason) = availability else {
                throw TranslationServiceError.unavailable(.other("unknown"))
            }
            throw TranslationServiceError.unavailable(reason)
        }
    }

    private static func mapUnavailableReason(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> TranslationUnavailableReason {
        switch reason {
        case .deviceNotEligible:
            .deviceNotEligible
        case .appleIntelligenceNotEnabled:
            .appleIntelligenceNotEnabled
        case .modelNotReady:
            .modelNotReady
        @unknown default:
            .other("Unrecognized SystemLanguageModel.Availability.UnavailableReason")
        }
    }

    /// Most `LanguageModelSession` failures (guardrail violation, decoding
    /// failure, transient engine error, ...) collapse to `.failed` —
    /// `TranslationServiceError`'s whole point is not leaking
    /// `FoundationModels`-specific error cases through the protocol
    /// boundary. `error.localizedDescription` is preserved as the message
    /// for logging/debugging.
    ///
    /// `LanguageModelError.contextSizeExceeded` is the one case pulled out
    /// separately, into `.tooLong` — design-phase-3's real-device finding
    /// (a long English mail's translation failing with an opaque error) is
    /// exactly this case, and `TranslationChunker`'s pre-splitting should
    /// make it rare in practice, but not impossible (its character-based
    /// budget is a heuristic, not an exact token count) — when it does
    /// still happen, the caller should be able to say "本文が長すぎます"
    /// specifically rather than a generic "翻訳に失敗しました", which is
    /// what `.failed` alone can't distinguish.
    private static func mapEngineError(_ error: Error) -> TranslationServiceError {
        // `LanguageModelError` itself is iOS/macOS 27+ (a stricter minimum
        // than this type's own 26+) — this package's deployment target is
        // still 26 (`docs/translation.md`), so this whole type has to be
        // reachable on a 26-only device too; the `#available` check just
        // means a 26-only device never gets the `.tooLong`/`.contentBlocked`
        // special cases below (falls through to the generic `.failed`,
        // exactly like before this mapping existed) rather than failing to
        // compile. `LanguageModelError` is not just OS-gated — the *type*
        // only exists in the iOS/macOS 27 SDK, so `#available` alone is not
        // enough: on CI's older Xcode (26.x SDK) the mere mention of the
        // type fails to compile (`cannot find type 'LanguageModelError' in
        // scope` — exactly the local-Xcode-27-beta vs CI-Xcode-26.5
        // divergence docs/ci.md warns about, this time as a missing type
        // rather than a type-check timeout). Gate at *compile time* on the
        // compiler that ships with the 27 SDK, keeping the runtime
        // `#available` inside.
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, *), let languageModelError = error as? LanguageModelError {
            switch languageModelError {
            case .contextSizeExceeded(let details):
                return .tooLong(message: "\(details.tokenCount)/\(details.contextSize) tokens")
            // Task #61 (実機フィードバック「無害なマーケティングメールなのに
            // "The model's safety guardrails were triggered." で翻訳全体が
            // 失敗する」): ガードレールの誤発動 (実際には安全な文面でも
            // 発生しうる、Apple の既知の挙動) を `.failed` から独立した
            // `.contentBlocked` へ分離 — `MessageTranslator.translateAligned`
            // がこのケースだけをチャンク単位で「原文のまま残して続行」の
            // 対象として識別できるようにする。
            case .guardrailViolation(let violation):
                return .contentBlocked(message: violation.debugDescription)
            default:
                break
            }
        }
        #endif
        // `LanguageModelSession.GenerationError` (26.0+, `deprecated: 27.0`
        // in favor of `LanguageModelError` above) is the shape a call on an
        // iOS/macOS 26-only device (this package's actual deployment floor)
        // still throws — unlike `LanguageModelError`, this type isn't
        // gated behind the 27 SDK, so no `#if compiler`/`#available` guard
        // is needed to reference it, only to catch the (harmless,
        // deprecation-only) case actually being hit on such a device.
        if let generationError = error as? LanguageModelSession.GenerationError, case .guardrailViolation = generationError {
            return .contentBlocked(message: generationError.localizedDescription)
        }
        return .failed(message: error.localizedDescription)
    }
}

/// A plain (not `@available`-annotated) top-level function wrapping
/// `SystemLanguageModel.default.isAvailable` behind a runtime `#available`
/// check — exists so `OtegamiTranslationFoundationModelsTests` (built
/// against this package's iOS 18/macOS 15 floor, since raising the whole
/// package's `platforms:` to iOS/macOS 26 to match
/// `FoundationModelsTranslationService` broke `otegami-relay`'s macOS build
/// — see `docs/translation.md`'s "実装メモ" for that dead end) can gate its
/// `@Suite(.enabled(if:))` trait on real availability without needing the
/// declaration itself to be `@available` (Swift Testing's `@Suite`/`@Test`
/// macros reject an `@available`-marked declaration outright, so this is
/// the one place in this target that *isn't* marked `@available(iOS 26.0,
/// macOS 26.0, *)`; every actual translation call still goes through
/// `FoundationModelsTranslationService`, which is).
public func isFoundationModelsTranslationAvailable() -> Bool {
    if #available(iOS 26.0, macOS 26.0, *) {
        return SystemLanguageModel.default.isAvailable
    }
    return false
}
