import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// Task #151 (「アーカイブ済みの可視化」): `ThreadSummary.isArchived`'s
/// determination logic — both the grouped path (`ThreadQuery.summaries
/// (forThreads:db:)`, which every threaded-mode list/search surface goes
/// through) and the flat path (`ThreadQuery.flatSummaries`/
/// `unifiedInboxFlatSummaries`, one row per message). The underlying
/// predicate itself (`GmailArchiveFilter.messageIsArchivedSQL`) is a thin
/// wrapper around the same `excludeUnarchivedSQL` `GmailArchiveFilterTests`
/// already covers in depth (dedup by `X-GM-MSGID` against INBOX/Sent/
/// Drafts) — this file focuses on the new `isArchived` boolean actually
/// landing correctly on `ThreadSummary` itself, for both a Gmail All Mail
/// message and a plain non-Gmail `.archive`-role mailbox.
@Suite("ThreadSummary.isArchived")
struct ThreadSummaryArchiveTests {
    // MARK: - Gmail (All Mail minus INBOX/Sent/Drafts duplicates)

    private func makeGmailDatabase() throws -> (
        database: AppDatabase, accountId: String, allMailId: Int64, inboxId: Int64
    ) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Gmail", email: "g@example.test", authType: .oauth2, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapUsername: "g@example.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        let (allMailId, inboxId) = try database.dbWriter.write { db -> (Int64, Int64) in
            var allMail = MailboxRecord(accountId: account.id, path: "[Gmail]/All Mail", displayPath: "All Mail", role: .all)
            allMail = try allMail.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            inbox = try inbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return (allMail.id!, inbox.id!)
        }
        return (database, account.id, allMailId, inboxId)
    }

    @Test("Gmail message only in All Mail: isArchived == true (grouped path)")
    func gmailOnlyInAllMailIsArchivedGrouped() throws {
        let (database, accountId, allMailId, _) = try makeGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(mailboxId: allMailId, uid: 1, date: base, internalDate: base, gmailMessageId: 1, threadId: thread.id)
            try message.insert(db)
            return thread.id!
        }

        let summaries = try database.dbWriter.read { db in
            try ThreadQuery.summaries(forThreads: [ThreadRecord.fetchOne(db, key: threadId)!], db: db)
        }
        #expect(summaries.count == 1)
        #expect(summaries[0].isArchived == true, "A Gmail message with no INBOX/Sent/Drafts duplicate is genuinely archived")
    }

    @Test("Gmail message also duplicated into INBOX: isArchived == false (grouped path)")
    func gmailDuplicatedIntoInboxIsNotArchivedGrouped() throws {
        let (database, accountId, allMailId, inboxId) = try makeGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 2)
            try thread.insert(db)
            var allMailMessage = MessageRecord(mailboxId: allMailId, uid: 1, date: base, internalDate: base, gmailMessageId: 1, threadId: thread.id)
            try allMailMessage.insert(db)
            var inboxMessage = MessageRecord(mailboxId: inboxId, uid: 1, date: base, internalDate: base, gmailMessageId: 1, threadId: thread.id)
            try inboxMessage.insert(db)
            return thread.id!
        }

        let summaries = try database.dbWriter.read { db in
            try ThreadQuery.summaries(forThreads: [ThreadRecord.fetchOne(db, key: threadId)!], db: db)
        }
        #expect(summaries.count == 1)
        #expect(summaries[0].isArchived == false, "Still present in INBOX means not archived yet, even though a copy sits in All Mail")
    }

    @Test("Gmail message only in All Mail: isArchived == true (flat path)")
    func gmailOnlyInAllMailIsArchivedFlat() throws {
        let (database, accountId, allMailId, _) = try makeGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(mailboxId: allMailId, uid: 1, date: base, internalDate: base, gmailMessageId: 1, threadId: thread.id)
            try message.insert(db)
        }

        let flat = try database.dbWriter.read { db in
            try ThreadQuery.flatSummaries(mailboxId: allMailId, accountId: accountId, db: db)
        }
        #expect(flat.count == 1)
        #expect(flat[0].isArchived == true)
    }

    @Test("Gmail message also duplicated into INBOX: isArchived == false (unifiedInboxFlatSummaries)")
    func gmailDuplicatedIntoInboxIsNotArchivedUnifiedFlat() throws {
        let (database, accountId, allMailId, inboxId) = try makeGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            // A genuinely archived message plus one still duplicated into
            // INBOX — mirrors `GmailArchiveFilterTests
            // .unifiedInboxFlatSummariesAppliesExclusion`'s own fixture
            // shape for this same query.
            var archivedThread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 1)
            try archivedThread.insert(db)
            var archivedMessage = MessageRecord(mailboxId: allMailId, uid: 1, date: base, internalDate: base, gmailMessageId: 1, threadId: archivedThread.id)
            try archivedMessage.insert(db)

            var dupThread = ThreadRecord(accountId: accountId, lastMessageDate: base.addingTimeInterval(60), messageCount: 2)
            try dupThread.insert(db)
            var allMailDup = MessageRecord(mailboxId: allMailId, uid: 2, date: base.addingTimeInterval(60), internalDate: base.addingTimeInterval(60), gmailMessageId: 2, threadId: dupThread.id)
            try allMailDup.insert(db)
            var inboxDup = MessageRecord(mailboxId: inboxId, uid: 2, date: base.addingTimeInterval(60), internalDate: base.addingTimeInterval(60), gmailMessageId: 2, threadId: dupThread.id)
            try inboxDup.insert(db)
        }

        // `role: .archive` — for a Gmail account this maps to All Mail only
        // (`MailboxRoleRecord.gmailArchiveQueryRole`), same as every other
        // Gmail-archive-scoped query in this codebase; `role: .all` would
        // *not* reach the INBOX-duplicated message at all for a Gmail
        // account (Task #141's "span every mailbox" behavior is non-Gmail
        // only), so it wouldn't exercise the dedup this test targets.
        let flat = try database.dbWriter.read { db in
            try ThreadQuery.unifiedInboxFlatSummaries(accountIds: [accountId], role: .archive, db: db)
        }
        #expect(flat.count == 1, "Expected only the genuinely-archived message — the INBOX-duplicated one shouldn't even be selected")
        #expect(flat.allSatisfy { $0.isArchived == true })
    }

    // MARK: - Non-Gmail (`role == .archive` directly)

    private func makeNonGmailDatabase() throws -> (
        database: AppDatabase, accountId: String, inboxId: Int64, archiveId: Int64
    ) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "IMAP", email: "i@example.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "i@example.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        let (inboxId, archiveId) = try database.dbWriter.write { db -> (Int64, Int64) in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            inbox = try inbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var archive = MailboxRecord(accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive)
            archive = try archive.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return (inbox.id!, archive.id!)
        }
        return (database, account.id, inboxId, archiveId)
    }

    @Test("Non-Gmail message in a .archive-role mailbox: isArchived == true (grouped path)")
    func nonGmailArchiveMailboxIsArchivedGrouped() throws {
        let (database, accountId, _, archiveId) = try makeNonGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(mailboxId: archiveId, uid: 1, date: base, internalDate: base, threadId: thread.id)
            try message.insert(db)
            return thread.id!
        }

        let summaries = try database.dbWriter.read { db in
            try ThreadQuery.summaries(forThreads: [ThreadRecord.fetchOne(db, key: threadId)!], db: db)
        }
        #expect(summaries.count == 1)
        #expect(summaries[0].isArchived == true)
    }

    @Test("Non-Gmail message in a .inbox-role mailbox: isArchived == false (grouped path)")
    func nonGmailInboxMailboxIsNotArchivedGrouped() throws {
        let (database, accountId, inboxId, _) = try makeNonGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(mailboxId: inboxId, uid: 1, date: base, internalDate: base, threadId: thread.id)
            try message.insert(db)
            return thread.id!
        }

        let summaries = try database.dbWriter.read { db in
            try ThreadQuery.summaries(forThreads: [ThreadRecord.fetchOne(db, key: threadId)!], db: db)
        }
        #expect(summaries.count == 1)
        #expect(summaries[0].isArchived == false)
    }

    @Test("Non-Gmail message in a .archive-role mailbox: isArchived == true (flat path)")
    func nonGmailArchiveMailboxIsArchivedFlat() throws {
        let (database, accountId, _, archiveId) = try makeNonGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(mailboxId: archiveId, uid: 1, date: base, internalDate: base, threadId: thread.id)
            try message.insert(db)
        }

        let flat = try database.dbWriter.read { db in
            try ThreadQuery.flatSummaries(mailboxId: archiveId, accountId: accountId, db: db)
        }
        #expect(flat.count == 1)
        #expect(flat[0].isArchived == true)
    }

    @Test("Non-Gmail message in a .inbox-role mailbox: isArchived == false (flat path)")
    func nonGmailInboxMailboxIsNotArchivedFlat() throws {
        let (database, accountId, inboxId, _) = try makeNonGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(mailboxId: inboxId, uid: 1, date: base, internalDate: base, threadId: thread.id)
            try message.insert(db)
        }

        let flat = try database.dbWriter.read { db in
            try ThreadQuery.flatSummaries(mailboxId: inboxId, accountId: accountId, db: db)
        }
        #expect(flat.count == 1)
        #expect(flat[0].isArchived == false)
    }
}
