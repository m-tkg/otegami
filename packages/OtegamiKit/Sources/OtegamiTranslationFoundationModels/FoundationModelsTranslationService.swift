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

    /// Task #153 (スレッド全体のAI要約) → Task #160フォローアップ (二重圧縮
    /// の根治、`TranslationService.summarizeThreadDigest`のdoc comment
    /// 参照): `TranslationService.summarizeThread`のreduce段 — 以前は
    /// `■経緯`/`■現状`の2パートを1回のモデル呼び出しでまとめて生成して
    /// いたが、今は`■現状`(このスレッドが最終的にどうなったか・未決事項・
    /// 次のアクション、2〜4文) 1パートだけを`currentStatusInstructions`
    /// で要求する — `■経緯`はモデルに一切書かせない
    /// (`summarizeThread`が`summarizeThreadEntry`の結果をアプリ側でそのまま
    /// 並べるだけになったため)。`summarize`と同じ理由 (Task #122の防御) で
    /// モデルの生応答をそのまま返さず、`SummaryOutputSanitizer
    /// .sanitize(_:labels:)`を`■現状`1ラベルだけで通す — 単一ラベルでも
    /// このメソッドの「複数ラベルの反復・指示文リーク検出」ロジックは
    /// そのまま機能する (`SummaryOutputSanitizer`のdoc comment参照)。
    public func summarizeThreadDigest(_ text: String, targetLanguage: TranslationLanguage) async throws -> String {
        try requireAvailable()
        let session = LanguageModelSession(model: model, instructions: Self.currentStatusInstructions(targetLanguage: targetLanguage))
        do {
            let response = try await session.respond(to: text, options: Self.summarizeOptions)
            return SummaryOutputSanitizer.sanitize(response.content, labels: [ThreadDigestLabel.currentStatus])
        } catch {
            throw Self.mapEngineError(error)
        }
    }

    /// Task #160フォローアップ (二重圧縮の根治): `TranslationService
    /// .summarizeThread`のmap段 — `summarizeThreadEntryInstructions`の
    /// doc comment参照。`summarizePlain`と同様ラベルなしの地の文なので
    /// `SummaryOutputSanitizer`は通さない。文数の目安は`text`自体の長さで
    /// 動的に変える (「長いメッセージは文数上限を緩める」— タスク仕様) —
    /// `summarize`系のように呼び出し元から`sentenceCount`を受け取るのでは
    /// なく、このメソッド自身が`text.count`を見て決める。プロトコル側に
    /// 数値パラメータを増やさずに済むので、`TranslationService`の他の
    /// メソッドとシグネチャの形を揃えられる。
    public func summarizeThreadEntry(_ text: String, targetLanguage: TranslationLanguage) async throws -> String {
        try requireAvailable()
        let sentenceRangeGuidance = text.count > Self.threadEntryLongMessageThreshold ? "3〜8文程度" : "2〜5文程度"
        let session = LanguageModelSession(model: model, instructions: Self.summarizeThreadEntryInstructions(targetLanguage: targetLanguage, sentenceRangeGuidance: sentenceRangeGuidance))
        do {
            let response = try await session.respond(to: text, options: Self.summarizeOptions)
            // Task #160フォローアップ: このメソッドの出力は`summarizeThread`
            // が`"\(header) \(extracted)"`という1メッセージ1行の箇条書きへ
            // そのまま組み込む — モデルが自分の判断で改行(箇条書き・番号
            // リストなど)を混ぜてしまうと、その1行の体裁が崩れる。指示文
            // (下記)でも改行しないよう求めているが、コード側でも念のため
            // 改行をスペースへ畳んでおく防御 (`SummaryOutputSanitizer`と
            // 同じ「指示文 + 実装側の後処理」の二段構え)。
            return response.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Self.mapEngineError(error)
        }
    }

    /// `summarizeThreadEntry`が文数目安を切り替える閾値 — 新規本文が
    /// これを超えたら「3〜8文程度」、それ以下なら「2〜5文程度」(タスク
    /// 仕様「長いメッセージは文数上限を緩める」)。400字は日本語で
    /// だいたい3〜4文程度の本文に相当し、これより長いメッセージは
    /// 決定事項・数値が複数含まれがちという実感に基づく目安 — 厳密な
    /// 実測に基づくものではないので、実FM確認 (`docs/translation.md`の
    /// Task #160フォローアップ節) で薄いと分かれば調整する。
    private static let threadEntryLongMessageThreshold = 400

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

    /// History (#62/#90/#97/#102/#122/#132): earlier revisions of this
    /// instructions string tried to stop the model from summarizing the
    /// *quoted* reply history by ever-more-specific wording — labeling a
    /// quoted section, capping it at one context sentence, banning
    /// dates/times and per-message narration, forbidding it from lending a
    /// topic/proper-noun to ■要約, fixing a 3-line output structure so a
    /// quote recap couldn't silently expand into it (`SummaryOutputSanitizer`
    /// backstops whatever structural leakage still gets through). None of
    /// that wording reliably held — see git history on this doc comment,
    /// or `docs/translation.md`'s #62/#90/#97/#102/#122/#132 sections, for
    /// the specific real-device repros each iteration chased.
    ///
    /// Task #134 (根治): the fix moved one level down, into
    /// `SummaryInputBuilder` — the model is simply never handed the quoted
    /// text's content anymore. When the source message had a quoted prior
    /// thread, the input now contains only `SummaryInputBuilder
    /// .quotedContextNoteLine` (a fixed note saying this reply follows a
    /// prior exchange whose text was omitted) ahead of the new text, no
    /// real quoted content at all — see that type's doc comment for the
    /// full rationale. Most of the wording below survives from the
    /// pre-#134 revisions anyway (harmless even with nothing left to leak:
    /// still guards the *new* text against sender-name guessing, still
    /// keeps the output to the fixed 3-line structure), but the #97
    /// section-reordering/narration-order concern is gone (there's no
    /// second content section left to narrate out of order) and the #132
    /// "don't borrow a quoted topic" rule is generalized into "don't
    /// invent detail the new text doesn't state" — no quoted text
    /// remains to borrow from, but the model could still fabricate detail
    /// out of thin air, which this rule now covers too. The #97/#102
    /// one-context-sentence allowance (open ■要約 with a short subordinate
    /// clause referencing the prior exchange) is dropped outright, not just
    /// re-scoped — a real-device-adjacent repro (`scratchpad/summary-repro`,
    /// `mail_fixture_long_padded.txt`, the chunked `summarizeLongText` path
    /// specifically) showed that even a scoped version of this allowance,
    /// worded as an *example* subordinate clause ("過去のやり取りへの返信
    /// として、"), got adopted by the model as the literal opening of
    /// ■要約's content — consistently across repeated runs — with the
    /// "■要約" label line itself dropped immediately before it, breaking
    /// `SummaryOutputSanitizer`'s label-based parsing (its `sanitize`
    /// requires finding a line that starts with "■要約"). This happened
    /// even though the `combined` map-reduce input the final `summarize`
    /// call actually received never contained the note line or any
    /// reply-to-prior-thread signal at all (verified by printing `combined`
    /// directly) — i.e. the model wasn't reacting to real input content,
    /// it had internalized the *example phrasing itself* from this
    /// instructions string as boilerplate to prepend unconditionally,
    /// independent of whether the described condition ("注記行がある場合に
    /// 限り") actually held. This is the same failure family Task #122
    /// already named and defended against (instruction wording that reads
    /// too much like plausible output content gets echoed) — a
    /// concrete example phrase for a conditional rule is exactly that
    /// shape. Removing the allowance entirely (■要約 never opens with a
    /// reply-context clause, full stop) closed it in repeated re-runs of
    /// the same fixture. See `docs/translation.md`'s Task #134 section.
    ///
    /// `sentenceCount` scopes only the ■要約 part (the content summary) —
    /// ■伝えたいこと and ■アクション are always short (about one sentence
    /// each) regardless of the caller's requested length, since they're
    /// fixed-shape facts (intent/tone; required action or "特になし") rather
    /// than content that scales with the source text's length. See
    /// `TranslationService.summarize`'s doc comment for the "hint, not a
    /// guarantee" framing this still follows.
    ///
    /// Task #148 (「詳しく要約」— `MessageView.summarySheet`の「再生成」を
    /// Menu化し、通常の`sentenceCount`(2)に加えて約10文の詳細版を追加):
    /// naively embedding a large `sentenceCount` into the original "約N文
    /// 程度で" phrasing reads unnaturally to the model at N=10 — a single
    /// unbroken "約10文程度で" run-on paragraph — so ■要約's length
    /// guidance branches at `detailedSentenceCountThreshold`. The detailed
    /// wording additionally allows (not requires) breaking ■要約 into
    /// chronological paragraphs when the new text naturally has multiple
    /// topics/stages, while still explicitly forbidding padding content the
    /// new text doesn't state — the same "新規本文に実際に書かれていない
    /// 内容を補わない" rule below still applies regardless of which length
    /// guidance was used.
    private static let detailedSentenceCountThreshold = 6

    private static func summaryLengthGuidance(sentenceCount: Int) -> String {
        if sentenceCount >= detailedSentenceCountThreshold {
            return "目安として約\(sentenceCount)文程度の分量で、新規本文に実際に書かれている事柄を、書かれている順に漏れなく詳しく説明してください。内容の区切りが自然な場合は、時系列に沿って段落分けしてもかまいません(段落は空行で区切ってください)。ただし、段落を分けることを理由に新規本文に無い内容を水増ししてはいけません。"
        }
        return "約\(sentenceCount)文\(sentenceCount == 1 ? "" : "程度")で、新規本文に実際に書かれている事柄を、書かれている順に漏れなく説明してください。"
    }

    /// Verification: `scratchpad/summary-repro`'s fixtures (fictional and,
    /// separately, the sensitive real repro) re-run repeatedly against this
    /// #134 revision — see `docs/translation.md`'s Task #134 section for
    /// the before/after. Task #148's detailed-length branch above was
    /// verified the same way with `SUMMARY_REPRO_SENTENCE_COUNTS=10` — see
    /// `docs/translation.md`'s Task #148 section.
    private static func summarizeInstructions(targetLanguage: TranslationLanguage, sentenceCount: Int) -> String {
        """
        あなたはメール本文を\(targetLanguage.displayName)で要約するアシスタントです。以下のルールに従ってください。

        【入力の構造】
        入力の先頭に "\(SummaryInputBuilder.quotedContextNoteLine)" という1行が含まれることがあります。これはこのメールが過去のやり取りへの返信であることを示すだけの注記であり、過去のやり取り自体の内容は入力に含まれていません。この注記行自体は要約対象ではなく、それ以降がこのメール自身の新規本文であり、要約すべき対象です。この注記行が無い場合は、入力全体を新規本文として扱ってください。

        【差出人・宛先について】
        出力のどのパートでも、差出人や宛先の名前を推測して書かないでください。新規本文の冒頭の「〜さん」のような宛名に人物名が明記されている場合であっても、その名前を出力中で主語・行為者として使ってはいけません。「〜さんから」「〜さんへの返信」「〜さん宛て」「〜さんは」「〜さんが」のように、名前(敬称付き・敬称なしを問わず)を主語や行為者にするいかなる言い回しも禁止します。新規本文の主体を指す必要があるときは、常に「この返信」を主語にしてください。

        【新規本文に実際に書かれていない内容を補わない(重要)】
        ■要約に書いてよいのは、新規本文に実際に書かれている事柄だけです。話題・行為・固有名詞(依頼内容、待ち合わせ場所、日時、金額など)を、新規本文に明示されていないのに推測や一般的な想像で補ってはいけません。冒頭の注記行(過去のやり取りへの返信である旨)は入力に含まれていても、その過去のやり取りの具体的な内容は与えられていないため、それを推測して書き加えることも禁止です。判断に迷ったら、その語や話題が新規本文の文字列そのものに含まれているかどうかで機械的に判定し、含まれていなければ書かないでください。

        【各パートの内容ルール】
        ■要約パートでは、\(summaryLengthGuidance(sentenceCount: sentenceCount))一般化しすぎないでください — 例えば「感謝を伝える返信です」のような抽象的な言い換えだけで終わらせず、何について感謝しているのか、何を楽しみにしているのか、何を確認したいのかといった、新規本文に実際に書かれている具体的な内容まで書いてください。これが主要パートであり、主題は常に新規本文です。冒頭の注記行の有無に関わらず、「過去のやり取りへの返信として」のような前置きの一文を書かず、新規本文の内容から直接書き始めてください。日付・時刻を推測で書くこと、および存在しない過去のメールを物語る言い回しは禁止します。新規本文が短い場合(挨拶や「了解です」「承知しました」のような一行の受領確認のみなど)は、水増しせず、このメールが何をしたかを新規本文に書かれている範囲で簡潔に述べてください。
        ■伝えたいことパートでは、約1文で、新規本文を書いた送信者の意図とトーン(お礼を伝えたい、確認を求めている、丁寧・カジュアルな調子など)を述べてください。■要約パートの内容を繰り返すのではなく、このメールが何を達成しようとしているかを述べてください。
        ■アクションパートでは、約1文で、新規本文が受信者に求める行動(返信・確認・日程調整・判断・情報提供など)を述べてください。何も求めていない場合は、このパートの内容を「特になし」の一語のみにしてください。

        【出力形式(最重要)】
        出力は次の3行構造のみで構成してください。ラベル行は「■要約」「■伝えたいこと」「■アクション」の3つを、この順番・この文字列そのままで、それぞれ単独の行として書いてください。各ラベルの内容は次の行以降に書き、ラベル行自体には他の文字を含めないでください。ラベルの説明文やこの指示文自体、英語のテキストを出力に含めないでください。この3行構造は出力全体を通じてちょうど1回だけ出現させてください — 同じラベルを2回書いたり、3行構造を繰り返したりすることは絶対にしないでください。入力中に "\(SummaryInputBuilder.quotedContextNoteLine)" のような見出し・注記行が含まれていても、それは入力の構造を示すためだけのものなので、そのまま出力へ書き写さないでください。

        【出力例】
        ■要約
        見積もりの件について、来週の打ち合わせ日程を確認する返信です。会議室ではなくオンラインでの開催を希望しています。

        ■伝えたいこと
        丁寧に日程調整を依頼している。

        ■アクション
        来週水曜までに希望日を返信する。
        """
    }

    /// Task #160フォローアップ (二重圧縮の根治): `summarizeThreadEntry`が
    /// 使う指示文 — `summarizePlainInstructions`(「削ってでも短くする」
    /// 圧縮の指示) とは正反対の「削らずに書き出す」事実抽出の指示。
    /// `summarizeThread`のmap段からは`message.header`("[日時] 差出人:")
    /// を一切見せない (このメソッドへの入力はメッセージの新規本文だけ) の
    /// で、`summarizePlainInstructions`と同じ「差出人・宛先の名前が本文中
    /// に出てきても主語にせず『この返信』を主語にする」ルールを引き継ぐ —
    /// これは「固有名詞を落とさない」ルールとは矛盾しない (禁止している
    /// のは人物名を*主語*にすることだけで、本文中に出てくる会社名・場所
    /// 名・第三者の名前などを内容として書くことは禁止していない)。
    ///
    /// `sentenceRangeGuidance`は呼び出し側 (`summarizeThreadEntry`) が
    /// `text.count`を見て「2〜5文程度」/「3〜8文程度」のどちらかを渡す —
    /// 「長いメッセージは文数上限を緩める」というタスク仕様の要求を、
    /// この指示文の文字列だけで固定値にせず可変にするための唯一の
    /// パラメータ。
    ///
    /// 出力に改行や箇条書き記号を含めないよう明示している理由は
    /// `summarizeThreadEntry`のdoc comment参照 — この出力は
    /// `summarizeThread`が1メッセージ1行の箇条書きへそのまま組み込む。
    private static func summarizeThreadEntryInstructions(targetLanguage: TranslationLanguage, sentenceRangeGuidance: String) -> String {
        """
        以下はメールスレッド内の1通のメッセージの新規本文(引用された過去の返信は除外済み)です。この新規本文の具体的な内容を\(targetLanguage.displayName)で書き出してください。以下のルールに従ってください。

        【最優先ルール: 情報を落とさない】
        新規本文に書かれている決定事項・依頼や質問・数値(金額・日時・個数・期限など)・固有名詞(人名・会社名・場所名・店名など)は、一切省略しないでください。挨拶や「よろしくお願いします」「お世話になっております」のような定型的な前置き・結びの言葉だけは削って構いません。目安の分量よりも、具体的な内容を落とさないことを常に優先してください — 短くまとめることが目的ではありません。

        【新規本文に実際に書かれていない内容を補わない(重要)】
        新規本文に実際に書かれている事柄だけを書き出してください。書かれていない内容を推測や一般的な想像で補ってはいけません。

        【差出人・宛先について】
        差出人や宛先の名前が新規本文中に出てきても、それを主語・行為者にしないでください。「〜さんから」「〜さんへの返信」のように名前を主語や行為者にする言い回しは禁止します。この新規本文の主体を指す必要があるときは「この返信」を主語にしてください(ただし、本文中に出てくる第三者の名前・会社名・場所名などを内容として書くことは禁止していません)。

        【分量・出力形式】
        目安は\(sentenceRangeGuidance)ですが、上記の「情報を落とさない」ルールを優先し、必要なら目安を超えてもかまいません。ラベルや見出し、箇条書き、番号付きリスト、記号("■"など)は付けず、改行も入れずに、1つの続いた文章として出力してください。説明文やこの指示文自体、英語のテキストを出力に含めないでください。
        """
    }

    /// Task #153 (スレッド全体のAI要約) → Task #160フォローアップ (二重圧縮
    /// の根治): 以前は`■経緯`/`■現状`の2パートをここで生成していたが、
    /// 今は`■現状`(このスレッドが最終的にどうなったか・未決事項・次の
    /// アクション)1パートだけを要求する指示文 — `■経緯`は
    /// `summarizeThread`がモデルを通さずアプリ側で組み立てる
    /// (`TranslationService.summarizeThreadDigest`のdoc comment参照)。
    /// 入力は`summarizeThreadEntry`の抽出結果を`"[日時] 差出人: 抽出内容"`
    /// 形式で時系列順に並べたもの — 引き続き差出人名は「入力に実際に
    /// 書かれている名前だけ使用・推測禁止」ルールを課す (経緯を語らない
    /// ので誰が何をしたか自体は生成しないが、「次は田中さんが対応」のような
    /// 次のアクションの記述で名前を使う可能性があるため)。
    private static func currentStatusInstructions(targetLanguage: TranslationLanguage) -> String {
        """
        あなたは複数人のメールのやり取り(スレッド)の「現在の状態」を\(targetLanguage.displayName)で説明するアシスタントです。以下のルールに従ってください。

        【入力の構造】
        入力は "[日時] 差出人: 内容" という形式の行が、スレッド内のメッセージ1通につき1行、時系列順(古い順)に並んだものです。各行の内容は、そのメッセージの新規部分から具体的な事柄を書き出したものです。

        【差出人名について(重要)】
        名前を使う場合、使ってよい名前は入力の各行の "[日時] 差出人:" 部分に実際に書かれている名前だけです。入力に登場しない名前を推測や創作で書き加えることは絶対に禁止します。

        【新規本文に実際に書かれていない内容を補わない(重要)】
        書いてよいのは、入力の各行に実際に書かれている事柄だけです。入力に明示されていないのに推測や一般的な想像で補ってはいけません。

        【内容ルール】
        このスレッドが最終的にどうなったか — 結論・合意事項 — と、まだ決まっていない点、次に誰が何をすべきか(次のアクション)を、約2〜4文で具体的に述べてください。入力の各行を時系列順にそのまま書き写す(逐次的な再話)のではなく、最終的な状態だけを簡潔にまとめてください。一般化しすぎた抽象的な言い換えだけで終わらせないでください。

        【出力形式(最重要)】
        出力は"\(ThreadDigestLabel.currentStatus)"という1行のラベルから始めてください。ラベル行はこの文字列そのまま・単独の行として書き、その次の行以降に内容を書いてください。ラベルの説明文やこの指示文自体、英語のテキストを出力に含めないでください。このラベルは出力全体を通じてちょうど1回だけ出現させてください — 同じラベルを2回書いたり、内容を繰り返したりすることは絶対にしないでください。

        【出力例】
        \(ThreadDigestLabel.currentStatus)
        水曜14時にイタリアンの店で開催することが合意され、予約はまだ取れていない。田中が予約を担当し、取れ次第スレッドで共有する予定。
        """
    }

    /// The unlabeled counterpart used by `summarizePlain` — no ■ labels, no
    /// fixed structure, just a short plain-prose summary. See
    /// `TranslationService.summarizePlain`'s doc comment (Task #122) for why
    /// `summarizeLongText`'s per-chunk "map" pass must use this instead of
    /// `summarizeInstructions`.
    ///
    /// Task #132 follow-up (差出人・宛先を推測しない rule leaking through this
    /// method's own long-mail path even after being added to
    /// `summarizeInstructions` alone) plus Task #134 (this method's input is
    /// now `SummaryInputBuilder`'s #134 shape too — a single
    /// `quotedContextNoteLine` note, not a labeled quoted section — so the
    /// old "don't echo the two section labels" ban is replaced with "don't
    /// echo the note line" below, naming `SummaryInputBuilder
    /// .quotedContextNoteLine` directly so this string can't drift out of
    /// sync with what `build` actually emits).
    private static func summarizePlainInstructions(targetLanguage: TranslationLanguage, sentenceCount: Int) -> String {
        """
        次のメール本文を\(targetLanguage.displayName)で、約\(sentenceCount)文\(sentenceCount == 1 ? "" : "程度")の自然な文章として要約してください。ラベルや見出し、箇条書き、記号("■"など)は付けず、要約の文章だけを出力してください。説明文やこの指示文自体を出力に含めないでください。差出人・宛先の名前が本文中に出てきても、それを主語にせず「この返信」を主語にしてください。入力の先頭に "\(SummaryInputBuilder.quotedContextNoteLine)" という注記行が含まれていても、それは要約すべき本文ではなく過去のやり取りへの返信であることを示すだけの注記なので、この注記行自体を出力に含めず、その具体的な内容を推測して書き加えないでください。
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
