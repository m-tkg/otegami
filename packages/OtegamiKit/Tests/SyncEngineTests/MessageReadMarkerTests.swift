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
}
