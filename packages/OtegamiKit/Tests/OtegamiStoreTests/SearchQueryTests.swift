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
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> (messageId: Int64, threadId: Int64) {
        var message = MessageRecord(
            mailboxId: mailboxId,
            uid: uid,
            subject: subject,
            fromAddresses: from,
            toAddresses: to,
            ccAddresses: cc,
            fromText: FTSIndexer.composeFromText(from),
            toText: FTSIndexer.composeFromText(to),
            ccText: FTSIndexer.composeFromText(cc),
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

    // MARK: - Header operators (新画面構成: from:/to:/cc:/subject:)

    @Test("parse splits recognized operator:value tokens out of the free text, case-insensitively")
    func parseSplitsOperatorsFromFreeText() {
        let parsed = SearchQuery.parse("From:aiko@otegami.test budget To:boss@otegami.test report Subject:Q3 Cc:cc@otegami.test")
        #expect(parsed.from == "aiko@otegami.test")
        #expect(parsed.to == "boss@otegami.test")
        #expect(parsed.cc == "cc@otegami.test")
        #expect(parsed.subject == "Q3")
        #expect(parsed.freeText == "budget report")
    }

    @Test("parse treats a bare 'from:' with no value as free text, not an operator")
    func parseTreatsEmptyOperatorValueAsFreeText() {
        let parsed = SearchQuery.parse("from: budget")
        #expect(parsed.from == nil)
        #expect(parsed.freeText == "from: budget")
    }

    @Test("parse: a repeated operator keeps only its last occurrence")
    func parseRepeatedOperatorKeepsLastValue() {
        let parsed = SearchQuery.parse("from:a@x.test from:b@x.test")
        #expect(parsed.from == "b@x.test")
    }

    @Test("from: narrows results to the sender's address, independent of the free-text match")
    func fromOperatorNarrowsToSender() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        let (matchId, _) = try database.dbWriter.write { db in
            try insertMessage(
                db: db, accountId: accountId, mailboxId: mailboxId, uid: 1,
                subject: "Budget review", from: [EmailAddress(address: "aiko@otegami.test")]
            )
        }
        _ = try database.dbWriter.write { db in
            try insertMessage(
                db: db, accountId: accountId, mailboxId: mailboxId, uid: 2,
                subject: "Budget review", from: [EmailAddress(address: "someone-else@otegami.test")]
            )
        }

        let results = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "from:aiko@otegami.test budget", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(results.map { $0.latestMessage?.id } == [matchId])
    }

    @Test("an operator-only query (no free text) still runs, matched purely on the operator")
    func operatorOnlyQueryRunsWithNoFreeText() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        let (matchId, _) = try database.dbWriter.write { db in
            try insertMessage(
                db: db, accountId: accountId, mailboxId: mailboxId, uid: 1,
                subject: "Anything", from: [EmailAddress(address: "aiko@otegami.test")]
            )
        }

        let results = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "from:aiko@otegami.test", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(results.map { $0.latestMessage?.id } == [matchId])
    }

    @Test("to: and cc: each narrow independently, and subject: only matches the subject column")
    func toCcSubjectOperatorsMatchTheirOwnColumn() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        let (toMatchId, _) = try database.dbWriter.write { db in
            try insertMessage(
                db: db, accountId: accountId, mailboxId: mailboxId, uid: 1,
                subject: "Weekly sync", to: [EmailAddress(address: "team@otegami.test")]
            )
        }
        let (ccMatchId, _) = try database.dbWriter.write { db in
            try insertMessage(
                db: db, accountId: accountId, mailboxId: mailboxId, uid: 2,
                subject: "FYI", cc: [EmailAddress(address: "manager@otegami.test")]
            )
        }

        let toResults = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "to:team@otegami.test", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(toResults.map { $0.latestMessage?.id } == [toMatchId])

        let ccResults = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "cc:manager@otegami.test", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(ccResults.map { $0.latestMessage?.id } == [ccMatchId])

        let subjectResults = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "subject:Weekly", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(subjectResults.map { $0.latestMessage?.id } == [toMatchId])
    }

    @Test("combining an operator with free text requires both (AND)")
    func operatorAndFreeTextAreCombinedWithAnd() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        _ = try database.dbWriter.write { db in
            try insertMessage(
                db: db, accountId: accountId, mailboxId: mailboxId, uid: 1,
                subject: "Lunch plans", from: [EmailAddress(address: "aiko@otegami.test")]
            )
        }

        let results = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "from:aiko@otegami.test zzzznotfound", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(results.isEmpty)
    }

    // MARK: - flatMessageSummaries (B3 フラット表示 + 検索)
    //
    // 実機バグ報告「スレッド表示をオフにしてるのに、スレッドで表示される
    // ことがある」の再発防止テスト — 検索は`ThreadQuery`の他の呼び出しと
    // 違い、この修正まで`isFlatMode`を一切見ていなかった唯一の経路だった。

    /// Adds a second message to an *existing* thread — `insertMessage`
    /// above always creates its own single-member thread (fine for every
    /// grouped-mode test, which never needs two messages sharing one real
    /// thread), but this suite's flat-mode regression test specifically
    /// needs two matching messages inside the *same* thread to prove
    /// `flatMessageSummaries` keeps them as two separate rows rather than
    /// collapsing them the way `threadSummaries` deliberately does.
    @discardableResult
    private func insertMessageIntoThread(
        db: Database, accountId: String, mailboxId: Int64, threadId: Int64, uid: Int64, subject: String?,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> Int64 {
        var message = MessageRecord(
            mailboxId: mailboxId, uid: uid, subject: subject, date: date, internalDate: date, threadId: threadId
        )
        try message.insert(db)
        try FTSIndexer.reindex(messageId: message.id!, db: db)
        return message.id!
    }

    @Test("flatMessageSummaries returns one row per matching message, even when both share the same real thread")
    func flatMessageSummariesKeepsEachMessageAsItsOwnRow() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "1") }
        let (firstId, threadId) = try database.dbWriter.write { db in
            try insertMessage(db: db, accountId: accountId, mailboxId: mailboxId, uid: 1, subject: "来週のランチについて")
        }
        let secondId = try database.dbWriter.write { db in
            try insertMessageIntoThread(db: db, accountId: accountId, mailboxId: mailboxId, threadId: threadId, uid: 2, subject: "Re: 来週のランチについて")
        }

        // グループ化モード (既定): 同じスレッドの2通は1行にまとまる —
        // このテストの前提を確認するベースライン。
        let grouped = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "ランチ", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(grouped.count == 1)
        #expect(grouped.first?.thread.id == threadId)

        // フラットモード: 同じ検索でも1メッセージ1行 — `ThreadQuery
        // .flatSummaries`/`unifiedInboxFlatSummaries`と同じ「スレッド表示
        // オフなら常にメッセージ単位」という約束を検索結果にも適用する。
        let flat = try database.dbWriter.read { db in
            try SearchQuery.flatMessageSummaries(query: "ランチ", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(flat.count == 2)
        #expect(Set(flat.compactMap(\.singleMessageId)) == Set([firstId, secondId]))
        // `messageCount == 1`/`singleMessageId != nil` on every row — the
        // same "thread of one" shape `ThreadSummary.init(flatMessage:
        // accountId:)` gives every other flat-mode row, so `ThreadRowView`/
        // `MessageListRow` render these identically to a flat list row
        // with zero further changes.
        for summary in flat {
            #expect(summary.thread.messageCount == 1)
            #expect(summary.singleMessageId != nil)
        }
    }

    @Test("flatMessageSummaries collapses one Gmail message synced into INBOX and All Mail")
    func flatMessageSummariesDeduplicatesGmailMailboxMemberships() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, inboxId) = try database.dbWriter.write { db in
            try makeAccountAndMailbox(db: db, suffix: "gmail")
        }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let inboxMessageId = try database.dbWriter.write { db -> Int64 in
            var allMail = MailboxRecord(
                accountId: accountId, path: "[Gmail]/All Mail", displayPath: "All Mail", role: .all
            )
            allMail = try allMail.upsertAndFetch(db, onConflict: ["accountId", "path"])

            var thread = ThreadRecord(
                accountId: accountId, normalizedSubject: "領収書", lastMessageDate: base, messageCount: 1
            )
            try thread.insert(db)
            var allMailMessage = MessageRecord(
                mailboxId: allMail.id!, uid: 10, subject: "楽天 領収書", date: base,
                internalDate: base, gmailMessageId: 42, threadId: thread.id
            )
            try allMailMessage.insert(db)
            try FTSIndexer.reindex(messageId: allMailMessage.id!, db: db)

            var inboxMessage = MessageRecord(
                mailboxId: inboxId, uid: 20, subject: "楽天 領収書", date: base,
                internalDate: base, gmailMessageId: 42, threadId: thread.id
            )
            try inboxMessage.insert(db)
            try FTSIndexer.reindex(messageId: inboxMessage.id!, db: db)
            return inboxMessage.id!
        }

        let results = try database.dbWriter.read { db in
            try SearchQuery.flatMessageSummaries(
                query: "楽天", scope: .allAccounts(accountIds: [accountId]), db: db
            )
        }

        #expect(results.map(\.singleMessageId) == [inboxMessageId])
    }

    @Test("flatMessageSummaries returns no rows for a non-matching query, and respects mailbox scope")
    func flatMessageSummariesRespectsScopeAndEmptyQuery() throws {
        let database = try AppDatabase.makeInMemory()
        let (accountIdA, mailboxIdA) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "a") }
        let (accountIdB, mailboxIdB) = try database.dbWriter.write { db in try makeAccountAndMailbox(db: db, suffix: "b") }
        let (matchIdA, _) = try database.dbWriter.write { db in
            try insertMessage(db: db, accountId: accountIdA, mailboxId: mailboxIdA, uid: 1, subject: "Quarterly Budget")
        }
        _ = try database.dbWriter.write { db in
            try insertMessage(db: db, accountId: accountIdB, mailboxId: mailboxIdB, uid: 1, subject: "Quarterly Budget")
        }

        let scoped = try database.dbWriter.read { db in
            try SearchQuery.flatMessageSummaries(query: "quarterly", scope: .mailbox(mailboxId: mailboxIdA), db: db)
        }
        #expect(scoped.map(\.singleMessageId) == [matchIdA])

        let noMatch = try database.dbWriter.read { db in
            try SearchQuery.flatMessageSummaries(query: "zzzznotfound", scope: .allAccounts(accountIds: [accountIdA, accountIdB]), db: db)
        }
        #expect(noMatch.isEmpty)
    }
}
