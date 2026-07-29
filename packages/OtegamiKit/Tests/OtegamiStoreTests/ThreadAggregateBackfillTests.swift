import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// 実機フィードバック (2026-07-30, Gmail、Oktaの通知メール):「一覧の通数
/// バッジが3なのに、開くと1通しかない」。原因: a54f585 で
/// `thread.messageCount`/`unreadCount` は dedup 済みの定義になったが
/// (`ThreadDuplicateMessageDedupTests`参照)、それは「これから書かれる値」
/// にしか適用されず、**修正前に書き込まれた重複込みの値はそのスレッドの
/// membership が次に変わるまで残り続ける**。詳細画面 (`ThreadQuery
/// .messages(threadId:db:)`) は表示のたびに dedup を再計算するので常に
/// 正しいが、一覧バッジは保存列を読むだけなので古い値のまま。
///
/// `ThreadAssigner.recomputeAllAggregates(db:)` (Task #168, `apply`が使う
/// のと同じ単一UPDATE文を`WHERE`節なしで全スレッドに対して実行する形で
/// 切り出したもの) がこのズレを一度で解消する。ここでは「保存済みの
/// 重複込みの値」を直接 (Swiftの`ThreadRecord`初期化子経由ではなく、その
/// 初期化子はもう重複を作れない値しか許さないため) 書き込んでから
/// `recomputeAllAggregates`を呼び、dedup済みの値へ直ることを確認する —
/// v35 migration が実データに対してやることと同じ形。
@Suite("ThreadAssigner.recomputeAllAggregates backfill")
struct ThreadAggregateBackfillTests {
    private func makeGmailDatabase() throws -> (
        database: AppDatabase, accountId: String, inboxId: Int64, allMailId: Int64
    ) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Gmail", email: "g@example.test", authType: .oauth2, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapUsername: "g@example.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        let (inboxId, allMailMailboxId) = try database.dbWriter.write { db -> (Int64, Int64) in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            inbox = try inbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var allMail = MailboxRecord(accountId: account.id, path: "[Gmail]/All Mail", displayPath: "All Mail", role: .all)
            allMail = try allMail.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return (inbox.id!, allMail.id!)
        }
        return (database, account.id, inboxId, allMailMailboxId)
    }

    @Test("(a) a Gmail thread with a stale duplicate-inflated messageCount is corrected to the deduplicated count")
    func correctsStaleGmailDuplicateCount() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let threadId = try database.dbWriter.write { db -> Int64 in
            // Stored as `messageCount: 3`/`unreadCount: 3` — exactly what a
            // pre-a54f585 raw row-count write would have produced for one
            // physical email present as an unread row in both INBOX and
            // All Mail (this reproduces the real-device report: one Okta
            // notification, badge showed 3, thread had 1 message).
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 3, unreadCount: 3)
            try thread.insert(db)
            var allMailMessage = MessageRecord(
                mailboxId: allMailId, uid: 1, date: base, internalDate: base,
                flagsRaw: 0, gmailMessageId: 42, threadId: thread.id
            )
            try allMailMessage.insert(db)
            var inboxMessage = MessageRecord(
                mailboxId: inboxId, uid: 1, date: base, internalDate: base,
                flagsRaw: 0, gmailMessageId: 42, threadId: thread.id
            )
            try inboxMessage.insert(db)
            return thread.id!
        }

        try database.dbWriter.write { db in try ThreadAssigner.recomputeAllAggregates(db: db) }

        let thread = try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) }
        #expect(thread?.messageCount == 1, "the INBOX/All-Mail duplicate is one physical email, not two")
        #expect(thread?.unreadCount == 1)

        // Detail screen's header count (`ThreadDetailView.navigationTitleText`)
        // must agree with the now-backfilled list badge.
        let detailMessages = try database.dbWriter.read { db in try ThreadQuery.messages(threadId: threadId, db: db) }
        #expect(detailMessages.count == thread?.messageCount)
    }

    @Test("(b) a non-Gmail thread (dedup by messageId, no gmailMessageId) is also corrected")
    func correctsStaleNonGmailDuplicateCount() throws {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@example.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@example.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (inboxId, archiveId) = try database.dbWriter.write { db -> (Int64, Int64) in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            inbox = try inbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var archive = MailboxRecord(accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive)
            archive = try archive.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return (inbox.id!, archive.id!)
        }

        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: account.id, lastMessageDate: base, messageCount: 2, unreadCount: 2)
            try thread.insert(db)
            // Same RFC 822 Message-ID synced into two role-bearing mailboxes
            // (e.g. a resync artifact) — no gmailMessageId at all, so dedup
            // falls back to `messageId`.
            var archiveMessage = MessageRecord(
                mailboxId: archiveId, uid: 1, messageId: "<dup@example.test>",
                date: base, internalDate: base, flagsRaw: 0, threadId: thread.id
            )
            try archiveMessage.insert(db)
            var inboxMessage = MessageRecord(
                mailboxId: inboxId, uid: 5, messageId: "<dup@example.test>",
                date: base, internalDate: base, flagsRaw: 0, threadId: thread.id
            )
            try inboxMessage.insert(db)
            return thread.id!
        }

        try database.dbWriter.write { db in try ThreadAssigner.recomputeAllAggregates(db: db) }

        let thread = try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) }
        #expect(thread?.messageCount == 1)
        #expect(thread?.unreadCount == 1)
    }

    @Test("(c) rows with neither gmailMessageId nor messageId are never deduplicated against each other")
    func rowsWithNoIdentityKeyAreCountedIndividually() throws {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@example.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@example.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let inboxId = try database.dbWriter.write { db -> Int64 in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            inbox = try inbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return inbox.id!
        }

        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: account.id, lastMessageDate: base, messageCount: 0, unreadCount: 0)
            try thread.insert(db)
            // Two genuinely distinct messages, neither with a messageId or
            // gmailMessageId (e.g. malformed mail missing a Message-ID
            // header) — must never collapse into one another.
            var first = MessageRecord(
                mailboxId: inboxId, uid: 1, date: base, internalDate: base, flagsRaw: 0, threadId: thread.id
            )
            try first.insert(db)
            var second = MessageRecord(
                mailboxId: inboxId, uid: 2, date: base.addingTimeInterval(60), internalDate: base.addingTimeInterval(60),
                flagsRaw: 0, threadId: thread.id
            )
            try second.insert(db)
            return thread.id!
        }

        try database.dbWriter.write { db in try ThreadAssigner.recomputeAllAggregates(db: db) }

        let thread = try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) }
        #expect(thread?.messageCount == 2)
        #expect(thread?.unreadCount == 2)
    }

    @Test("(d) unreadCount reflects the surviving (role-bearing) row's read state, not the discarded duplicate's")
    func unreadCountReflectsWinningRowState() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 2, unreadCount: 0)
            try thread.insert(db)
            // The All-Mail duplicate (discarded by dedup) is unread; the
            // INBOX row (the survivor, and what the user actually sees) is
            // read. A naive "any row unread" count would wrongly say 1.
            var allMailMessage = MessageRecord(
                mailboxId: allMailId, uid: 1, date: base, internalDate: base,
                flagsRaw: 0, gmailMessageId: 7, threadId: thread.id
            )
            try allMailMessage.insert(db)
            var inboxMessage = MessageRecord(
                mailboxId: inboxId, uid: 1, date: base, internalDate: base,
                flagsRaw: MessageFlags.seen.rawValue, gmailMessageId: 7, threadId: thread.id
            )
            try inboxMessage.insert(db)
            return thread.id!
        }

        try database.dbWriter.write { db in try ThreadAssigner.recomputeAllAggregates(db: db) }

        let thread = try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) }
        #expect(thread?.messageCount == 1)
        #expect(thread?.unreadCount == 0, "the surviving INBOX row is read, even though its discarded All-Mail duplicate is unread")
    }

    @Test("recomputeAllAggregates touches every thread across every account in one pass")
    func touchesEveryThreadAcrossAccounts() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let otherAccount = AccountRecord(
            displayName: "Other", email: "o@example.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "o@example.test"
        )
        try database.dbWriter.write { db in try otherAccount.insert(db) }
        let otherInboxId = try database.dbWriter.write { db -> Int64 in
            var inbox = MailboxRecord(accountId: otherAccount.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            inbox = try inbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return inbox.id!
        }
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let (gmailThreadId, otherThreadId) = try database.dbWriter.write { db -> (Int64, Int64) in
            var gmailThread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 2, unreadCount: 2)
            try gmailThread.insert(db)
            var allMailMessage = MessageRecord(
                mailboxId: allMailId, uid: 1, date: base, internalDate: base,
                flagsRaw: 0, gmailMessageId: 1, threadId: gmailThread.id
            )
            try allMailMessage.insert(db)
            var inboxMessage = MessageRecord(
                mailboxId: inboxId, uid: 1, date: base, internalDate: base,
                flagsRaw: 0, gmailMessageId: 1, threadId: gmailThread.id
            )
            try inboxMessage.insert(db)

            var otherThread = ThreadRecord(accountId: otherAccount.id, lastMessageDate: base, messageCount: 0, unreadCount: 0)
            try otherThread.insert(db)
            var otherMessage = MessageRecord(
                mailboxId: otherInboxId, uid: 1, date: base, internalDate: base, flagsRaw: 0, threadId: otherThread.id
            )
            try otherMessage.insert(db)

            return (gmailThread.id!, otherThread.id!)
        }

        try database.dbWriter.write { db in try ThreadAssigner.recomputeAllAggregates(db: db) }

        let threads = try database.dbWriter.read { db in
            (
                try ThreadRecord.fetchOne(db, key: gmailThreadId),
                try ThreadRecord.fetchOne(db, key: otherThreadId)
            )
        }
        #expect(threads.0?.messageCount == 1)
        #expect(threads.1?.messageCount == 1, "a thread with no duplicates should still be recomputed (and stay correct)")
    }
}
