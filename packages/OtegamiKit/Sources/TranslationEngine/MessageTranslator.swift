import Foundation
import GRDB
import OtegamiCore
import OtegamiStore
import OtegamiTranslation

/// Ties a `TranslationService` to persistence: checks
/// `messageTranslation` (`MessageTranslationRecord`) before calling the
/// engine, translates paragraph-aligned (so 1i's per-paragraph original
/// toggle has data to work with) when a cache miss happens, and writes the
/// result back. The one object the eventual UI phase needs to hold onto for
/// "translate this message" — it never touches `FoundationModels` or any
/// other engine specifics itself, only the `TranslationService` protocol.
///
/// An `actor`: `translate(messageId:...)` reads-then-writes the same
/// message's cache row, and while a same-message race is unlikely in
/// practice (one detail view open at a time), actor isolation makes it
/// impossible rather than merely unlikely, at the cost of two different
/// messages' translations serializing behind this one actor — acceptable
/// given on-device inference is already the dominant cost, not lock
/// contention.
public actor MessageTranslator {
    /// `TranslationService` implementation identifiers this codebase
    /// ships, for `MessageTranslationRecord.engineIdentifier` — callers
    /// constructing a `MessageTranslator` use one of these rather than
    /// inventing their own string, so a cache row's engine can always be
    /// matched back to a known implementation.
    public enum EngineIdentifier {
        public static let foundationModels = "foundation-models"
        public static let fake = "fake"
    }

    private let database: AppDatabase
    private let service: any TranslationService
    private let engineIdentifier: String

    public init(database: AppDatabase, service: any TranslationService, engineIdentifier: String) {
        self.database = database
        self.service = service
        self.engineIdentifier = engineIdentifier
    }

    /// Forwards `service.availability` — a caller (the future UI phase)
    /// checks this before offering a "翻訳" action at all, the same way
    /// `TranslationService.availability` itself is meant to be checked
    /// before `translate`/`translateStream`. `nonisolated` because
    /// `service` is immutable actor state, safe to read from any context
    /// (see `FakeTranslationService.availability`'s doc comment for the
    /// same reasoning).
    public nonisolated var availability: TranslationAvailability { service.availability }

    /// Streams a live translation without touching the cache — for a
    /// "typing" effect in the detail view while the *cached* result (from
    /// a concurrent or subsequent `translate` call) is what actually
    /// persists. Streaming a partial, possibly-still-changing translation
    /// into `messageTranslation` would risk caching a truncated result if
    /// the stream is cancelled mid-flight, so this deliberately bypasses
    /// persistence entirely — callers that want the final result cached
    /// should also call `translate(messageId:...)`.
    public nonisolated func translateStream(
        _ text: String,
        from source: TranslationLanguage,
        to target: TranslationLanguage
    ) -> AsyncThrowingStream<String, Error> {
        service.translateStream(text, from: source, to: target)
    }

    /// Returns the message's translation, from cache if a still-valid row
    /// exists (same target language, same engine), otherwise by calling
    /// `service.translateParagraphs` and persisting the result before
    /// returning it. Never throws — engine/DB failures resolve to
    /// `.failed(message:)` so a caller can render that state directly
    /// instead of also needing a `do`/`catch`.
    @discardableResult
    public func translate(
        messageId: Int64,
        sourceText: String,
        sourceLanguage: TranslationLanguage,
        targetLanguage: TranslationLanguage
    ) async -> MessageTranslationState {
        await translateAligned(
            messageId: messageId,
            paragraphs: ParagraphSplitter.split(sourceText),
            cacheEngineIdentifier: engineIdentifier,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    /// HTML メールのレイアウト保持翻訳 (実機フィードバック「htmlメールの場合、
    /// レイアウトをなるべく崩さないように翻訳を表示して欲しい」): the same
    /// cache/chunk/persist pipeline as `translate(messageId:sourceText:...)`
    /// above, but `texts` is already the exact ordered array to translate —
    /// each element is one DOM text node's current content, collected by
    /// the app layer's `HTMLTranslationController` (this package has no
    /// WebKit dependency and can't collect DOM nodes itself) — rather than a
    /// flattened string this method would otherwise have to re-split with
    /// `ParagraphSplitter`, which assumes prose paragraph boundaries, not
    /// arbitrary DOM text-node boundaries (a `<td>` label and its sibling
    /// value are two separate array elements here even though
    /// `ParagraphSplitter` would never split them apart from flattened
    /// text).
    ///
    /// Cached under a distinct engine-identifier suffix
    /// (`htmlEngineIdentifierSuffix`) so a message translated once in HTML
    /// mode and once in plain-text mode (the "テキストで表示" toggle lets a
    /// user switch either way per message) never mixes the two differently-
    /// shaped `paragraphs` arrays together — `translateAligned`'s cache
    /// check already keys on the engine identifier, so this reuses that
    /// exact mechanism instead of adding a new cache dimension/column to
    /// `MessageTranslationRecord`.
    @discardableResult
    public func translateHTMLTextNodes(
        messageId: Int64,
        texts: [String],
        sourceLanguage: TranslationLanguage,
        targetLanguage: TranslationLanguage
    ) async -> MessageTranslationState {
        await translateAligned(
            messageId: messageId,
            paragraphs: texts,
            cacheEngineIdentifier: engineIdentifier + Self.htmlEngineIdentifierSuffix,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    private static let htmlEngineIdentifierSuffix = ".html-nodes"

    /// Shared by `translate(messageId:sourceText:...)` and
    /// `translateHTMLTextNodes(messageId:texts:...)` — both ultimately just
    /// need "translate this ordered array of strings, cached under this
    /// engine identifier", they only differ in *how* that array was
    /// produced (prose-paragraph splitting vs. DOM-node collection).
    private func translateAligned(
        messageId: Int64,
        paragraphs: [String],
        cacheEngineIdentifier: String,
        sourceLanguage: TranslationLanguage,
        targetLanguage: TranslationLanguage
    ) async -> MessageTranslationState {
        do {
            if let cached = try await fetchCached(messageId: messageId),
               isStillValid(cached, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, engineIdentifier: cacheEngineIdentifier) {
                return .translated(cached)
            }

            // design-phase-3: a paragraph that's itself longer than the
            // engine's context window (`TranslationChunker`'s doc comment —
            // the real-device "translation works for some mail, not
            // others" report) used to make `translateParagraphs` throw and
            // fail the whole message. Explode any oversized paragraph into
            // safe-sized chunks *before* calling the engine, then regroup
            // the per-chunk results back into one translated string per
            // original paragraph — `chunkCounts[i]` chunks belong to
            // `paragraphs[i]`, in order, so `translatedParagraphs` still
            // lines up 1:1 with `paragraphs` for `TranslatedParagraph`
            // (1i's per-paragraph original/translated toggle needs that
            // alignment; a paragraph split into 3 chunks must still collapse
            // back into a single translated paragraph, not 3).
            var chunks: [String] = []
            var chunkCounts: [Int] = []
            chunkCounts.reserveCapacity(paragraphs.count)
            for paragraph in paragraphs {
                let pieces = TranslationChunker.chunk(paragraph)
                chunks.append(contentsOf: pieces)
                chunkCounts.append(pieces.count)
            }

            let translatedChunks = try await service.translateParagraphs(chunks, from: sourceLanguage, to: targetLanguage)

            var translatedParagraphs: [String] = []
            translatedParagraphs.reserveCapacity(paragraphs.count)
            var cursor = 0
            for count in chunkCounts {
                let pieceTranslations = translatedChunks[cursor..<(cursor + count)]
                translatedParagraphs.append(pieceTranslations.joined(separator: " "))
                cursor += count
            }

            let aligned = zip(paragraphs, translatedParagraphs).map { TranslatedParagraph(original: $0, translated: $1) }

            let record = MessageTranslationRecord(
                messageId: messageId,
                sourceLanguage: sourceLanguage.rawValue,
                targetLanguage: targetLanguage.rawValue,
                translatedText: aligned.map(\.translated).joined(separator: "\n\n"),
                paragraphs: aligned,
                engineIdentifier: cacheEngineIdentifier
            )
            try await persist(record)
            return .translated(record)
        } catch let error as TranslationServiceError {
            // design-phase-3: `.userFacingMessage` (not `.errorDescription`,
            // which stays English/log-oriented) so "本文が長すぎます" reaches
            // the user instead of a generic failure — see that property's
            // doc comment for why the mapping has to happen here rather
            // than in the UI layer.
            return .failed(message: error.userFacingMessage)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    /// Drops `messageId`'s cached translation, if any — for a future
    /// explicit "再翻訳" UI action, or for tests that need to force a cache
    /// miss on the next `translate` call.
    public func invalidate(messageId: Int64) async throws {
        try await database.dbWriter.write { db in
            _ = try MessageTranslationRecord.deleteOne(db, key: messageId)
        }
    }

    private func fetchCached(messageId: Int64) async throws -> MessageTranslationRecord? {
        try await database.dbWriter.read { db in
            try MessageTranslationRecord.fetchOne(db, key: messageId)
        }
    }

    private func persist(_ record: MessageTranslationRecord) async throws {
        try await database.dbWriter.write { db in
            try record.save(db)
        }
    }

    private func isStillValid(_ cached: MessageTranslationRecord, sourceLanguage: TranslationLanguage, targetLanguage: TranslationLanguage, engineIdentifier: String) -> Bool {
        cached.sourceLanguage == sourceLanguage.rawValue
            && cached.targetLanguage == targetLanguage.rawValue
            && cached.engineIdentifier == engineIdentifier
    }
}
