import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// 実機報告「まだローカルにない未読メールが検出できない」: `UnseenSweeper` は
/// `UID SEARCH UNSEEN` の結果とローカルの行を突き合わせ、足りない分を取り込み、
/// 取り切れなかった残りを `MailboxRecord.unseenNotFetchedCount` に残す。
/// `BackfillSyncerTests` と同じ「アクターを直接組み立てて、スクリプト化した
/// `FakeIMAPSession` に対して回す」形 — `sweep` 自身は `connect`/`select` を
/// しない (本番では呼び出し側の `MailboxSyncer` が済ませている)。
@Suite("UnseenSweeper")
struct UnseenSweeperTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Test", email: "test@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test@otegami.test"
        )
    }

    private func makeEnvelope(uid: UInt32, seen: Bool = false) -> FetchedEnvelope {
        FetchedEnvelope(
            uid: uid,
            messageId: "<unseen-\(uid)@otegami.test>",
            inReplyTo: nil,
            references: [],
            subject: "未読メール \(uid)",
            from: [EmailAddress(name: "Aiko", address: "aiko@otegami.test")],
            to: [EmailAddress(address: "test@otegami.test")],
            cc: [], bcc: [], replyTo: [],
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            internalDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            flags: seen ? [.seen] : [],
            size: 512
        )
    }

    private func makeMailbox(
        database: AppDatabase, account: AccountRecord, role: MailboxRoleRecord = .inbox,
        path: String = "INBOX", lastUnseenSweepAt: Date? = nil
    ) async throws -> MailboxRecord {
        try await database.dbWriter.write { db in
            if try AccountRecord.fetchOne(db, key: account.id) == nil {
                try account.insert(db)
            }
            var mailbox = MailboxRecord(
                accountId: account.id, path: path, displayPath: path, role: role,
                uidValidity: 1, lastUnseenSweepAt: lastUnseenSweepAt
            )
            try mailbox.insert(db)
            return mailbox
        }
    }

    /// Inserts a local `message` row for `uid` (unread unless `seen`), the way
    /// a previous sync would have — what the sweep diffs the server's answer
    /// against.
    private func insertLocalMessage(
        database: AppDatabase, mailboxId: Int64, accountId: String, uid: Int64, seen: Bool = false
    ) async throws {
        try await database.dbWriter.write { db in
            var thread = ThreadRecord(
                accountId: accountId, lastMessageDate: Date(timeIntervalSince1970: 1_700_000_000), messageCount: 1
            )
            try thread.insert(db)
            var message = MessageRecord(
                mailboxId: mailboxId, uid: uid, messageId: "<unseen-\(uid)@otegami.test>",
                date: Date(timeIntervalSince1970: 1_700_000_000),
                internalDate: Date(timeIntervalSince1970: 1_700_000_000),
                threadId: thread.id
            )
            if seen { message.flags = [.seen] }
            try message.insert(db)
        }
    }

    // MARK: the reported bug

    @Test("unread messages the server has but this device doesn't are fetched, and the remainder lands at zero")
    func fetchesMissingUnreadMessages() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        let mailbox = try await makeMailbox(database: database, account: account)
        // The server has three unread messages; this device stored only one of
        // them — the state a mailbox whose backfill hasn't caught up is in.
        try await insertLocalMessage(database: database, mailboxId: mailbox.id!, accountId: account.id, uid: 3)

        let script = FakeIMAPSession.Script(envelopesByPath: [
            "INBOX": [makeEnvelope(uid: 1), makeEnvelope(uid: 2), makeEnvelope(uid: 3)],
        ])
        let session = FakeIMAPSession(config: account.imapConfig, script: script)

        let result = try await UnseenSweeper(database: database).sweep(
            mailboxRecord: mailbox, mailboxPath: "INBOX", accountId: account.id, session: session
        )

        #expect(result?.serverUnseenCount == 3)
        #expect(result?.missingCount == 2)
        #expect(result?.fetchedCount == 2)
        #expect(result?.remainingCount == 0)

        let (localCount, stored) = try await database.dbWriter.read { db in
            (
                try MessageRecord.filter(Column("mailboxId") == mailbox.id!).fetchCount(db),
                try MailboxRecord.fetchOne(db, key: mailbox.id!)
            )
        }
        #expect(localCount == 3, "the two missing messages are now stored locally")
        #expect(stored?.unseenNotFetchedCount == 0)
        #expect(stored?.lastUnseenSweepAt != nil)
    }

    @Test("the unread badge now includes what the sweep found, and the sweep makes it real")
    func unreadCountReflectsTheSweep() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        let mailbox = try await makeMailbox(database: database, account: account)

        // Before any sweep: the badge only knows about local rows — one — even
        // though the server has three unread. This is the reported symptom.
        try await insertLocalMessage(database: database, mailboxId: mailbox.id!, accountId: account.id, uid: 3)
        let before = try await database.dbWriter.read { db in
            try MessageQuery.unreadCount(mailboxId: mailbox.id!, accountId: account.id, db: db)
        }
        #expect(before == 1)

        let script = FakeIMAPSession.Script(envelopesByPath: [
            "INBOX": [makeEnvelope(uid: 1), makeEnvelope(uid: 2), makeEnvelope(uid: 3)],
        ])
        let session = FakeIMAPSession(config: account.imapConfig, script: script)
        _ = try await UnseenSweeper(database: database).sweep(
            mailboxRecord: mailbox, mailboxPath: "INBOX", accountId: account.id, session: session
        )

        let after = try await database.dbWriter.read { db in
            try MessageQuery.unreadCount(mailboxId: mailbox.id!, accountId: account.id, db: db)
        }
        #expect(after == 3)
    }

    @Test("what the sweep couldn't fetch this pass is still counted, via unseenNotFetchedCount")
    func remainderIsCountedWithoutBeingFetched() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        let mailbox = try await makeMailbox(database: database, account: account)
        // Simulate a sweep that hit its per-pass cap: no local rows, and a
        // stored remainder. (Driving the real 500-message cap through a fake
        // fixture would only test `prefix`.)
        try await database.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE mailbox SET unseenNotFetchedCount = ? WHERE id = ?", arguments: [42, mailbox.id!]
            )
        }

        let (perMailbox, unified) = try await database.dbWriter.read { db in
            (
                try MessageQuery.unreadCount(mailboxId: mailbox.id!, accountId: account.id, db: db),
                try MessageQuery.unifiedInboxUnreadCount(accountIds: [account.id], role: .inbox, db: db)
            )
        }
        #expect(perMailbox == 42, "a mailbox with zero local unread rows still reports its remainder")
        #expect(unified == 42)
    }

    @Test("locally-read messages still decrement the badge — the remainder never counts a stored row")
    func localReadsStillDecrementTheBadge() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        let mailbox = try await makeMailbox(database: database, account: account)
        try await insertLocalMessage(database: database, mailboxId: mailbox.id!, accountId: account.id, uid: 1)
        try await insertLocalMessage(database: database, mailboxId: mailbox.id!, accountId: account.id, uid: 2)

        let script = FakeIMAPSession.Script(envelopesByPath: [
            "INBOX": [makeEnvelope(uid: 1), makeEnvelope(uid: 2)],
        ])
        let session = FakeIMAPSession(config: account.imapConfig, script: script)
        _ = try await UnseenSweeper(database: database).sweep(
            mailboxRecord: mailbox, mailboxPath: "INBOX", accountId: account.id, session: session
        )

        // Everything the server called unread is already stored, so nothing is
        // added — and marking one read locally drops the badge straight away.
        try await database.dbWriter.write { db in
            try db.execute(sql: "UPDATE message SET flagsRaw = 1 WHERE uid = 1")
        }
        let count = try await database.dbWriter.read { db in
            try MessageQuery.unreadCount(mailboxId: mailbox.id!, accountId: account.id, db: db)
        }
        #expect(count == 1)
    }

    @Test("a message stored locally as read is never re-counted, even while the server still calls it unread")
    func locallyReadRowIsNotCountedAsMissing() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        let mailbox = try await makeMailbox(database: database, account: account)
        // Read locally, `\Seen` not yet replayed to the server — so the server
        // still returns it from SEARCH UNSEEN. It has a local row, so it must
        // not land in the remainder.
        try await insertLocalMessage(
            database: database, mailboxId: mailbox.id!, accountId: account.id, uid: 1, seen: true
        )

        let script = FakeIMAPSession.Script(envelopesByPath: ["INBOX": [makeEnvelope(uid: 1)]])
        let session = FakeIMAPSession(config: account.imapConfig, script: script)
        let result = try await UnseenSweeper(database: database).sweep(
            mailboxRecord: mailbox, mailboxPath: "INBOX", accountId: account.id, session: session
        )

        #expect(result?.missingCount == 0)
        #expect(result?.remainingCount == 0)
        let count = try await database.dbWriter.read { db in
            try MessageQuery.unreadCount(mailboxId: mailbox.id!, accountId: account.id, db: db)
        }
        #expect(count == 0)
    }

    // MARK: Gmail's All Mail

    @Test("Gmail's All Mail remainder is not added to the archive badge — SEARCH UNSEEN can't tell archived from inbox")
    func gmailAllMailRemainderIsNotCounted() async throws {
        let database = try AppDatabase.makeInMemory()
        let gmail = AccountRecord(
            displayName: "Gmail", email: "g@otegami.test", authType: .oauth2, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapUsername: "g@otegami.test"
        )
        let allMail = try await makeMailbox(
            database: database, account: gmail, role: .all, path: "[Gmail]/All Mail"
        )
        try await database.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE mailbox SET unseenNotFetchedCount = ? WHERE id = ?", arguments: [99, allMail.id!]
            )
        }

        let (perMailbox, archiveBadge) = try await database.dbWriter.read { db in
            (
                try MessageQuery.unreadCount(mailboxId: allMail.id!, accountId: gmail.id, db: db),
                try MessageQuery.unifiedInboxUnreadCount(accountIds: [gmail.id], role: .archive, db: db)
            )
        }
        #expect(perMailbox == 0)
        #expect(archiveBadge == 0)
    }

    @Test("a Gmail INBOX remainder is counted normally — only All Mail is excluded")
    func gmailInboxRemainderIsCounted() async throws {
        let database = try AppDatabase.makeInMemory()
        let gmail = AccountRecord(
            displayName: "Gmail", email: "g@otegami.test", authType: .oauth2, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapUsername: "g@otegami.test"
        )
        let inbox = try await makeMailbox(database: database, account: gmail, role: .inbox)
        try await database.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE mailbox SET unseenNotFetchedCount = ? WHERE id = ?", arguments: [7, inbox.id!]
            )
        }

        let badge = try await database.dbWriter.read { db in
            try MessageQuery.unifiedInboxUnreadCount(accountIds: [gmail.id], role: .inbox, db: db)
        }
        #expect(badge == 7)
    }

    @Test("a hidden mailbox's remainder stays out of the unified badge, matching the local count's own scope")
    func hiddenMailboxRemainderIsExcludedFromUnifiedBadge() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        let mailbox = try await makeMailbox(database: database, account: account)
        try await database.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE mailbox SET unseenNotFetchedCount = ?, isHidden = 1 WHERE id = ?",
                arguments: [5, mailbox.id!]
            )
        }

        let badge = try await database.dbWriter.read { db in
            try MessageQuery.unifiedInboxUnreadCount(accountIds: [account.id], role: .inbox, db: db)
        }
        #expect(badge == 0)
    }

    // MARK: rate limiting and failure tolerance

    @Test("isDue gates on sweepInterval")
    func isDueGatesOnInterval() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        let never = try await makeMailbox(database: database, account: account)
        #expect(UnseenSweeper.isDue(never) == true, "never swept")

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var justSwept = never
        justSwept.lastUnseenSweepAt = now
        #expect(UnseenSweeper.isDue(justSwept, now: now.addingTimeInterval(60)) == false)
        #expect(
            UnseenSweeper.isDue(justSwept, now: now.addingTimeInterval(UnseenSweeper.sweepInterval + 1)) == true
        )
    }

    @Test("a failed SEARCH UNSEEN propagates out of sweep rather than corrupting the stored remainder")
    func failedSearchPropagates() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        let mailbox = try await makeMailbox(database: database, account: account)

        let script = FakeIMAPSession.Script(
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 1)]],
            failSearchUnseenUIDs: .notImplemented("SEARCH")
        )
        let session = FakeIMAPSession(config: account.imapConfig, script: script)

        await #expect(throws: MailTransportError.self) {
            _ = try await UnseenSweeper(database: database).sweep(
                mailboxRecord: mailbox, mailboxPath: "INBOX", accountId: account.id, session: session
            )
        }

        // `MailboxSyncer` is what swallows this (a sweep failure must not fail
        // the sync); the sweeper itself must leave the stored state untouched
        // so the next pass starts from the same place.
        let stored = try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: mailbox.id!) }
        #expect(stored?.unseenNotFetchedCount == 0)
        #expect(stored?.lastUnseenSweepAt == nil)
    }

    @Test("a mailbox the server reports as fully read has its stale remainder cleared")
    func staleRemainderIsCleared() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        let mailbox = try await makeMailbox(database: database, account: account)
        try await database.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE mailbox SET unseenNotFetchedCount = ? WHERE id = ?", arguments: [10, mailbox.id!]
            )
        }
        let stale = try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: mailbox.id!)! }

        // Everything on the server is read now (elsewhere, or by this device).
        let script = FakeIMAPSession.Script(envelopesByPath: ["INBOX": [makeEnvelope(uid: 1, seen: true)]])
        let session = FakeIMAPSession(config: account.imapConfig, script: script)
        let result = try await UnseenSweeper(database: database).sweep(
            mailboxRecord: stale, mailboxPath: "INBOX", accountId: account.id, session: session
        )

        #expect(result?.serverUnseenCount == 0)
        #expect(result?.remainingCount == 0)
        let stored = try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: mailbox.id!) }
        #expect(stored?.unseenNotFetchedCount == 0)
    }
}
