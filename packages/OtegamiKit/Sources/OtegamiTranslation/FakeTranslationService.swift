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

    public init(availability: TranslationAvailability = .available, behavior: Behavior = .success) {
        self.availabilityValue = availability
        self.behavior = behavior
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
