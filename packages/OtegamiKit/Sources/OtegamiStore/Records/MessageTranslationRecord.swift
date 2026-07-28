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
    /// Task #61 (ガードレール誤発動の寛容化): `true` when this paragraph
    /// contained at least one chunk that `MessageTranslator.translateAligned`
    /// couldn't translate because the engine reported
    /// `TranslationServiceError.contentBlocked` (Apple Foundation Models の
    /// ガードレール誤発動 — 無害な文面でも発生しうる、`docs/translation.md`
    /// 参照) — `translated` is then just `original` verbatim for (at least
    /// part of) this paragraph, not a real translation.
    ///
    /// Decoded via `decodeIfPresent` (custom `init(from:)` below) so a
    /// `messageTranslation` row cached before this field existed decodes as
    /// `false` rather than failing to decode at all — this is stored as
    /// JSON inside `MessageTranslationRecord.paragraphs`'s existing `.blob`
    /// column (that type's own doc comment), so adding this field needs no
    /// GRDB schema migration, just backward-compatible `Codable`.
    public var wasBlocked: Bool

    public init(original: String, translated: String, wasBlocked: Bool = false) {
        self.original = original
        self.translated = translated
        self.wasBlocked = wasBlocked
    }

    private enum CodingKeys: String, CodingKey {
        case original, translated, wasBlocked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        original = try container.decode(String.self, forKey: .original)
        translated = try container.decode(String.self, forKey: .translated)
        wasBlocked = try container.decodeIfPresent(Bool.self, forKey: .wasBlocked) ?? false
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

    /// Task #61: whether *any* paragraph in this translation had a chunk
    /// the engine's safety guardrails blocked (`TranslatedParagraph
    /// .wasBlocked`'s doc comment) — `apps/Otegami`'s
    /// `MessageDetailFooterToolbar` (`translateButton`, Task #88; formerly
    /// `TranslationFloatingButton`) uses this to show a modest "一部の文は
    /// 翻訳できませんでした" note
    /// instead of treating a partially-blocked translation as either a
    /// silent full success or a scary full failure.
    public var hasPartiallyBlockedContent: Bool {
        paragraphs.contains { $0.wasBlocked }
    }
}
