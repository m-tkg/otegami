import Foundation
import GRDB
import Testing
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// Regression coverage for Task #96 (実機報告「未読メールを開き、本文の読み込みが
/// 完了する前に一覧へ戻ると既読にならない」) — see `MessageReadMarker`'s own doc
/// comment for the root cause (mark-as-read used to run only after
/// `MessageView.load()`'s body fetch resolved, inside the same `.task(id:)`
/// that an early pop back to the list cancels mid-fetch) and the fix (the
/// DB write moved here, and `MessageView` now triggers it from `.onAppear`
/// via its own independent, unstructured `Task { }`).
@Suite("MessageReadMarker")
struct MessageReadMarkerTests {
    private func makeDatabase() throws -> (database: AppDatabase, accountId: String, inboxId: Int64) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        let inboxId = try database.dbWriter.write { db -> Int64 in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1)
            try inbox.insert(db)
            return inbox.id!
        }
        return (database, account.id, inboxId)
    }

    @discardableResult
    private func insertUnreadMessage(accountId: String, mailboxId: Int64, uid: Int64, db: Database) throws -> Int64 {
        var thread = ThreadRecord(accountId: accountId, lastMessageDate: Date(timeIntervalSince1970: 1_700_000_000), messageCount: 1)
        try thread.insert(db)
        var message = MessageRecord(
            mailboxId: mailboxId, uid: uid,
            date: Date(timeIntervalSince1970: 1_700_000_000), internalDate: Date(timeIntervalSince1970: 1_700_000_000),
            threadId: thread.id
        )
        // Freshly-synced messages default to unread — flip explicitly so
        // this test doesn't depend on that default staying unread forever.
        message.flags.remove(.seen)
        try message.insert(db)
        return message.id!
    }

    @Test("marks an unread message \\Seen locally and enqueues a setFlags op")
    func marksUnreadMessageSeenAndEnqueuesOp() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let messageId = try database.dbWriter.write { db in
            try insertUnreadMessage(accountId: accountId, mailboxId: inboxId, uid: 1, db: db)
        }

        let didMark = try database.dbWriter.write { db in
            try MessageReadMarker.markSeen(messageId: messageId, accountId: accountId, db: db)
        }
        #expect(didMark)

        let (message, opCount, opKind) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try OpQueueRecord.fetchCount(db),
                try OpQueueRecord.fetchOne(db)?.kind
            )
        }
        #expect(message?.flags.contains(.seen) == true)
        #expect(opCount == 1)
        #expect(opKind == OpQueueKind.setFlags.rawValue)
    }

    @Test("calling markSeen again on an already-read message is a no-op — no duplicate op enqueued")
    func alreadyReadMessageIsANoOp() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let messageId = try database.dbWriter.write { db in
            try insertUnreadMessage(accountId: accountId, mailboxId: inboxId, uid: 2, db: db)
        }
        _ = try database.dbWriter.write { db in
            try MessageReadMarker.markSeen(messageId: messageId, accountId: accountId, db: db)
        }

        let secondDidMark = try database.dbWriter.write { db in
            try MessageReadMarker.markSeen(messageId: messageId, accountId: accountId, db: db)
        }
        #expect(secondDidMark == false)

        let opCount = try database.dbWriter.read { db in try OpQueueRecord.fetchCount(db) }
        #expect(opCount == 1)
    }

    @Test("markSeen for a message that doesn't exist is a harmless no-op")
    func missingMessageIsANoOp() throws {
        let (database, accountId, _) = try makeDatabase()
        let didMark = try database.dbWriter.write { db in
            try MessageReadMarker.markSeen(messageId: 999, accountId: accountId, db: db)
        }
        #expect(didMark == false)
        let opCount = try database.dbWriter.read { db in try OpQueueRecord.fetchCount(db) }
        #expect(opCount == 0)
    }

    /// Reproduces the real-device bug's shape directly: `MessageView` used
    /// to only reach its mark-as-read call from *inside* the same `Task`
    /// `.task(id: messageId)` drives (`load()`), so cancelling that task —
    /// exactly what popping back to the list before the body fetch resolves
    /// does — meant the call was simply never reached. The fix wraps the
    /// write in its *own*, separately-launched `Task { }` (mirroring
    /// `MessageView.markAsReadIfNeeded()`'s actual shape) — an unstructured
    /// task is never implicitly cancelled just because some other task was.
    /// This proves that shape: cancel the "view's" task immediately, but
    /// the independent "mark as read" task it kicked off before disappearing
    /// still runs the write to completion.
    @Test("the mark-as-read write survives even if the view's own task is cancelled immediately after")
    func markAsReadSurvivesEarlyViewTaskCancellation() async throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let messageId = try await database.dbWriter.write { db in
            try insertUnreadMessage(accountId: accountId, mailboxId: inboxId, uid: 3, db: db)
        }

        // Mirrors `MessageView.markAsReadIfNeeded()`: a *separately*
        // launched, unstructured `Task { }` — not a child of `viewTask`
        // below — exactly as `.onAppear` kicks it off independently of
        // `.task(id: messageId)`'s own body.
        let markAsReadTask = Task {
            _ = try? await database.dbWriter.write { db in
                try MessageReadMarker.markSeen(messageId: messageId, accountId: accountId, db: db)
            }
        }
        // Simulates the slow network body fetch `.task(id: messageId)`
        // would otherwise still be awaiting when the user pops back to the
        // list.
        let viewTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // The user pops back to the list right away — SwiftUI cancels the
        // `.task(id: messageId)`-driven work immediately.
        viewTask.cancel()
        await viewTask.value

        // The independent mark-as-read task was never cancelled by that —
        // wait for it and confirm the write actually landed.
        await markAsReadTask.value

        let (message, opCount) = try await database.dbWriter.read { db in
            (try MessageRecord.fetchOne(db, key: messageId), try OpQueueRecord.fetchCount(db))
        }
        #expect(message?.flags.contains(.seen) == true)
        #expect(opCount == 1)
    }

    // MARK: Gmail の二重ラベル行

    /// 実機報告「Gmail のメールを既読にしてアーカイブしたのに、アーカイブ側の
    /// スレッドに未読ドットが残る」の再発防止。`MessagePinReadStateDuplicateTests
    /// .makePinnedGmailDuplicate` と同じ形の INBOX/All Mail 二重行を作る。
    /// 戻り値は (accountId, threadId, INBOX 行の id, All Mail 行の id)。
    private func makeUnreadGmailDuplicate(
        db: Database
    ) throws -> (accountId: String, threadId: Int64, inboxMessageId: Int64, allMailMessageId: Int64) {
        let account = AccountRecord(
            displayName: "Gmail", email: "dup@otegami.test", authType: .password, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapUsername: "dup@otegami.test"
        )
        try account.insert(db)
        var inbox = MailboxRecord(
            accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1
        )
        try inbox.insert(db)
        var allMail = MailboxRecord(
            accountId: account.id, path: "[Gmail]/All Mail", displayPath: "All Mail", role: .all, uidValidity: 1
        )
        try allMail.insert(db)

        var thread = ThreadRecord(accountId: account.id, normalizedSubject: "重複スレッド")
        try thread.insert(db)
        let threadId = try #require(thread.id)

        var messageIds: [Int64] = []
        for (mailboxId, uid) in [(try #require(inbox.id), Int64(10)), (try #require(allMail.id), Int64(20))] {
            var message = MessageRecord(
                mailboxId: mailboxId, uid: uid,
                messageId: "<dup@otegami.test>",
                subject: "重複スレッド", normalizedSubject: "重複スレッド",
                internalDate: Date(timeIntervalSince1970: 1_700_000_000),
                gmailMessageId: 4242,
                threadId: threadId
            )
            try message.insert(db)
            messageIds.append(try #require(message.id))
        }
        try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
        return (account.id, threadId, messageIds[0], messageIds[1])
    }

    @Test("markSeen が Gmail の重複兄弟行にも \\Seen を伝播する")
    func markSeenPropagatesToGmailDuplicateSibling() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.write { db in
            let (accountId, threadId, inboxMessageId, allMailMessageId) = try makeUnreadGmailDuplicate(db: db)

            let didMark = try MessageReadMarker.markSeen(
                messageId: inboxMessageId, accountId: accountId, db: db
            )
            #expect(didMark)

            let inboxRow = try #require(try MessageRecord.fetchOne(db, key: inboxMessageId))
            let allMailRow = try #require(try MessageRecord.fetchOne(db, key: allMailMessageId))
            #expect(inboxRow.flags.contains(.seen))
            #expect(
                allMailRow.flags.contains(.seen),
                "これが無いと、アーカイブで INBOX 行が消えた瞬間に未読 1 件として顕在化する"
            )
            let thread = try #require(try ThreadRecord.fetchOne(db, key: threadId))
            #expect(thread.unreadCount == 0)
        }
    }

    @Test("兄弟行も直したときに積まれる setFlags op は代表行のぶん 1 件だけ")
    func markSeenEnqueuesOneOpForTheRepresentativeRow() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.write { db in
            let (accountId, _, inboxMessageId, _) = try makeUnreadGmailDuplicate(db: db)
            try MessageReadMarker.markSeen(messageId: inboxMessageId, accountId: accountId, db: db)

            // フラグはラベルではなくメッセージに付くので、サーバーへ送るのは
            // 1 回でよい (`MessagePinReadState.applyToDuplicateSiblings` の前提)。
            #expect(try OpQueueRecord.fetchCount(db) == 1)
        }
    }

    @Test("代表行が既読で兄弟行だけ未読なら markSeen は true を返して op を積み直す")
    func markSeenStillWritesWhenOnlyTheSiblingIsOutOfStep() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.write { db in
            let (accountId, threadId, inboxMessageId, allMailMessageId) = try makeUnreadGmailDuplicate(db: db)
            // 代表行だけ既読 — 旧実装の `markSeen` が作っていた中間状態そのもの。
            try db.execute(sql: "UPDATE message SET flagsRaw = 1 WHERE id = ?", arguments: [inboxMessageId])
            try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)

            let didMark = try MessageReadMarker.markSeen(
                messageId: inboxMessageId, accountId: accountId, db: db
            )
            #expect(didMark, "代表行だけ見て早期 return すると兄弟行が直らない")

            let allMailRow = try #require(try MessageRecord.fetchOne(db, key: allMailMessageId))
            #expect(allMailRow.flags.contains(.seen))
            #expect(try OpQueueRecord.fetchCount(db) == 1)
        }
    }

    @Test("両行とも既読なら no-op — 2 回目の markSeen は false を返し op も増えない")
    func markSeenIsIdempotentAcrossSiblings() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.write { db in
            let (accountId, _, inboxMessageId, _) = try makeUnreadGmailDuplicate(db: db)
            try MessageReadMarker.markSeen(messageId: inboxMessageId, accountId: accountId, db: db)

            let second = try MessageReadMarker.markSeen(
                messageId: inboxMessageId, accountId: accountId, db: db
            )
            #expect(second == false)
            #expect(try OpQueueRecord.fetchCount(db) == 1)
        }
    }
}
