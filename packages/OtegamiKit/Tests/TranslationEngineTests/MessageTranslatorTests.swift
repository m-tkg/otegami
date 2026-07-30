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
        // Phase 5続報4 (2026-07-30): `translateAligned` now tries
        // `service.translateParagraphs` (one request for every chunk) first
        // — with nothing guardrail-blocked, that single batch call succeeds
        // and the per-chunk fallback (`service.translate`, one call per
        // chunk — see `guardrailBlockedChunkIsToleratedAndOthersStillTranslate`
        // below for when that path actually runs) never executes at all.
        #expect(await service.translateCallCount == 0)
        #expect(await service.translateParagraphsCallCount == 1)

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
        // Phase 5続報4: no guardrail block configured, so the single batch
        // `translateParagraphs` call (carrying every chunk from every
        // paragraph — the short intro's one chunk plus the long paragraph's
        // `longParagraphPieceCount` pieces — in one request) succeeds and
        // the per-chunk fallback never runs.
        #expect(await service.translateCallCount == 0)
        #expect(await service.translateParagraphsCallCount == 1)
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
        // be spuriously flaky. The one batch call to the engine (cache miss
        // on the first `translate`; the second is a cache hit and never
        // reaches the engine at all) is the behavior actually under test.
        #expect(first.translatedRecord?.translatedText == second.translatedRecord?.translatedText)
        #expect(first.translatedRecord?.paragraphs == second.translatedRecord?.paragraphs)
        #expect(await service.translateCallCount == 0)
        #expect(await service.translateParagraphsCallCount == 1)
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
        #expect(await secondService.translateCallCount == 0)
        #expect(await secondService.translateParagraphsCallCount == 1)
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

        // Two separate `translateAligned` calls (cache miss both times,
        // thanks to `invalidate`), each with one short paragraph — one
        // batch call per `translate`.
        #expect(await service.translateCallCount == 0)
        #expect(await service.translateParagraphsCallCount == 2)
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
        // Phase 5続報4: the batch `translateParagraphs` attempt (1 call)
        // fails as a whole because one of the 3 chunks is blocked, so
        // `translateAligned` falls back to the per-chunk path — every chunk
        // is still individually attempted there (the blocked one included)
        // — only its *result* was substituted, the call itself wasn't
        // skipped.
        #expect(await service.translateParagraphsCallCount == 1)
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
        // The batch attempt (1 chunk, blocked) fails as a whole, falls back
        // to the per-chunk path (1 call, also blocked) — same outcome.
        #expect(await service.translateParagraphsCallCount == 1)
        #expect(await service.translateCallCount == 1)
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
        // 1 failed batch attempt, falls back to: 1 chunk-level call
        // (blocked) + 3 sentence-level retry calls.
        #expect(await service.translateParagraphsCallCount == 1)
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
        // 1 failed batch attempt, falls back to: 3 chunk-level calls (one
        // per paragraph) + 2 sentence-level retry calls for the
        // fully-blocked paragraph's chunk.
        #expect(await service.translateParagraphsCallCount == 1)
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
        // involvement at all is still translated as one whole chunk, via
        // the single batch `translateParagraphs` call (Phase 5続報4), never
        // falling back to the per-chunk/sentence path.
        #expect(await service.translateCallCount == 0)
        #expect(await service.translateParagraphsCallCount == 1)
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

    // MARK: - Phase 5 (2026-07-30, real-device log `dd58453`): empty/blank
    // input must never reach the engine as an empty batch — that's what
    // produced `TranslationErrorDomain Code=21` ("Client asked to translate
    // batch of 0 inputs") on a device where the language packs were
    // actually already downloaded, which then got misdiagnosed further
    // upstream as "language pack not downloaded".

    @Test("empty source text resolves to a clear 'nothing to translate' failure without calling the engine")
    func emptySourceTextDoesNotCallEngine() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService()
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        let state = await translator.translate(messageId: messageId, sourceText: "", sourceLanguage: .english, targetLanguage: .japanese)

        #expect(state == .insufficientInput(message: MessageTranslator.noTranslatableContentMessage))
        #expect(await service.translateCallCount == 0)
    }

    @Test("whitespace-only source text resolves to the same 'nothing to translate' failure without calling the engine")
    func whitespaceOnlySourceTextDoesNotCallEngine() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService()
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        let state = await translator.translate(messageId: messageId, sourceText: "   \n\t  ", sourceLanguage: .english, targetLanguage: .japanese)

        #expect(state == .insufficientInput(message: MessageTranslator.noTranslatableContentMessage))
        #expect(await service.translateCallCount == 0)
    }

    @Test("an empty HTML text-node array resolves to the same failure without calling the engine")
    func emptyHTMLTextNodesDoesNotCallEngine() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService()
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        let state = await translator.translateHTMLTextNodes(messageId: messageId, texts: [], sourceLanguage: .english, targetLanguage: .japanese)

        #expect(state == .insufficientInput(message: MessageTranslator.noTranslatableContentMessage))
        #expect(await service.translateCallCount == 0)
    }

    @Test("HTML text nodes that are all whitespace/invisible-only resolve to the same failure without calling the engine")
    func blankOnlyHTMLTextNodesDoesNotCallEngine() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService()
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        // A single zero-width space is exactly the real-device shape (a bare
        // DOM text node that's non-empty by Swift's `isEmpty` and passes a
        // JS `.trim().length > 0` check, but has no actual translatable
        // content) that produced `TranslationErrorDomain Code=21` on-device.
        let state = await translator.translateHTMLTextNodes(messageId: messageId, texts: ["\u{200B}", "  ", "\n"], sourceLanguage: .english, targetLanguage: .japanese)

        #expect(state == .insufficientInput(message: MessageTranslator.noTranslatableContentMessage))
        #expect(await service.translateCallCount == 0)
    }

    @Test("HTML text nodes mixing real content with blank/invisible ones only translate the real ones, keeping alignment")
    func mixedBlankAndRealHTMLTextNodesTranslatesOnlyRealOnes() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService()
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        let state = await translator.translateHTMLTextNodes(
            messageId: messageId,
            texts: ["Hello", "\u{200B}", "World"],
            sourceLanguage: .english,
            targetLanguage: .japanese
        )

        guard case .translated(let record) = state else {
            Issue.record("expected .translated, got \(state)")
            return
        }
        #expect(record.paragraphs == [
            TranslatedParagraph(original: "Hello", translated: "[ja] Hello"),
            TranslatedParagraph(original: "\u{200B}", translated: ""),
            TranslatedParagraph(original: "World", translated: "[ja] World"),
        ])
        // Only the two real-content nodes ever reach the engine — the
        // zero-width-space node contributes zero chunks (`TranslationChunker
        // .chunk`'s `isBlank` check) and is never sent as part of the batch
        // request.
        #expect(await service.translateCallCount == 0)
        #expect(await service.translateParagraphsCallCount == 1)
    }

    // MARK: - Phase 5続報 (2026-07-30, 実機フィードバック f7b623f 適用後):
    // "翻訳元の言語を判定できませんでした" という別の文言で同じ根本原因
    // (実質空の入力) が表面化し、9e74419 の文字列一致フォールバックを
    // すり抜けた実機報告への対応 — `.insufficientInput`という独立ケースが
    // ちゃんと型として伝播することを確認する。
    //
    // 「合計文字数が閾値未満なら事前に弾く」という追加ガードは一度実装した
    // が、既存の短い正当な入力 ("Hello."等) を巻き込んで壊すことが判明し
    // 撤回した (`translateAligned`のdoc comment参照) — 短いが非空の入力は
    // 実際にエンジンへ渡り、エンジン自身が「わからない」と答えた場合だけ
    // `.insufficientInput`になる、という以下のテストがその方針を確認する。

    @Test("short but non-blank input still reaches the engine (no pre-emptive length rejection) and translates normally when the engine accepts it")
    func shortNonBlankInputStillReachesEngine() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService()
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        // "Hi" + "OK" — short, but real, non-blank content a user might
        // genuinely want translated; must not be blocked before ever
        // asking the engine.
        let state = await translator.translateHTMLTextNodes(messageId: messageId, texts: ["Hi", "OK"], sourceLanguage: .english, targetLanguage: .japanese)

        guard case .translated = state else {
            Issue.record("expected .translated, got \(state)")
            return
        }
        #expect(await service.translateCallCount == 0)
        #expect(await service.translateParagraphsCallCount == 1)
    }

    @Test("a TranslationService-reported .insufficientInput propagates through translateAligned unchanged, not collapsed into .failed")
    func engineInsufficientInputFailurePropagatesAsInsufficientInput() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        // 2026-07-30 (Phase 5再訂正): `AppleTranslationService` itself no
        // longer ever throws `.insufficientInput` (three rounds of trying
        // to infer it from `TranslationError`/raw NSError codes each turned
        // out wrong on the next real device — see `AppleTranslationService
        // .mapEngineError`'s doc comment) — the only remaining source is
        // `MessageTranslator.translateAligned`'s own pre-check
        // (`chunks.isEmpty`, tested elsewhere in this file). This test
        // instead exercises `translateAligned`'s classification logic
        // directly via `FakeTranslationService`, confirming that *if* some
        // `TranslationService` conformer ever does throw this case, it
        // still propagates through as `.insufficientInput`, not flattened
        // to `.failed`.
        let service = FakeTranslationService(behavior: .insufficientInput(message: "翻訳元の言語を判定できませんでした"))
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        let state = await translator.translate(messageId: messageId, sourceText: "Some reasonably long line of text here.", sourceLanguage: .english, targetLanguage: .japanese)

        guard case .insufficientInput(let message) = state else {
            Issue.record("expected .insufficientInput, got \(state)")
            return
        }
        #expect(message == "翻訳元の言語を判定できませんでした")
    }
}
