import Foundation
import GRDB
import Testing
import OtegamiCore
import OtegamiStore
import OtegamiTranslation
@testable import TranslationEngine

@Suite("MessageTranslator")
struct MessageTranslatorTests {
    /// Inserts a minimal account/mailbox/message row and returns the
    /// message's id — `MessageTranslator` only ever needs `messageId` (the
    /// foreign key `messageTranslation` cascades on), not the full
    /// `MessageRecord`.
    private func makeMessageId(database: AppDatabase) async throws -> Int64 {
        let account = AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
        try await database.dbWriter.write { db in try account.insert(db) }

        return try await database.dbWriter.write { db in
            var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var message = MessageRecord(mailboxId: mailbox.id!, uid: 1, internalDate: Date())
            try message.insert(db)
            return message.id!
        }
    }

    @Test("a cache miss calls the engine, persists the result, and returns .translated")
    func cacheMissTranslatesAndPersists() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService()
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        let state = await translator.translate(
            messageId: messageId,
            sourceText: "Hello team,\n\nThe report is attached.",
            sourceLanguage: .english,
            targetLanguage: .japanese
        )

        guard case .translated(let record) = state else {
            Issue.record("expected .translated, got \(state)")
            return
        }
        #expect(record.translatedText == "[ja] Hello team,\n\n[ja] The report is attached.")
        #expect(record.paragraphs == [
            TranslatedParagraph(original: "Hello team,", translated: "[ja] Hello team,"),
            TranslatedParagraph(original: "The report is attached.", translated: "[ja] The report is attached."),
        ])
        #expect(record.engineIdentifier == MessageTranslator.EngineIdentifier.fake)
        // Task #61: `translateAligned` now calls `service.translate` once
        // per chunk (not `translateParagraphs` once for the whole batch) so
        // a single guardrail-blocked chunk can be tolerated without failing
        // every other chunk — see `guardrailBlockedChunkIsToleratedAndOthersStillTranslate`
        // below. Two short paragraphs here means two chunks, so two calls.
        #expect(await service.translateCallCount == 2)
        #expect(await service.translateParagraphsCallCount == 0)

        // Compared field-by-field rather than `persisted == record`:
        // `translatedAt` defaults to an unrounded `Date()`, and GRDB's
        // default `Date` storage round-trips through millisecond-precision
        // text (see `AppDatabaseTests.savesAccount`'s doc comment for the
        // same caveat), so an exact `Date` equality check here would be
        // spuriously flaky.
        let persisted = try await database.dbWriter.read { db in
            try MessageTranslationRecord.fetchOne(db, key: messageId)
        }
        #expect(persisted?.messageId == record.messageId)
        #expect(persisted?.sourceLanguage == record.sourceLanguage)
        #expect(persisted?.targetLanguage == record.targetLanguage)
        #expect(persisted?.translatedText == record.translatedText)
        #expect(persisted?.paragraphs == record.paragraphs)
        #expect(persisted?.engineIdentifier == record.engineIdentifier)
    }

    @Test("a paragraph longer than the chunk limit is split, translated in pieces, and rejoined into one TranslatedParagraph")
    func longParagraphIsChunkedAndRejoined() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService()
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        // Three sentences that individually fit `TranslationChunker
        // .defaultMaxChunkLength` but together comfortably exceed it, so
        // this paragraph is guaranteed to be split into multiple chunks —
        // real-device motivation in `TranslationChunker`'s doc comment.
        let sentence = "This is a moderately long sentence about the quarterly report. "
        let longParagraph = String(repeating: sentence, count: 60).trimmingCharacters(in: .whitespaces)
        #expect(longParagraph.count > TranslationChunker.defaultMaxChunkLength)

        let sourceText = "Short intro.\n\n\(longParagraph)"
        let state = await translator.translate(
            messageId: messageId, sourceText: sourceText, sourceLanguage: .english, targetLanguage: .japanese
        )

        guard case .translated(let record) = state else {
            Issue.record("expected .translated, got \(state)")
            return
        }
        // Still exactly one `TranslatedParagraph` per original paragraph
        // (two: the short intro and the long one) — chunking is an
        // implementation detail the engine call sees, not something that
        // should fragment 1i's per-paragraph original/translated toggle.
        #expect(record.paragraphs.count == 2)
        #expect(record.paragraphs[0].original == "Short intro.")
        #expect(record.paragraphs[1].original == longParagraph)
        // `FakeTranslationService.deterministicTranslation` prefixes every
        // *piece* it's handed with "[ja] " independently — if the long
        // paragraph had gone through as one over-limit request it would
        // carry exactly one "[ja] " prefix; more than one proves the
        // engine actually received several chunks for this one paragraph,
        // which then got rejoined into a single `TranslatedParagraph`.
        let longParagraphPieceCount = record.paragraphs[1].translated.components(separatedBy: "[ja] ").count - 1
        #expect(longParagraphPieceCount > 1)
        // Task #61: `translateAligned` calls `service.translate` once per
        // chunk (not `translateParagraphs` once for the whole batch, which
        // is what let one guardrail-blocked chunk fail every other chunk —
        // see `guardrailBlockedChunkIsToleratedAndOthersStillTranslate`
        // below) — so the total call count is every chunk from every
        // paragraph: the short intro's one chunk plus the long paragraph's
        // `longParagraphPieceCount` pieces.
        #expect(await service.translateCallCount == 1 + longParagraphPieceCount)
        #expect(await service.translateParagraphsCallCount == 0)
    }

    @Test("a second call for the same message is served from cache, not the engine")
    func cacheHitSkipsEngine() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService()
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        let first = await translator.translate(messageId: messageId, sourceText: "Hello.", sourceLanguage: .english, targetLanguage: .japanese)
        let second = await translator.translate(messageId: messageId, sourceText: "Hello.", sourceLanguage: .english, targetLanguage: .japanese)

        // Compared by content, not full `MessageTranslationState` equality:
        // `first` is the freshly-constructed (unrounded `Date()`) record
        // from the cache-miss path, `second` is read back from the DB
        // (millisecond-rounded) on the cache-hit path — see the previous
        // test's doc comment on why an exact `Date` equality check would
        // be spuriously flaky. The one call to the engine either way is
        // the behavior actually under test.
        #expect(first.translatedRecord?.translatedText == second.translatedRecord?.translatedText)
        #expect(first.translatedRecord?.paragraphs == second.translatedRecord?.paragraphs)
        #expect(await service.translateCallCount == 1)
    }

    @Test("a cached row from a different engine is treated as a miss and re-translated")
    func differentEngineInvalidatesCache() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)

        let firstTranslator = MessageTranslator(database: database, service: FakeTranslationService(), engineIdentifier: "engine-a")
        _ = await firstTranslator.translate(messageId: messageId, sourceText: "Hello.", sourceLanguage: .english, targetLanguage: .japanese)

        let secondService = FakeTranslationService()
        let secondTranslator = MessageTranslator(database: database, service: secondService, engineIdentifier: "engine-b")
        let state = await secondTranslator.translate(messageId: messageId, sourceText: "Hello.", sourceLanguage: .english, targetLanguage: .japanese)

        guard case .translated(let record) = state else {
            Issue.record("expected .translated, got \(state)")
            return
        }
        #expect(record.engineIdentifier == "engine-b")
        #expect(await secondService.translateCallCount == 1)
    }

    @Test("engine failure resolves to .failed rather than throwing")
    func engineFailureResolvesToFailedState() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService(behavior: .failure(message: "model unavailable"))
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        let state = await translator.translate(messageId: messageId, sourceText: "Hello.", sourceLanguage: .english, targetLanguage: .japanese)
        // `.userFacingMessage` (not `.errorDescription`, which stays
        // English/log-oriented) — see `MessageTranslator.translate`'s catch
        // block and `TranslationServiceError.userFacingMessage`'s doc
        // comment for why the mapping happens here.
        #expect(state == .failed(message: TranslationServiceError.failed(message: "model unavailable").userFacingMessage))

        let persisted = try await database.dbWriter.read { db in
            try MessageTranslationRecord.fetchOne(db, key: messageId)
        }
        #expect(persisted == nil)
    }

    @Test("invalidate() drops the cached row so the next call re-translates")
    func invalidateForcesRetranslation() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService()
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        _ = await translator.translate(messageId: messageId, sourceText: "Hello.", sourceLanguage: .english, targetLanguage: .japanese)
        try await translator.invalidate(messageId: messageId)
        _ = await translator.translate(messageId: messageId, sourceText: "Hello.", sourceLanguage: .english, targetLanguage: .japanese)

        #expect(await service.translateCallCount == 2)
    }

    @Test("a guardrail-blocked chunk keeps its original text and doesn't fail the other chunks")
    func guardrailBlockedChunkIsToleratedAndOthersStillTranslate() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService()
        // Task #61 (実機フィードバック「無害なマーケティングメールなのに
        // "The model's safety guardrails were triggered." で翻訳全体が失敗
        // する」): 3段落中1段落だけがガードレール誤発動を起こしても、残り
        // 2段落は正常に翻訳され、全体としては `.translated` (成功) 扱いに
        // なることを確認する。
        await service.configureContentBlocked(for: ["This one triggers the guardrail."])
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        let sourceText = "First paragraph is fine.\n\nThis one triggers the guardrail.\n\nThird paragraph is also fine."
        let state = await translator.translate(messageId: messageId, sourceText: sourceText, sourceLanguage: .english, targetLanguage: .japanese)

        guard case .translated(let record) = state else {
            Issue.record("expected .translated (partial success), got \(state)")
            return
        }
        #expect(record.paragraphs.count == 3)
        #expect(record.paragraphs[0] == TranslatedParagraph(original: "First paragraph is fine.", translated: "[ja] First paragraph is fine.", wasBlocked: false))
        // The blocked paragraph's "translated" text is just its own
        // original, verbatim — not run through `deterministicTranslation`
        // — and flagged `wasBlocked: true` so the UI layer
        // (`MessageTranslationRecord.hasPartiallyBlockedContent`) can show
        // its modest "一部の文は翻訳できませんでした" note.
        #expect(record.paragraphs[1] == TranslatedParagraph(original: "This one triggers the guardrail.", translated: "This one triggers the guardrail.", wasBlocked: true))
        #expect(record.paragraphs[2] == TranslatedParagraph(original: "Third paragraph is also fine.", translated: "[ja] Third paragraph is also fine.", wasBlocked: false))
        #expect(record.hasPartiallyBlockedContent)
        // Every chunk was still individually attempted (the blocked one
        // included) — only its *result* was substituted, the call itself
        // wasn't skipped.
        #expect(await service.translateCallCount == 3)
    }

    @Test("every chunk being guardrail-blocked resolves to .failed, not a silently-empty .translated")
    func allChunksBlockedResolvesToFailed() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService()
        await service.configureContentBlocked(for: ["Only paragraph, also blocked."])
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        let state = await translator.translate(messageId: messageId, sourceText: "Only paragraph, also blocked.", sourceLanguage: .english, targetLanguage: .japanese)

        guard case .failed(let message) = state else {
            Issue.record("expected .failed when every chunk is blocked, got \(state)")
            return
        }
        #expect(message == TranslationServiceError.contentBlocked(message: "").userFacingMessage)

        let persisted = try await database.dbWriter.read { db in
            try MessageTranslationRecord.fetchOne(db, key: messageId)
        }
        #expect(persisted == nil)
    }

    @Test("a guardrail-blocked chunk is retried sentence-by-sentence so only the actually-blocked sentence stays original")
    func guardrailBlockedChunkRetriesBySentenceAndMostlyTranslates() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService()
        let sourceText = "First sentence is fine. This one triggers the guardrail. Third sentence is also fine."
        // Task #81 (実機フィードバック「MakerWorldのメールで翻訳が一部効か
        // ない」): the whole paragraph is one chunk (well under
        // `TranslationChunker.defaultMaxChunkLength`), and the chunk-level
        // call is blocked — simulating a chunk-wide guardrail misfire.
        // `translateAligned` now retries at sentence granularity instead of
        // discarding the whole chunk (Task #61's coarser prior behavior,
        // still covered by `guardrailBlockedChunkIsToleratedAndOthersStillTranslate`
        // below for the un-splittable single-sentence case).
        await service.configureContentBlocked(for: [sourceText, "This one triggers the guardrail."])
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        let state = await translator.translate(messageId: messageId, sourceText: sourceText, sourceLanguage: .english, targetLanguage: .japanese)

        guard case .translated(let record) = state else {
            Issue.record("expected .translated (partial success via sentence retry), got \(state)")
            return
        }
        #expect(record.paragraphs.count == 1)
        let paragraph = record.paragraphs[0]
        #expect(paragraph.original == sourceText)
        // The two innocuous sentences translate normally; only the middle
        // sentence keeps its own original text — Task #61's coarser
        // chunk-wide fallback would have discarded "First sentence is
        // fine."/"Third sentence is also fine." too, which is exactly the
        // real-device bug this retry fixes.
        #expect(paragraph.translated == "[ja] First sentence is fine. This one triggers the guardrail. [ja] Third sentence is also fine.")
        #expect(paragraph.wasBlocked)
        #expect(record.hasPartiallyBlockedContent)
        // 1 chunk-level call (blocked) + 3 sentence-level retry calls.
        #expect(await service.translateCallCount == 4)
    }

    @Test("when every sentence in a retried chunk is still blocked, that paragraph keeps its original text (unchanged) and stays flagged blocked")
    func guardrailBlockedChunkFullyBlockedAtSentenceLevelKeepsOriginal() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService()
        let blockedParagraph = "This sentence is blocked. This other sentence is also blocked."
        await service.configureContentBlocked(for: [
            blockedParagraph,
            "This sentence is blocked.",
            "This other sentence is also blocked.",
        ])
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        let sourceText = "First paragraph is fine.\n\n\(blockedParagraph)\n\nThird paragraph is also fine."
        let state = await translator.translate(messageId: messageId, sourceText: sourceText, sourceLanguage: .english, targetLanguage: .japanese)

        guard case .translated(let record) = state else {
            Issue.record("expected .translated (other paragraphs still succeed), got \(state)")
            return
        }
        #expect(record.paragraphs.count == 3)
        #expect(record.paragraphs[0] == TranslatedParagraph(original: "First paragraph is fine.", translated: "[ja] First paragraph is fine.", wasBlocked: false))
        // Both sentences remained blocked even after the sentence-level
        // retry — the paragraph's "translated" text is just its own
        // original, verbatim, same as Task #61's un-splittable single-
        // sentence case, just reached via two blocked sentences instead of
        // one blocked chunk.
        #expect(record.paragraphs[1] == TranslatedParagraph(original: blockedParagraph, translated: blockedParagraph, wasBlocked: true))
        #expect(record.paragraphs[2] == TranslatedParagraph(original: "Third paragraph is also fine.", translated: "[ja] Third paragraph is also fine.", wasBlocked: false))
        #expect(record.hasPartiallyBlockedContent)
        // 3 chunk-level calls (one per paragraph) + 2 sentence-level retry
        // calls for the fully-blocked paragraph's chunk.
        #expect(await service.translateCallCount == 5)
    }

    @Test("ordinary multi-sentence text makes exactly one engine call per chunk — the sentence retry path never runs without a guardrail block")
    func normalMultiSentenceChunkIsNotExplodedIntoSentenceCalls() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService()
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        let sourceText = "First sentence is fine. Second sentence is also fine. Third sentence is fine too."
        let state = await translator.translate(messageId: messageId, sourceText: sourceText, sourceLanguage: .english, targetLanguage: .japanese)

        guard case .translated(let record) = state else {
            Issue.record("expected .translated, got \(state)")
            return
        }
        #expect(record.paragraphs.count == 1)
        #expect(record.paragraphs[0] == TranslatedParagraph(original: sourceText, translated: "[ja] \(sourceText)", wasBlocked: false))
        #expect(!record.hasPartiallyBlockedContent)
        // Task #81's sentence-level retry only ever runs after a chunk-
        // level `.contentBlocked` — an ordinary chunk with no guardrail
        // involvement at all is still translated as one whole chunk, one
        // engine call, exactly as before Task #81 (non-regression).
        #expect(await service.translateCallCount == 1)
    }

    @Test("availability forwards the underlying service's availability")
    func availabilityForwardsService() async throws {
        let database = try AppDatabase.makeInMemory()
        let service = FakeTranslationService(availability: .unavailable(reason: .deviceNotEligible))
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)
        #expect(translator.availability == .unavailable(reason: .deviceNotEligible))
    }

    @Test("translateStream passes through without touching the cache")
    func translateStreamBypassesCache() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService()
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        var lastChunk: String?
        for try await chunk in translator.translateStream("Hello world", from: .english, to: .japanese) {
            lastChunk = chunk
        }
        #expect(lastChunk == "[ja] Hello world")

        let persisted = try await database.dbWriter.read { db in
            try MessageTranslationRecord.fetchOne(db, key: messageId)
        }
        #expect(persisted == nil)
    }
}
