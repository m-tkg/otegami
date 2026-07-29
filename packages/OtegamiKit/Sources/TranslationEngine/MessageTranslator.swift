import Foundation
import GRDB
import OtegamiCore
import OtegamiStore
import OtegamiTranslation
import os

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
        /// Task #159 (メール翻訳を Apple Translation フレームワークの専用 NMT
        /// へ切替): `AppleTranslationService`/`HybridTranslationService`'s
        /// identifier — deliberately distinct from `foundationModels` above
        /// (not reused) so `isStillValid`'s engine-identifier check treats
        /// every pre-existing `foundation-models`-cached translation as
        /// stale on next open and regenerates it through the new engine,
        /// rather than serving a cached result from a since-replaced engine.
        public static let appleTranslation = "apple-translation"
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

            // Phase 5 (2026-07-30, 実機ログ dd58453): 本文そのものは出さず、
            // 件数/文字数/由来 (`.html-nodes`サフィックスの有無でHTML経由か
            // 判別できる) だけを記録 — 次に「翻訳が失敗する」報告が来た時、
            // 実機ログ1本から「入力が0件/空白だけだったか」を即座に切り分け
            // られるようにするためのもの (F15の趣旨を新規ログにも適用)。
            Self.logger.notice("translateAligned: messageId=\(messageId, privacy: .public) engine=\(cacheEngineIdentifier, privacy: .public) paragraphCount=\(paragraphs.count, privacy: .public) totalChars=\(paragraphs.reduce(0) { $0 + $1.count }, privacy: .public) source=\(sourceLanguage.rawValue, privacy: .public) target=\(targetLanguage.rawValue, privacy: .public)")

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

            // Phase 5 (2026-07-30, 実機ログ dd58453 で確定した真因): 空 (また
            // は空白/不可視文字だけ) の要素だけからなる`paragraphs`を
            // フィルタせずそのままエンジンへ渡すと、`TranslationSession`側の
            // 言語自動判定 (LID) に渡す文字列が実質0件になり
            // `TranslationErrorDomain Code=21`("Client asked to translate
            // batch of 0 inputs") で失敗する — これが誤って「言語データ未
            // ダウンロード」と診断されていた実機不具合の本当の原因。
            // `TranslationChunker.chunk`が空白/不可視文字のみの段落を`[]`に
            // 潰す (このタスクでの修正、そのファイルのdoc comment参照) ため
            // `chunks`はここで初めて「翻訳すべき実体が本当に1つも無い」を
            // 判定できる、意味のある空チェックになる — エンジンを一切呼ばず
            // 中立な「見つかりませんでした」を返す。
            guard !chunks.isEmpty else {
                Self.logger.notice("translateAligned: messageId=\(messageId, privacy: .public) aborting — no translatable content after chunking (paragraphCount=\(paragraphs.count, privacy: .public))")
                return .failed(message: "翻訳できる本文が見つかりませんでした")
            }

            // Task #61 (実機フィードバック「無害なマーケティングメールなのに
            // "The model's safety guardrails were triggered." で翻訳全体が
            // 失敗する」): 以前は `service.translateParagraphs` への一括呼び
            // 出しがチャンク1つのガードレール誤発動で配列全体を巻き込んで
            // 失敗していた。1チャンクずつ `service.translate` を呼び、
            // `.contentBlocked` (ガードレール誤発動 — `TranslationServiceError
            // .contentBlocked`のdoc comment参照) だけはそのチャンクの原文を
            // そのまま採用して続行する。それ以外のエラー (`.tooLong`/
            // `.unavailable`/その他の`.failed`) は `catch` に一致せずこの
            // `do` ブロックの外側 (このメソッド自身の `catch` 節) へ素通り
            // し、従来どおり全体を失敗させる — 意図的に「握り潰し」を
            // ガードレール誤発動 1 種類だけに絞っている。
            //
            // Task #81 (実機フィードバック「MakerWorldのメールで翻訳が一部
            // 効かない」): Task #61 のチャンク単位フォールバックは、ブロック
            // されたチャンクに含まれる無害な文まで道連れで原文のまま残して
            // いた。ブロックされたチャンクは `retryBlockedChunkBySentence`
            // でさらに文単位に分割し、1文ずつ再翻訳する（再帰は1段まで —
            // 文単位で再度ブロックされてもそれ以上は分割しない）。
            // `chunkHasBlockedContent[i]` は「このチャンクに1文でも原文の
            // まま残った」、`chunkFullyBlocked[i]` は「このチャンクは1文も
            // 翻訳できなかった」を表し、後者は「全チャンクがブロックされた
            // 場合のみ失敗」判定に、前者は段落単位の `wasBlocked` に使う。
            var translatedChunks: [String] = []
            translatedChunks.reserveCapacity(chunks.count)
            var chunkHasBlockedContent = [Bool](repeating: false, count: chunks.count)
            var chunkFullyBlocked = [Bool](repeating: false, count: chunks.count)
            for (index, chunk) in chunks.enumerated() {
                do {
                    translatedChunks.append(try await service.translate(chunk, from: sourceLanguage, to: targetLanguage))
                } catch let error as TranslationServiceError where error.isContentBlocked {
                    // F15 (2026-07-29 security scan): dropped `privacy:
                    // .public` — this interpolates a mail-content fragment
                    // (`logPrefix`), and `.public` persists it un-redacted
                    // into Console.app/sysdiagnose captures outside the
                    // app's sandbox, potentially including OTP/2FA codes.
                    // Default (`.private`) still redacts it in production
                    // while remaining visible to a debug-build/Xcode-
                    // attached session.
                    Self.logger.notice("chunk \(index) content-blocked, retrying by sentence: \(Self.logPrefix(chunk))")
                    let retry = try await retryBlockedChunkBySentence(chunk, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
                    translatedChunks.append(retry.text)
                    chunkHasBlockedContent[index] = retry.hasBlockedContent
                    chunkFullyBlocked[index] = retry.fullyBlocked
                }
            }
            // 全チャンクが1文も翻訳できなかった場合だけ失敗扱いにする —
            // 1文でも翻訳できていれば「一部スキップ」として成功扱いにし、
            // `MessageTranslationRecord.hasPartiallyBlockedContent` 経由で
            // UIが控えめな注記を出す (`docs/translation.md`参照)。
            if !chunks.isEmpty, chunkFullyBlocked.allSatisfy({ $0 }) {
                throw TranslationServiceError.contentBlocked(message: "every chunk was blocked by the model's safety guardrails")
            }

            var translatedParagraphs: [String] = []
            translatedParagraphs.reserveCapacity(paragraphs.count)
            var paragraphWasBlocked: [Bool] = []
            paragraphWasBlocked.reserveCapacity(paragraphs.count)
            var cursor = 0
            for count in chunkCounts {
                let range = cursor..<(cursor + count)
                let pieceTranslations = translatedChunks[range]
                translatedParagraphs.append(pieceTranslations.joined(separator: " "))
                paragraphWasBlocked.append(range.contains { chunkHasBlockedContent[$0] })
                cursor += count
            }

            var aligned: [TranslatedParagraph] = []
            aligned.reserveCapacity(paragraphs.count)
            for i in 0..<paragraphs.count {
                aligned.append(TranslatedParagraph(original: paragraphs[i], translated: translatedParagraphs[i], wasBlocked: paragraphWasBlocked[i]))
            }

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
            Self.logger.notice("translateAligned: messageId=\(messageId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return .failed(message: error.userFacingMessage)
        } catch {
            let nsError = error as NSError
            Self.logger.notice("translateAligned: messageId=\(messageId, privacy: .public) failed (non-TranslationServiceError): domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            return .failed(message: error.localizedDescription)
        }
    }

    /// Task #81: retries a guardrail-blocked chunk one sentence at a time.
    /// `SentenceSplitter.split(chunk)` yields the smallest retry unit this
    /// method goes to — a sentence that's itself still blocked keeps its
    /// own original text rather than being split further (words/clauses),
    /// which is the "recursion is one level deep" limit called for by the
    /// real-device report this exists to fix (a chunk that's already a
    /// single sentence-like unit, i.e. `sentences.count <= 1`, can't be
    /// split any smaller either, so it falls straight back to the whole
    /// chunk's original text — identical to the pre-Task #81 behavior for
    /// that case).
    ///
    /// A non-`contentBlocked` error from `service.translate` (e.g.
    /// `.tooLong`/`.unavailable`/another `.failed`) is intentionally *not*
    /// caught here — same tolerance boundary as the chunk-level loop in
    /// `translateAligned` above, it propagates out to that method's own
    /// `catch` and fails the whole translation rather than being silently
    /// treated as "blocked".
    ///
    /// Returns the rejoined chunk text, whether *any* sentence in it
    /// remained untranslated (feeds `chunkHasBlockedContent`, which in turn
    /// decides `TranslatedParagraph.wasBlocked`), and whether *every*
    /// sentence remained untranslated (feeds `chunkFullyBlocked`, which
    /// decides the "every chunk blocked" total-failure check).
    private func retryBlockedChunkBySentence(
        _ chunk: String,
        sourceLanguage: TranslationLanguage,
        targetLanguage: TranslationLanguage
    ) async throws -> (text: String, hasBlockedContent: Bool, fullyBlocked: Bool) {
        let sentences = SentenceSplitter.split(chunk)
        guard sentences.count > 1 else {
            // F15: see the identical note above — dropped `privacy: .public`
            // on this mail-content fragment too.
            Self.logger.notice("chunk has no further sentence boundary, kept original: \(Self.logPrefix(chunk))")
            return (chunk, true, true)
        }

        var translatedSentences: [String] = []
        translatedSentences.reserveCapacity(sentences.count)
        var blockedCount = 0
        for sentence in sentences {
            do {
                translatedSentences.append(try await service.translate(sentence, from: sourceLanguage, to: targetLanguage))
            } catch let error as TranslationServiceError where error.isContentBlocked {
                // F15: see the identical note above — dropped `privacy:
                // .public` on this mail-content fragment too.
                Self.logger.notice("sentence content-blocked, kept original: \(Self.logPrefix(sentence))")
                translatedSentences.append(sentence)
                blockedCount += 1
            }
        }
        return (translatedSentences.joined(separator: " "), blockedCount > 0, blockedCount == sentences.count)
    }

    /// Task #81: OSLog category for guardrail-retry diagnostics — real-
    /// device reports of "translation doesn't work for this one mail" are
    /// otherwise unreproducible from a bug report alone, since the
    /// guardrail's trigger condition isn't documented by Apple; logging
    /// which chunk/sentence got blocked (truncated, see `logPrefix`) lets a
    /// follow-up sysdiagnose narrow down what actually tripped it.
    private static let logger = Logger(subsystem: "com.mtkg.otegami", category: "MessageTranslator")

    /// First 20 characters of `text` — enough to identify which
    /// chunk/sentence a log line is about without logging a user's full
    /// mail content to the system log.
    private static func logPrefix(_ text: String) -> String {
        String(text.prefix(20))
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
