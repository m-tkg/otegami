import Foundation

/// A deterministic, instant `TranslationService` for tests (and, later,
/// SwiftUI previews) — no on-device model, no Apple-only dependency, no
/// real latency. Every method's output is a pure function of its input, so
/// `TranslationEngineTests`/callers can assert exact strings instead of
/// just "did it change".
///
/// An `actor` (not a `struct`) so `configure(behavior:)` can be flipped
/// mid-test (e.g. "start `.success`, then simulate the model becoming
/// unavailable mid-flow") and `translateCallCount` is a safe, race-free way
/// to assert `MessageTranslator`'s cache actually short-circuits a second
/// call for the same message.
public actor FakeTranslationService: TranslationService {
    /// What the next call should do. `.failure`/`.unavailable` apply to
    /// every method (`translate`/`translateParagraphs`/`translateStream`/
    /// `summarize`) so a single `configure` call can simulate "the engine
    /// just broke" for whichever one a test happens to be exercising.
    public enum Behavior: Sendable, Equatable {
        case success
        case failure(message: String)
        case unavailable(TranslationUnavailableReason)
        /// Simulates `TranslationServiceError.tooLong` — for tests covering
        /// the "本文が長すぎます" UI path without needing a real engine's
        /// context-window limit.
        case tooLong(message: String)
    }

    private var behavior: Behavior
    private let availabilityValue: TranslationAvailability

    public private(set) var translateCallCount = 0
    public private(set) var translateParagraphsCallCount = 0
    public private(set) var summarizeCallCount = 0
    /// Task #122: tracked separately from `summarizeCallCount` so a test can
    /// assert `summarizeLongText`'s map-reduce shape — one `summarizePlain`
    /// call per `TranslationChunker` chunk, then exactly one `summarize`
    /// call for the final structured pass.
    public private(set) var summarizePlainCallCount = 0
    /// Task #153 (スレッド全体のAI要約): `summarizeThread`(`TranslationService`
    /// のprotocol extension)のreduce段呼び出し回数 — `summarizeCallCount`
    /// (単一メッセージの3パート要約) とは別カウントで追跡し、テストが
    /// map-reduceの形 (チャンク数分の`summarizePlain`呼び出し + reduce段の
    /// この呼び出しちょうど1回) を検証できるようにする。
    public private(set) var summarizeThreadDigestCallCount = 0
    /// Task #160フォローアップ (二重圧縮の根治): `summarizeThread`のmap段
    /// (`summarizeThreadEntry`) 呼び出し回数 — Task #160時代は
    /// `summarizePlainCallCount`をそのまま流用していたが、`summarizePlain`
    /// (単一メッセージの長文圧縮のmap段でも使う) と役割が分かれた今は
    /// 独立カウントにしないと、両方を使うテストで数値の意味が混ざる。
    public private(set) var summarizeThreadEntryCallCount = 0
    /// Task #160フォローアップ3 (ユーザー要望「要約済みのものを再度読ませて
    /// さらに要約を挟ませてシンプルにする」): `summarizeThread`の任意の
    /// 「仕上げ」パス (`refineThreadEntries`) の呼び出し回数 — 独立カウント
    /// にしておくことで、テストが「短いスレッドではこのパスがスキップ
    /// される (0回)」「長いスレッドではちょうど1回」を検証できる。
    public private(set) var refineThreadEntriesCallCount = 0
    /// Task #61 (ガードレール誤発動の寛容化テスト用): exact input strings
    /// `translate(_:from:to:)` should fail with `TranslationServiceError
    /// .contentBlocked` for, independent of `behavior` — lets a test
    /// simulate "the model's safety guardrails misfired on *this one*
    /// chunk, but every other chunk translates fine" (the real-device
    /// report this exists to cover), which a single global `Behavior` case
    /// can't express since it applies to every call. Checked first, before
    /// `checkBehavior()`, so a test can combine this with `.success` (the
    /// common case: "mostly fine, one chunk blocked").
    private var blockedTexts: Set<String> = []
    /// Task #160フォローアップ3: same "fail just this one call, everything
    /// else succeeds" motivation as `blockedTexts` above — lets
    /// `TranslationServiceSummarizeThreadTests` verify `summarizeThread`'s
    /// "an unrefined `■経緯` is still a correct, complete summary" fallback
    /// contract without having to fail the *whole* engine (`behavior`),
    /// which would also fail the map step and `summarizeThreadDigest`.
    private var refineThreadEntriesShouldFail = false

    public init(availability: TranslationAvailability = .available, behavior: Behavior = .success) {
        self.availabilityValue = availability
        self.behavior = behavior
    }

    /// Task #160フォローアップ3: see `refineThreadEntriesShouldFail`'s doc
    /// comment.
    public func configureRefineThreadEntriesFailure(_ shouldFail: Bool) {
        refineThreadEntriesShouldFail = shouldFail
    }

    /// Task #61: marks `texts` as guardrail-blocked for every subsequent
    /// `translate(_:from:to:)` call whose input matches exactly — see
    /// `blockedTexts`'s doc comment.
    public func configureContentBlocked(for texts: Set<String>) {
        blockedTexts = texts
    }

    /// Immutable for the lifetime of one instance (unlike `behavior`) — a
    /// real engine's availability can change at any time, but tests that
    /// want to simulate *that* create a fresh instance or race against
    /// `configure(behavior:)` instead, keeping this `nonisolated` property
    /// (required by the protocol's synchronous `get`) trivially safe to
    /// read from any context.
    public nonisolated var availability: TranslationAvailability { availabilityValue }

    public func configure(behavior: Behavior) {
        self.behavior = behavior
    }

    public func translate(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) async throws -> String {
        translateCallCount += 1
        if blockedTexts.contains(text) {
            throw TranslationServiceError.contentBlocked(message: "fake guardrail violation")
        }
        try checkBehavior()
        return Self.deterministicTranslation(text, to: target)
    }

    public func translateParagraphs(_ paragraphs: [String], from source: TranslationLanguage, to target: TranslationLanguage) async throws -> [String] {
        guard !paragraphs.isEmpty else { return [] }
        translateParagraphsCallCount += 1
        try checkBehavior()
        return paragraphs.map { Self.deterministicTranslation($0, to: target) }
    }

    /// `nonisolated` (like `availability`) since the protocol requirement
    /// is a synchronous, non-`async` function — it has to be callable
    /// without `await`ing the actor first. Reading the actor-isolated
    /// `behavior` therefore happens inside the `Task` the stream spawns
    /// (`await self.behavior`), not synchronously in this function's own
    /// body.
    public nonisolated func translateStream(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) -> AsyncThrowingStream<String, Error> {
        let full = Self.deterministicTranslation(text, to: target)
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch await self.behavior {
                case .failure(let message):
                    continuation.finish(throwing: TranslationServiceError.failed(message: message))
                case .unavailable(let reason):
                    continuation.finish(throwing: TranslationServiceError.unavailable(reason))
                case .tooLong(let message):
                    continuation.finish(throwing: TranslationServiceError.tooLong(message: message))
                case .success:
                    // Cumulative word-by-word chunks, matching
                    // `LanguageModelSession.streamResponse`'s own
                    // snapshot-is-the-whole-thing-so-far semantics (see
                    // `TranslationService.translateStream`'s doc comment)
                    // — exercises the same "always render the latest
                    // element" assumption a real stream requires, without
                    // any real latency.
                    let words = full.split(separator: " ")
                    var cumulative = ""
                    for (index, word) in words.enumerated() {
                        cumulative += (index == 0 ? "" : " ") + word
                        continuation.yield(cumulative)
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func summarize(_ text: String, targetLanguage: TranslationLanguage, sentenceCount: Int) async throws -> String {
        summarizeCallCount += 1
        try checkBehavior()
        let sentences = Self.splitSentences(text)
        let picked = sentences.prefix(max(0, sentenceCount)).joined(separator: " ")
        return Self.deterministicTranslation(picked.isEmpty ? text : picked, to: targetLanguage)
    }

    /// Same deterministic "first N sentences" behavior as `summarize` —
    /// `FakeTranslationService`'s output was never labeled to begin with, so
    /// there's no structure to strip here; this exists as its own method
    /// (rather than reusing `summarize`) purely so `summarizePlainCallCount`
    /// can track it separately, matching the real engine's map/reduce split.
    public func summarizePlain(_ text: String, targetLanguage: TranslationLanguage, sentenceCount: Int) async throws -> String {
        summarizePlainCallCount += 1
        try checkBehavior()
        let sentences = Self.splitSentences(text)
        let picked = sentences.prefix(max(0, sentenceCount)).joined(separator: " ")
        return Self.deterministicTranslation(picked.isEmpty ? text : picked, to: targetLanguage)
    }

    /// Task #153 (スレッド全体のAI要約) → Task #160フォローアップ (二重圧縮
    /// の根治): `summarizeThread`のreduce段が呼ぶ構造化要約 — 以前は
    /// ■経緯/■現状の2ラベルを返していたが、今は`■現状`1ラベルだけを
    /// 返す (本物の`FoundationModelsTranslationService.summarizeThreadDigest`
    /// と同じ形、`ThreadDigestLabel.currentStatus`を共有して drift を防ぐ)。
    public func summarizeThreadDigest(_ text: String, targetLanguage: TranslationLanguage) async throws -> String {
        summarizeThreadDigestCallCount += 1
        try checkBehavior()
        let translated = Self.deterministicTranslation(text, to: targetLanguage)
        return """
        \(ThreadDigestLabel.currentStatus)
        \(translated)
        """
    }

    /// Task #160フォローアップ (二重圧縮の根治): `summarizeThread`のmap段
    /// — `summarizePlain`と同じ決定的な「先頭N文」動作だが、独立した
    /// `summarizeThreadEntryCallCount`で追跡する (このメソッドのdoc comment
    /// 参照)。文数はやや多め (5文) にしてある — 実物の
    /// `summarizeThreadEntryInstructions`が「2〜5文/3〜8文」という圧縮
    /// 目的ではない目安を使うことに軽く対応させたもので、フェイク側の
    /// 決定的挙動としての意味は`summarizePlain`と変わらない。
    public func summarizeThreadEntry(_ text: String, targetLanguage: TranslationLanguage) async throws -> String {
        summarizeThreadEntryCallCount += 1
        try checkBehavior()
        let sentences = Self.splitSentences(text)
        let picked = sentences.prefix(5).joined(separator: " ")
        return Self.deterministicTranslation(picked.isEmpty ? text : picked, to: targetLanguage)
    }

    /// Task #160フォローアップ3: `summarizeThread`の任意の「仕上げ」パス
    /// — `summarizeThreadDigest`と同様、決定的な出力にするため実際の
    /// `■経緯`ラベル付き出力をそのまま返す (`ThreadDigestLabel.progress`
    /// を共有して drift を防ぐ)。
    public func refineThreadEntries(_ text: String, targetLanguage: TranslationLanguage) async throws -> String {
        refineThreadEntriesCallCount += 1
        // Task #160フォローアップ3: `blockedTexts`と同じ理由で`checkBehavior()`
        // より先に見る — `configureRefineThreadEntriesFailure(true)`は
        // このメソッドだけを狙って失敗させる (`behavior`を`.failure`に
        // すると map段/■現状生成まで巻き添えで失敗してしまうため)。
        guard !refineThreadEntriesShouldFail else {
            throw TranslationServiceError.failed(message: "fake refineThreadEntries failure (test-only)")
        }
        try checkBehavior()
        let translated = Self.deterministicTranslation(text, to: targetLanguage)
        return """
        \(ThreadDigestLabel.progress)
        \(translated)
        """
    }

    private func checkBehavior() throws {
        switch behavior {
        case .success:
            break
        case .failure(let message):
            throw TranslationServiceError.failed(message: message)
        case .unavailable(let reason):
            throw TranslationServiceError.unavailable(reason)
        case .tooLong(let message):
            throw TranslationServiceError.tooLong(message: message)
        }
    }

    /// `"[<target> ] <text>"` — a fixed, greppable marker rather than
    /// anything resembling real machine translation, so a test (or a
    /// developer eyeballing a preview) can never mistake fake output for a
    /// real model's.
    static func deterministicTranslation(_ text: String, to target: TranslationLanguage) -> String {
        "[\(target.rawValue)] \(text)"
    }

    /// A deliberately simple sentence split (breaks on `.`/`!`/`?`/`。`/
    /// `！`/`？`, keeping the punctuation) — good enough for
    /// `summarize`'s deterministic "first N sentences" behavior, not meant
    /// to handle abbreviations or nested punctuation correctly.
    static func splitSentences(_ text: String) -> [String] {
        let terminators = CharacterSet(charactersIn: ".!?。！？")
        var sentences: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if terminators.contains(scalar) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty { sentences.append(trailing) }
        return sentences
    }
}
