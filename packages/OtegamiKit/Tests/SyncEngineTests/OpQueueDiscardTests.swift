import Foundation
import GRDB
import Testing
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// ユーザー要望 (2026-08-07「未送信の操作はキャンセルして削除できるように
/// して」) で追加した`OpQueue.discard(opId:db:)`/`discardAll(accountId:kind:db:)`
/// のテスト。`send`op の`outboxMessage`後始末 (これが無いと「送信中のまま」
/// 状態が永久に残る — `discard(opId:db:)`のdoc comment参照) を特に固定する。
@Suite("OpQueue discard — user-initiated cancellation of pending ops")
struct OpQueueDiscardTests {
    private func makeAccount(email: String = "discard@otegami.test", db: Database) throws -> AccountRecord {
        let account = AccountRecord(
            displayName: "Test", email: email, authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: email
        )
        try account.insert(db)
        return account
    }

    private func makeInbox(accountId: String, db: Database) throws -> MailboxRecord {
        var mailbox = MailboxRecord(accountId: accountId, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1)
        try mailbox.insert(db)
        return mailbox
    }

    private func makeOutbox(accountId: String, db: Database) throws -> Int64 {
        var outbox = OutboxMessageRecord(
            accountId: accountId,
            toAddresses: [EmailAddress(address: "recipient@example.com")],
            subject: "テスト送信",
            plainTextBody: "body"
        )
        try outbox.insert(db)
        return try #require(outbox.id)
    }

    @Test("discard(opId:) は opQueue 行を消す")
    func discardRemovesOneOp() throws {
        let database = try AppDatabase.makeInMemory()
        let remaining = try database.dbWriter.write { db -> Int in
            let account = try makeAccount(db: db)
            let inbox = try makeInbox(accountId: account.id, db: db)
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: try #require(inbox.id), uidValidity: inbox.uidValidity,
                uids: [1], flags: .seen, db: db
            )
            let opId = try #require(try OpQueueRecord.fetchOne(db)?.id)
            #expect(try OpQueue.discard(opId: opId, db: db))
            return try OpQueueRecord.fetchCount(db)
        }
        #expect(remaining == 0)
    }

    @Test("存在しない op の discard は false を返すだけ")
    func discardMissingOpIsNoop() throws {
        let database = try AppDatabase.makeInMemory()
        let discarded = try database.dbWriter.write { db in
            try OpQueue.discard(opId: 999, db: db)
        }
        #expect(!discarded)
    }

    /// `FailedOperationsView`がインラインで持っていた挙動をそのまま
    /// `SyncEngine`側へ移したので、その要点をここで固定する。
    @Test("send op を破棄すると outboxMessage も一緒に消える")
    func discardingSendAlsoDeletesOutboxRow() throws {
        let database = try AppDatabase.makeInMemory()
        let (opCount, outboxCount) = try database.dbWriter.write { db -> (Int, Int) in
            let account = try makeAccount(db: db)
            let outboxId = try makeOutbox(accountId: account.id, db: db)
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: outboxId, db: db)
            let opId = try #require(try OpQueueRecord.fetchOne(db)?.id)
            try OpQueue.discard(opId: opId, db: db)
            return (try OpQueueRecord.fetchCount(db), try OutboxMessageRecord.fetchCount(db))
        }
        #expect(opCount == 0)
        #expect(outboxCount == 0)
    }

    @Test("discardAll はそのアカウントの未送信操作をまとめて消し、他アカウントには触らない")
    func discardAllScopesToOneAccount() throws {
        let database = try AppDatabase.makeInMemory()
        let (deleted, remainingAccountIds) = try database.dbWriter.write { db -> (Int, [String]) in
            let target = try makeAccount(email: "target@otegami.test", db: db)
            let other = try makeAccount(email: "other@otegami.test", db: db)
            let targetInbox = try makeInbox(accountId: target.id, db: db)
            let otherInbox = try makeInbox(accountId: other.id, db: db)
            try OpQueue.enqueueSetFlags(
                accountId: target.id, mailboxId: try #require(targetInbox.id), uidValidity: 1,
                uids: [1], flags: .seen, db: db
            )
            try OpQueue.enqueueArchive(
                accountId: target.id, sourceMailboxId: try #require(targetInbox.id), uidValidity: 1,
                uids: [2], db: db
            )
            try OpQueue.enqueueSetFlags(
                accountId: other.id, mailboxId: try #require(otherInbox.id), uidValidity: 1,
                uids: [3], flags: .seen, db: db
            )
            let deleted = try OpQueue.discardAll(accountId: target.id, db: db)
            return (deleted, try OpQueueRecord.fetchAll(db).map(\.accountId))
        }
        #expect(deleted == 2)
        #expect(remainingAccountIds.count == 1)
    }

    @Test("discardAll(kind:) は指定した種類だけを消す")
    func discardAllCanFilterByKind() throws {
        let database = try AppDatabase.makeInMemory()
        let remainingKinds = try database.dbWriter.write { db -> [String] in
            let account = try makeAccount(db: db)
            let inbox = try makeInbox(accountId: account.id, db: db)
            let outboxId = try makeOutbox(accountId: account.id, db: db)
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: try #require(inbox.id), uidValidity: 1,
                uids: [1], flags: .seen, db: db
            )
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: outboxId, db: db)
            #expect(try OpQueue.discardAll(accountId: account.id, kind: .setFlags, db: db) == 1)
            return try OpQueueRecord.fetchAll(db).map(\.kind)
        }
        #expect(remainingKinds == [OpQueueKind.send.rawValue])
    }

    @Test("discardAll でも send の outboxMessage は後始末される")
    func discardAllCleansUpOutboxRows() throws {
        let database = try AppDatabase.makeInMemory()
        let outboxCount = try database.dbWriter.write { db -> Int in
            let account = try makeAccount(db: db)
            let outboxId = try makeOutbox(accountId: account.id, db: db)
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: outboxId, db: db)
            try OpQueue.discardAll(accountId: account.id, db: db)
            return try OutboxMessageRecord.fetchCount(db)
        }
        #expect(outboxCount == 0)
    }

    @Test("未送信操作が無いアカウントの discardAll は 0 件")
    func discardAllOnEmptyQueueReturnsZero() throws {
        let database = try AppDatabase.makeInMemory()
        let deleted = try database.dbWriter.write { db -> Int in
            let account = try makeAccount(db: db)
            return try OpQueue.discardAll(accountId: account.id, db: db)
        }
        #expect(deleted == 0)
    }
}
