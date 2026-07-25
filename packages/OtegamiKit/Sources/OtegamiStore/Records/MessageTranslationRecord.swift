import Foundation
import GRDB

/// One paragraph of a translation, aligned by array index with the source
/// text's own paragraphs (`ParagraphSplitter.split(_:)` in
/// `OtegamiTranslation`) — what 1i's "段落長押しでその段落だけ原文表示"
/// needs: given the paragraph the user long-pressed, look up its `original`
/// without re-deriving the split from scratch.
public struct TranslatedParagraph: Codable, Equatable, Sendable {
    public var original: String
    public var translated: String

    public init(original: String, translated: String) {
        self.original = original
        self.translated = translated
    }
}

/// `MessageTranslator`'s cache: at most one row per `messageId` (this app
/// never needs a message translated into more than one target language
/// concurrently). See v15's migration comment in `AppDatabase` for the full
/// schema rationale, including why this is keyed by message rather than by
/// `(messageId, targetLanguage)`, and why `engineIdentifier` exists.
///
/// `paragraphs` is a plain `[TranslatedParagraph]` property — GRDB's
/// `Codable` record support stores it as JSON in the `.blob` column
/// automatically, the same way `MessageRecord.fromAddresses` stores
/// `[EmailAddress]`; no manual (de)serialization needed here.
public struct MessageTranslationRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "messageTranslation"

    /// Shares its primary key with `MessageRecord.id` (one translation
    /// cache row per message, mirroring `MessageBodyRecord.messageId`).
    public var messageId: Int64
    public var sourceLanguage: String
    public var targetLanguage: String
    /// The full translated body, `paragraphs.map(\.translated)` joined —
    /// stored separately (rather than derived at read time) so a caller
    /// that just wants "the translation" (list-row preview, non-paragraph-
    /// aware rendering) doesn't need to reassemble it from `paragraphs`
    /// every time.
    public var translatedText: String
    public var paragraphs: [TranslatedParagraph]
    /// Which `TranslationService` implementation produced this row (e.g.
    /// `"foundation-models"`, `"fake"`) — `MessageTranslator` uses this to
    /// decide whether a cached row is still trustworthy for the engine
    /// currently in use.
    public var engineIdentifier: String
    public var translatedAt: Date

    public init(
        messageId: Int64,
        sourceLanguage: String,
        targetLanguage: String,
        translatedText: String,
        paragraphs: [TranslatedParagraph],
        engineIdentifier: String,
        translatedAt: Date = Date()
    ) {
        self.messageId = messageId
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.translatedText = translatedText
        self.paragraphs = paragraphs
        self.engineIdentifier = engineIdentifier
        self.translatedAt = translatedAt
    }
}
