import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

@Suite("SearchQuery")
struct SearchQueryTests {
    private func makeAccountAndMailbox(db: Database, suffix: String) throws -> (accountId: String, mailboxId: Int64) {
        let account = AccountRecord(
            displayName: "Test \(suffix)", email: "t\(suffix)@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t\(suffix)@x.test"
        )
        try account.insert(db)
        var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
        mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
        return (account.id, mailbox.id!)
    }

    /// Inserts a message, its own single-member thread (threading itself is
    /// `ThreadAssigner`'s job, already covered by `ThreadAssignerTests` —
    /// this just needs *some* thread for `SearchQuery.threadSummaries` to
    /// group into), and its `messageSearchIndex` row, the same way
    /// `AccountSyncer.upsert`/`BodyFetcher.fetchBody` do together.
    @discardableResult
    private func insertMessage(
        db: Database,
        accountId: String,
        mailboxId: Int64,
        uid: Int64,
        subject: String?,
        plainText: String? = nil,
        from: [EmailAddress] = [],
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> (messageId: Int64, threadId: Int64) {
        var message = MessageRecord(
            mailboxId: mailboxId,
            uid: uid,
            subject: subject,
            fromAddresses: from,
            fromText: FTSIndexer.composeFromText(from),
            date: date,
            internalDate: date
        )
        try message.insert(db)
        let messageId = message.id!

        if let plainText {
            let body = MessageBodyRecord(messageId: messageId, plainText: plainText)
            try body.insert(db)
        }

        var thread = ThreadRecord(accountId: accountId, normalizedSubject: subject, lastMessageDate: date, messageCount: 1)
        try thread.insert(db)
        message.threadId = thread.id
        try message.update(db, columns: [Column("threadId")])

        try FTSIndexer.reindex(messageId: messageId, db: db)
        return (messageId, thread.id!)
    }

    // MARK: - FTS path (query length >= 3 Characters)

    @Test("a 3+ character Japanese query hits via FTS trigram MATCH")
    func japaneseThreeCharacterQueryHitsViaFTS() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        let (messageId, _) = try database.dbWriter.write { db in
            try insertMessage(db: db, accountId: accountId, mailboxId: mailboxId, uid: 1, subject: "明日の打ち合わせについて")
        }

        let results = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "打ち合わせ", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(results.contains { $0.latestMessage?.id == messageId })
    }

    @Test("an English query matches case-insensitively (FTS5 trigram ASCII case folding)")
    func englishQueryIsCaseInsensitive() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        let (messageId, _) = try database.dbWriter.write { db in
            try insertMessage(db: db, accountId: accountId, mailboxId: mailboxId, uid: 1, subject: "Hello World")
        }

        let results = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "hello", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(results.contains { $0.latestMessage?.id == messageId })
    }

    @Test("multiple space-separated words require all of them (AND), regardless of column")
    func multipleWordsAreCombinedWithAnd() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        let (messageId, _) = try database.dbWriter.write { db in
            try insertMessage(db: db, accountId: accountId, mailboxId: mailboxId, uid: 1, subject: "Weekly Report", plainText: "Attached is the summary document.")
        }

        let bothPresent = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "weekly summary", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(bothPresent.contains { $0.latestMessage?.id == messageId })

        let oneMissing = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "weekly zzzznotfound", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(oneMissing.isEmpty)
    }

    // MARK: - Which column hit (subject-only / body-only / from-only)

    @Test("a query matching only the subject still hits, and doesn't cross-match an unrelated message")
    func subjectOnlyHit() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        let (subjectHitId, _) = try database.dbWriter.write { db in
            try insertMessage(db: db, accountId: accountId, mailboxId: mailboxId, uid: 1, subject: "Quarterly Budget Review", plainText: "See you then.")
        }
        _ = try database.dbWriter.write { db in
            try insertMessage(db: db, accountId: accountId, mailboxId: mailboxId, uid: 2, subject: "Lunch plans", plainText: "No budget content here.")
        }

        let results = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "quarterly", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(results.map { $0.latestMessage?.id } == [subjectHitId])
    }

    @Test("a query matching only the plain-text body still hits")
    func bodyOnlyHit() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        let (bodyHitId, _) = try database.dbWriter.write { db in
            try insertMessage(db: db, accountId: accountId, mailboxId: mailboxId, uid: 1, subject: "Hi", plainText: "The launch date has been confirmed for Friday.")
        }

        let results = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "confirmed", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(results.map { $0.latestMessage?.id } == [bodyHitId])
    }

    @Test("a query matching only the sender's name/address still hits")
    func fromOnlyHit() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        let (fromHitId, _) = try database.dbWriter.write { db in
            try insertMessage(
                db: db, accountId: accountId, mailboxId: mailboxId, uid: 1,
                subject: "Meeting notes", plainText: "Nothing special.",
                from: [EmailAddress(name: "Kobayashi Yuki", address: "kobayashi@otegami.test")]
            )
        }

        let results = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "kobayashi", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(results.map { $0.latestMessage?.id } == [fromHitId])
    }

    // MARK: - LIKE fallback (query length < 3 Characters)

    @Test("a 2-character Japanese query hits via the LIKE fallback")
    func japaneseTwoCharacterQueryHitsViaLIKE() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        let (messageId, _) = try database.dbWriter.write { db in
            try insertMessage(db: db, accountId: accountId, mailboxId: mailboxId, uid: 1, subject: "本日の会議は延期になりました")
        }

        let results = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "会議", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(results.contains { $0.latestMessage?.id == messageId })
    }

    @Test("boundary: a query below the FTS minimum length finds nothing via a raw trigram MATCH, but SearchQuery's LIKE fallback finds it")
    func boundaryBelowMinimumFTSLengthIsRescuedByLIKE() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        let (messageId, _) = try database.dbWriter.write { db in
            try insertMessage(db: db, accountId: accountId, mailboxId: mailboxId, uid: 1, subject: "会議の件について")
        }
        let query = "会議"
        #expect(query.count < SearchQuery.minimumFTSLength)

        // Confirms *why* the fallback exists: a raw trigram MATCH on a
        // too-short query tokenizes to nothing, so it can never find this
        // message on its own.
        try database.dbWriter.read { db in
            let raw = try Int64.fetchAll(
                db,
                sql: "SELECT rowid FROM messageSearchIndex WHERE messageSearchIndex MATCH ?",
                arguments: [SearchQuery.ftsMatchExpression(for: query)]
            )
            #expect(raw.isEmpty)
        }

        // SearchQuery itself, going through its length-based dispatch, does
        // find it (via LIKE).
        let results = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: query, scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(results.contains { $0.latestMessage?.id == messageId })
    }

    @Test("likeEscape escapes %, _, and backslash so a literal query can't act as a LIKE wildcard")
    func likeEscapeEscapesWildcards() {
        #expect(SearchQuery.likeEscape("50%") == "50\\%")
        #expect(SearchQuery.likeEscape("a_b") == "a\\_b")
        #expect(SearchQuery.likeEscape("a\\b") == "a\\\\b")
        #expect(SearchQuery.likeEscape("plain") == "plain")
    }

    @Test("a short query containing a literal % matches only that literal text, not as a wildcard")
    func shortQueryWithPercentIsTreatedLiterally() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        let (percentId, _) = try database.dbWriter.write { db in
            try insertMessage(db: db, accountId: accountId, mailboxId: mailboxId, uid: 1, subject: "100% done")
        }
        _ = try database.dbWriter.write { db in
            // If '%' in the query were left unescaped, this row (no literal
            // "0%" substring, but plenty for a wildcard '%' to swallow)
            // would spuriously match too.
            try insertMessage(db: db, accountId: accountId, mailboxId: mailboxId, uid: 2, subject: "100X done")
        }

        let query = "0%"
        #expect(query.count < SearchQuery.minimumFTSLength)
        let results = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: query, scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(results.map { $0.latestMessage?.id } == [percentId])
    }

    // MARK: - Deletion

    @Test("a deleted message's index row no longer matches")
    func deletedMessageIsNotFound() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        let (messageId, threadId) = try database.dbWriter.write { db in
            try insertMessage(db: db, accountId: accountId, mailboxId: mailboxId, uid: 1, subject: "後で消すメッセージ")
        }

        let beforeDelete = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "消すメッセージ", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(beforeDelete.contains { $0.latestMessage?.id == messageId })

        _ = try database.dbWriter.write { db in
            try FTSIndexer.delete(messageId: messageId, db: db)
            try MessageRecord.deleteOne(db, key: messageId)
            try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
        }

        let afterDelete = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "消すメッセージ", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(afterDelete.isEmpty)
    }

    // MARK: - Scope

    @Test("mailbox scope only returns that mailbox's messages; allAccounts scope spans every account")
    func scopeNarrowsToOneMailboxOrSpansAllAccounts() throws {
        let database = try AppDatabase.makeInMemory()
        let (account1, mailbox1) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        let (account2, mailbox2) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "2") }
        let (message1, _) = try database.dbWriter.write { db in
            try insertMessage(db: db, accountId: account1, mailboxId: mailbox1, uid: 1, subject: "共通キーワードその1")
        }
        let (message2, _) = try database.dbWriter.write { db in
            try insertMessage(db: db, accountId: account2, mailboxId: mailbox2, uid: 1, subject: "共通キーワードその2")
        }

        let scopedToMailbox1 = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "共通キーワード", scope: .mailbox(mailboxId: mailbox1), db: db)
        }
        #expect(scopedToMailbox1.map { $0.latestMessage?.id } == [message1])

        let acrossBothAccounts = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "共通キーワード", scope: .allAccounts(accountIds: [account1, account2]), db: db)
        }
        #expect(Set(acrossBothAccounts.compactMap { $0.latestMessage?.id }) == [message1, message2])
    }

    @Test("an empty or whitespace-only query returns no results")
    func emptyQueryReturnsNoResults() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        _ = try database.dbWriter.write { db in
            try insertMessage(db: db, accountId: accountId, mailboxId: mailboxId, uid: 1, subject: "何か")
        }

        for query in ["", "   ", "\n"] {
            let results = try database.dbWriter.read { db in
                try SearchQuery.threadSummaries(query: query, scope: .allAccounts(accountIds: [accountId]), db: db)
            }
            #expect(results.isEmpty)
        }
    }
}
