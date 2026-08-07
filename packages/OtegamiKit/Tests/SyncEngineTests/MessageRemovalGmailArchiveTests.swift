import Foundation
import GRDB
import Testing
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// Regression coverage for 実機報告「iOS で Gmail のさっき受信したメールを
/// アーカイブしたらどこにも表示されなくなった」— see
/// `MessageRemoval.relocationDestinationId`'s doc comment for the root cause
/// (a Gmail archive always deleted the source row outright, assuming All Mail
/// independently held the same message; All Mail is never part of
/// `SyncScope.inboxOnly`, so a message that arrived after the initial sync has
/// no All Mail row at all and the delete removed its last trace).
///
/// Split out of `MessageRemovalTests` rather than appended to it — that file
/// is already 37K and entirely about the non-Gmail archive/delete/undo paths.
@Suite("MessageRemoval Gmail archive")
struct MessageRemovalGmailArchiveTests {
    /// A Gmail account with an INBOX and (unless `withAllMail` is `false`) an
    /// All Mail mailbox — the two-mailbox shape every Gmail account really
    /// has, and the one `relocationDestinationId` branches on.
    private func makeGmailDatabase(
        withAllMail: Bool = true
    ) throws -> (database: AppDatabase, accountId: String, inboxId: Int64, allMailId: Int64?) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Gmail Test", email: "g@gmail.test", authType: .oauth2, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapUsername: "g@gmail.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        let (inboxId, allMailId) = try database.dbWriter.write { db -> (Int64, Int64?) in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1)
            try inbox.insert(db)
            guard withAllMail else { return (inbox.id!, nil) }
            var allMail = MailboxRecord(
                accountId: account.id, path: "[Gmail]/All Mail", displayPath: "[Gmail]/All Mail",
                role: .all, uidValidity: 1
            )
            try allMail.insert(db)
            return (inbox.id!, allMail.id!)
        }
        return (database, account.id, inboxId, allMailId)
    }

    /// One single-message thread, with the message identity fields a real
    /// Gmail envelope carries (`X-GM-MSGID` + RFC 822 `Message-ID`) — both
    /// are what `relocationDestinationId` judges "is this already in All
    /// Mail?" by, so every test here needs control over them.
    @discardableResult
    private func insertMessage(
        accountId: String, mailboxId: Int64, uid: Int64,
        messageId: String? = "<m1@otegami.test>", gmailMessageId: Int64? = 42,
        threadId: Int64? = nil, db: Database
    ) throws -> (threadId: Int64, messageId: Int64) {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let resolvedThreadId: Int64
        if let threadId {
            resolvedThreadId = threadId
        } else {
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: date, messageCount: 1)
            try thread.insert(db)
            resolvedThreadId = thread.id!
        }
        var message = MessageRecord(
            mailboxId: mailboxId, uid: uid, messageId: messageId,
            date: date, internalDate: date, threadId: resolvedThreadId
        )
        message.gmailMessageId = gmailMessageId
        try message.insert(db)
        try ThreadAssigner.recomputeAggregates(threadId: resolvedThreadId, db: db)
        return (resolvedThreadId, message.id!)
    }

    private func summary(threadId: Int64, messageId: Int64, database: AppDatabase) throws -> ThreadSummary {
        try database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }
    }

    // MARK: the reported bug

    @Test("archiving a Gmail message with no local All Mail row relocates it there instead of deleting it")
    func gmailArchiveRelocatesWhenAllMailRowIsMissing() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let (threadId, messageId) = try database.dbWriter.write { db in
            let ids = try insertMessage(accountId: accountId, mailboxId: inboxId, uid: 7, db: db)
            try FTSIndexer.upsert(messageId: ids.messageId, subject: "アーカイブ検証", plainText: nil, fromText: nil, db: db)
            return ids
        }
        let summary = try summary(threadId: threadId, messageId: messageId, database: database)

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }
        #expect(snapshot?.messages.count == 1)

        let (message, thread, ftsCount, opKind) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try ThreadRecord.fetchOne(db, key: threadId),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageSearchIndex WHERE rowid = ?", arguments: [messageId]),
                try OpQueueRecord.fetchOne(db)?.kind
            )
        }
        // The row survives, moved into All Mail with a placeholder UID — this
        // is the whole fix: before it, the row was deleted outright and the
        // message was gone from every view.
        #expect(message != nil)
        #expect(message?.mailboxId == allMailId)
        #expect(message?.isPendingRelocation == true)
        #expect(message?.uid == -messageId)
        // Relocation moves *where* a message lives, never its content, so its
        // search-index row is left alone (unlike the delete branch).
        #expect(ftsCount == 1)
        #expect(thread != nil)
        #expect(opKind == OpQueueKind.archive.rawValue)
    }

    @Test("a Gmail-archived message is immediately visible as archived and gone from the inbox view")
    func gmailArchivedMessageIsImmediatelyVisibleAsArchived() throws {
        let (database, accountId, inboxId, _) = try makeGmailDatabase()
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertMessage(accountId: accountId, mailboxId: inboxId, uid: 8, db: db)
        }
        let summary = try summary(threadId: threadId, messageId: messageId, database: database)

        try database.dbWriter.write { db in
            _ = try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }

        let (archived, inInbox, isArchived) = try database.dbWriter.read { db in
            (
                try ThreadQuery.unifiedInboxRequest(accountIds: [accountId], role: .archive).fetchAll(db),
                try ThreadQuery.unifiedInboxRequest(accountIds: [accountId], role: .inbox).fetchAll(db),
                try ThreadQuery.isThreadArchived(threadId: threadId, db: db)
            )
        }
        #expect(archived.map(\.id) == [threadId])
        #expect(inInbox.isEmpty)
        #expect(isArchived == true)
    }

    // MARK: duplicate avoidance

    @Test("archiving a Gmail message that already has a real All Mail row still deletes the inbox row")
    func gmailArchiveDeletesWhenAllMailRowAlreadyExists() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let (threadId, messageId) = try database.dbWriter.write { db -> (Int64, Int64) in
            let ids = try insertMessage(accountId: accountId, mailboxId: inboxId, uid: 9, db: db)
            // The same message, already synced into All Mail under its own
            // real UID — the case the pre-fix delete branch assumed always
            // held.
            try insertMessage(
                accountId: accountId, mailboxId: allMailId!, uid: 900,
                threadId: ids.threadId, db: db
            )
            try FTSIndexer.upsert(messageId: ids.messageId, subject: "重複回避", plainText: nil, fromText: nil, db: db)
            return ids
        }
        let summary = try summary(threadId: threadId, messageId: messageId, database: database)

        try database.dbWriter.write { db in
            _ = try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }

        let (inboxRow, allMailRows, ftsCount) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try MessageRecord.filter(Column("mailboxId") == allMailId!).fetchAll(db),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageSearchIndex WHERE rowid = ?", arguments: [messageId])
            )
        }
        // No synthetic second row beside the real one: フラット表示
        // (`ThreadQuery.flatSummaries`) doesn't dedup by message identity, so
        // one would be visible there.
        #expect(inboxRow == nil)
        #expect(allMailRows.count == 1)
        #expect(allMailRows.first?.uid == 900)
        #expect(ftsCount == 0)
    }

    @Test("a Gmail message with no RFC 822 Message-ID falls back to delete — its placeholder could never be reconciled")
    func gmailArchiveDeletesWhenMessageIdIsMissing() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertMessage(accountId: accountId, mailboxId: inboxId, uid: 10, messageId: nil, db: db)
        }
        let summary = try summary(threadId: threadId, messageId: messageId, database: database)

        try database.dbWriter.write { db in
            _ = try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }

        let (row, allMailCount) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try MessageRecord.filter(Column("mailboxId") == allMailId!).fetchCount(db)
            )
        }
        #expect(row == nil)
        #expect(allMailCount == 0)
    }

    @Test("a Gmail message with no gmailMessageId still relocates — identity falls back to Message-ID, matching ThreadQuery.identityKey")
    func gmailArchiveRelocatesWhenGmailMessageIdIsMissing() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertMessage(accountId: accountId, mailboxId: inboxId, uid: 11, gmailMessageId: nil, db: db)
        }
        let summary = try summary(threadId: threadId, messageId: messageId, database: database)

        try database.dbWriter.write { db in
            _ = try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }

        let row = try database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId) }
        #expect(row?.mailboxId == allMailId)
        #expect(row?.isPendingRelocation == true)
    }

    @Test("a Gmail message whose Message-ID already matches an All Mail row falls back to delete")
    func gmailArchiveDeletesWhenMessageIdMatchesAllMailRow() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let (threadId, messageId) = try database.dbWriter.write { db -> (Int64, Int64) in
            let ids = try insertMessage(
                accountId: accountId, mailboxId: inboxId, uid: 12, gmailMessageId: nil, db: db
            )
            try insertMessage(
                accountId: accountId, mailboxId: allMailId!, uid: 1200, gmailMessageId: nil,
                threadId: ids.threadId, db: db
            )
            return ids
        }
        let summary = try summary(threadId: threadId, messageId: messageId, database: database)

        try database.dbWriter.write { db in
            _ = try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }

        let (row, allMailCount) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try MessageRecord.filter(Column("mailboxId") == allMailId!).fetchCount(db)
            )
        }
        #expect(row == nil)
        #expect(allMailCount == 1)
    }

    @Test("a Gmail account with no local All Mail mailbox falls back to delete")
    func gmailArchiveDeletesWhenAllMailMailboxIsUnknown() throws {
        let (database, accountId, inboxId, _) = try makeGmailDatabase(withAllMail: false)
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertMessage(accountId: accountId, mailboxId: inboxId, uid: 13, db: db)
        }
        let summary = try summary(threadId: threadId, messageId: messageId, database: database)

        try database.dbWriter.write { db in
            _ = try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }

        let (row, opCount) = try database.dbWriter.read { db in
            (try MessageRecord.fetchOne(db, key: messageId), try OpQueueRecord.fetchCount(db))
        }
        #expect(row == nil)
        // The op is still queued — the server-side unlabel must happen either
        // way; only the local representation differs.
        #expect(opCount == 1)
    }

    @Test("only the message without an All Mail row relocates — the decision is per-message, not per-commit")
    func gmailArchiveDecidesPerMessage() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let (threadId, oldMessageId, newMessageId) = try database.dbWriter.write { db -> (Int64, Int64, Int64) in
            // Two messages in one thread: the older one is already in All
            // Mail (inside the initial sync window), the newer one arrived
            // after it and so isn't.
            let old = try insertMessage(
                accountId: accountId, mailboxId: inboxId, uid: 14,
                messageId: "<old@otegami.test>", gmailMessageId: 100, db: db
            )
            try insertMessage(
                accountId: accountId, mailboxId: allMailId!, uid: 1400,
                messageId: "<old@otegami.test>", gmailMessageId: 100,
                threadId: old.threadId, db: db
            )
            let new = try insertMessage(
                accountId: accountId, mailboxId: inboxId, uid: 15,
                messageId: "<new@otegami.test>", gmailMessageId: 101,
                threadId: old.threadId, db: db
            )
            return (old.threadId, old.messageId, new.messageId)
        }
        let summary = try summary(threadId: threadId, messageId: newMessageId, database: database)

        try database.dbWriter.write { db in
            _ = try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }

        let (oldRow, newRow) = try database.dbWriter.read { db in
            (try MessageRecord.fetchOne(db, key: oldMessageId), try MessageRecord.fetchOne(db, key: newMessageId))
        }
        #expect(oldRow == nil)
        #expect(newRow?.mailboxId == allMailId)
        #expect(newRow?.isPendingRelocation == true)
    }

    // MARK: guards that must keep holding

    @Test("archiving a row already in All Mail is a no-op — Gmail's All Mail is its archived location")
    func archivingAnAllMailRowIsANoOp() throws {
        let (database, accountId, _, allMailId) = try makeGmailDatabase()
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertMessage(accountId: accountId, mailboxId: allMailId!, uid: 16, db: db)
        }
        let summary = try summary(threadId: threadId, messageId: messageId, database: database)

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }
        // Without this guard the op would `\Deleted`+`EXPUNGE` against All
        // Mail itself, which on Gmail is a real delete (to Trash), not an
        // unlabel.
        #expect(snapshot == nil)
        let (row, opCount) = try database.dbWriter.read { db in
            (try MessageRecord.fetchOne(db, key: messageId), try OpQueueRecord.fetchCount(db))
        }
        #expect(row?.mailboxId == allMailId)
        #expect(opCount == 0)
    }

    @Test("archiving a pinned Gmail thread still throws ArchiveGuardError.pinned and relocates nothing")
    func pinnedGuardStillHolds() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let (threadId, messageId) = try database.dbWriter.write { db -> (Int64, Int64) in
            let ids = try insertMessage(accountId: accountId, mailboxId: inboxId, uid: 17, db: db)
            var message = try MessageRecord.fetchOne(db, key: ids.messageId)!
            message.isPinnedLocal = true
            try message.update(db)
            try ThreadAssigner.recomputeAggregates(threadId: ids.threadId, db: db)
            return ids
        }
        let summary = try summary(threadId: threadId, messageId: messageId, database: database)

        #expect(throws: MessageRemoval.ArchiveGuardError.pinned) {
            try database.dbWriter.write { db in
                try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
            }
        }

        let (row, allMailCount) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try MessageRecord.filter(Column("mailboxId") == allMailId!).fetchCount(db)
            )
        }
        #expect(row?.mailboxId == inboxId)
        #expect(allMailCount == 0)
    }

    @Test("markSeenOnArchive relocates the already-marked row, not a stale unread copy")
    func markSeenOnArchiveRelocatesTheUpdatedRow() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertMessage(accountId: accountId, mailboxId: inboxId, uid: 18, db: db)
        }
        let summary = try summary(threadId: threadId, messageId: messageId, database: database)

        try database.dbWriter.write { db in
            _ = try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db, markSeenOnArchive: true)
        }

        let (row, opKinds) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try OpQueueRecord.order(Column("id")).fetchAll(db).map(\.kind)
            )
        }
        #expect(row?.mailboxId == allMailId)
        #expect(row?.flags.contains(.seen) == true)
        // The flag STORE op must still precede the archive op — replay is
        // id-ordered, and a STORE against an already-unlabeled UID fails.
        #expect(opKinds == [OpQueueKind.setFlags.rawValue, OpQueueKind.archive.rawValue])
    }

    // MARK: undo

    @Test("undoing a relocating Gmail archive puts the row back in the inbox at its original UID")
    func undoRestoresRelocatedGmailArchive() throws {
        let (database, accountId, inboxId, _) = try makeGmailDatabase()
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertMessage(accountId: accountId, mailboxId: inboxId, uid: 19, db: db)
        }
        let summary = try summary(threadId: threadId, messageId: messageId, database: database)

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }
        try database.dbWriter.write { db in try MessageRemoval.undo(snapshot!, db: db) }

        let (row, thread, opCount, archived) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try ThreadRecord.fetchOne(db, key: threadId),
                try OpQueueRecord.fetchCount(db),
                try ThreadQuery.unifiedInboxRequest(accountIds: [accountId], role: .archive).fetchAll(db)
            )
        }
        #expect(row?.mailboxId == inboxId)
        #expect(row?.uid == 19)
        #expect(row?.isPendingRelocation == false)
        #expect(thread != nil)
        #expect(opCount == 0)
        #expect(archived.isEmpty)
    }

    // MARK: non-Gmail regression

    @Test("a non-Gmail archive is unaffected — it still relocates into the account's Archive-role mailbox")
    func nonGmailArchiveIsUnchanged() throws {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        let (inboxId, archiveId) = try database.dbWriter.write { db -> (Int64, Int64) in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1)
            try inbox.insert(db)
            var archive = MailboxRecord(accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive, uidValidity: 1)
            try archive.insert(db)
            return (inbox.id!, archive.id!)
        }
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertMessage(accountId: account.id, mailboxId: inboxId, uid: 20, gmailMessageId: nil, db: db)
        }
        let summary = try summary(threadId: threadId, messageId: messageId, database: database)

        try database.dbWriter.write { db in
            _ = try MessageRemoval.commit(.archive, summary: summary, accountId: account.id, db: db)
        }

        let row = try database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId) }
        #expect(row?.mailboxId == archiveId)
        #expect(row?.isPendingRelocation == true)
    }
}
