import Foundation
import GRDB
import Testing
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// 「ゴミ箱を空にする」— `EmptyTrash.commit`'s local half: every message in
/// the target mailbox is hard-deleted (row + FTS), messages in *other*
/// mailboxes are untouched, and exactly one `.emptyTrash` op is enqueued
/// carrying every real (non-placeholder) UID removed.
@Suite("EmptyTrash")
struct EmptyTrashTests {
    private func makeDatabase() throws -> (database: AppDatabase, accountId: String, trashId: Int64, inboxId: Int64) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        let (trashId, inboxId) = try database.dbWriter.write { db -> (Int64, Int64) in
            var trash = MailboxRecord(accountId: account.id, path: "Trash", displayPath: "Trash", role: .trash, uidValidity: 42)
            try trash.insert(db)
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1)
            try inbox.insert(db)
            return (trash.id!, inbox.id!)
        }
        return (database, account.id, trashId, inboxId)
    }

    /// One single-message thread in `mailboxId`, optionally indexed in FTS.
    @discardableResult
    private func insertMessage(
        accountId: String, mailboxId: Int64, uid: Int64, indexInFTS: Bool = true, db: Database
    ) throws -> (threadId: Int64, messageId: Int64) {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var thread = ThreadRecord(accountId: accountId, lastMessageDate: date, messageCount: 1)
        try thread.insert(db)
        var message = MessageRecord(mailboxId: mailboxId, uid: uid, date: date, internalDate: date, threadId: thread.id)
        try message.insert(db)
        if indexInFTS {
            try FTSIndexer.upsert(messageId: message.id!, subject: "subject \(uid)", plainText: "body", fromText: "from@x.test", db: db)
        }
        return (thread.id!, message.id!)
    }

    private func ftsRowExists(messageId: Int64, db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageSearchIndex WHERE rowid = ?", arguments: [messageId])! > 0
    }

    @Test("commit removes every message in the mailbox, its FTS row, and its now-empty thread")
    func commitRemovesEveryMessageAndFTSRow() throws {
        let (database, accountId, trashId, _) = try makeDatabase()
        let (thread1, message1) = try database.dbWriter.write { db in
            try insertMessage(accountId: accountId, mailboxId: trashId, uid: 1, db: db)
        }
        let (thread2, message2) = try database.dbWriter.write { db in
            try insertMessage(accountId: accountId, mailboxId: trashId, uid: 2, db: db)
        }

        let removedCount = try database.dbWriter.write { db in
            try EmptyTrash.commit(accountId: accountId, mailboxId: trashId, db: db)
        }
        #expect(removedCount == 2)

        let (message1Gone, message2Gone, thread1Gone, thread2Gone, message1FTSGone, message2FTSGone) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: message1) == nil,
                try MessageRecord.fetchOne(db, key: message2) == nil,
                try ThreadRecord.fetchOne(db, key: thread1) == nil,
                try ThreadRecord.fetchOne(db, key: thread2) == nil,
                try !ftsRowExists(messageId: message1, db: db),
                try !ftsRowExists(messageId: message2, db: db)
            )
        }
        #expect(message1Gone)
        #expect(message2Gone)
        #expect(thread1Gone)
        #expect(thread2Gone)
        #expect(message1FTSGone)
        #expect(message2FTSGone)

        let ops = try database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(ops.count == 1)
        let payload = try JSONDecoder().decode(EmptyTrashOpPayload.self, from: ops[0].payload)
        #expect(payload.mailboxId == trashId)
        #expect(payload.uidValidity == 42)
        #expect(Set(payload.uids) == [1, 2])
    }

    @Test("commit leaves other mailboxes' messages untouched")
    func commitOnlyTouchesTargetMailbox() throws {
        let (database, accountId, trashId, inboxId) = try makeDatabase()
        try database.dbWriter.write { db in
            try insertMessage(accountId: accountId, mailboxId: trashId, uid: 1, db: db)
        }
        let (inboxThread, inboxMessage) = try database.dbWriter.write { db in
            try insertMessage(accountId: accountId, mailboxId: inboxId, uid: 1, db: db)
        }

        try database.dbWriter.write { db in
            try EmptyTrash.commit(accountId: accountId, mailboxId: trashId, db: db)
        }

        let (inboxMessageStillThere, inboxThreadStillThere) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: inboxMessage) != nil,
                try ThreadRecord.fetchOne(db, key: inboxThread) != nil
            )
        }
        #expect(inboxMessageStillThere)
        #expect(inboxThreadStillThere)
    }

    @Test("commit on an already-empty mailbox is a no-op — no op enqueued")
    func commitOnEmptyMailboxIsANoOp() throws {
        let (database, accountId, trashId, _) = try makeDatabase()
        let removedCount = try database.dbWriter.write { db in
            try EmptyTrash.commit(accountId: accountId, mailboxId: trashId, db: db)
        }
        #expect(removedCount == 0)
        let opCount = try database.dbWriter.read { db in try OpQueueRecord.fetchCount(db) }
        #expect(opCount == 0)
    }

    @Test("a pending-relocation placeholder row (uid <= 0) is removed locally but excluded from the enqueued op's UIDs")
    func commitExcludesPlaceholderUIDsFromThePayload() throws {
        let (database, accountId, trashId, _) = try makeDatabase()
        let (_, realMessage) = try database.dbWriter.write { db in
            try insertMessage(accountId: accountId, mailboxId: trashId, uid: 5, db: db)
        }
        let (_, placeholderMessage) = try database.dbWriter.write { db in
            try insertMessage(accountId: accountId, mailboxId: trashId, uid: -realMessage, indexInFTS: false, db: db)
        }

        let removedCount = try database.dbWriter.write { db in
            try EmptyTrash.commit(accountId: accountId, mailboxId: trashId, db: db)
        }
        #expect(removedCount == 2)

        let (realMessageGone, placeholderMessageGone) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: realMessage) == nil,
                try MessageRecord.fetchOne(db, key: placeholderMessage) == nil
            )
        }
        #expect(realMessageGone)
        #expect(placeholderMessageGone)

        let ops = try database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(ops.count == 1)
        let payload = try JSONDecoder().decode(EmptyTrashOpPayload.self, from: ops[0].payload)
        #expect(payload.uids == [5])
    }
}
