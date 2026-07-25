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
        #expect(await secondService.translateParagraphsCallCount == 1)
    }

    @Test("engine failure resolves to .failed rather than throwing")
    func engineFailureResolvesToFailedState() async throws {
        let database = try AppDatabase.makeInMemory()
        let messageId = try await makeMessageId(database: database)
        let service = FakeTranslationService(behavior: .failure(message: "model unavailable"))
        let translator = MessageTranslator(database: database, service: service, engineIdentifier: MessageTranslator.EngineIdentifier.fake)

        let state = await translator.translate(messageId: messageId, sourceText: "Hello.", sourceLanguage: .english, targetLanguage: .japanese)
        #expect(state == .failed(message: TranslationServiceError.failed(message: "model unavailable").errorDescription!))

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

        #expect(await service.translateParagraphsCallCount == 2)
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
