import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// Real-device report (iPad, Gmail): opening a thread in the accordion
/// showed every message duplicated. Root cause: Gmail syncs the same
/// physical email once per IMAP folder it belongs to (Gmail's dual-labeling
/// model — every message is in All Mail *and* whichever other special-use
/// folder(s) apply), so the same email becomes two `message` rows sharing
/// one `gmailMessageId` but different `mailboxId`. Widening All Mail
/// sync/reference (see `docs/design-system.md`) made this visible.
///
/// Covers `ThreadQuery.messages(threadId:db:)`'s dedup (identity:
/// `gmailMessageId` when non-`nil`, else `messageId`; rows with both `nil`
/// are never deduplicated; a role-bearing mailbox's row wins over an
/// All-Mail/no-role one) and `ThreadAssigner`'s two aggregate paths
/// (`recomputeAggregates(threadId:db:)` and the bulk SQL path exercised via
/// `assignAllUnthreaded`), which must agree with each other and with the
/// deduplicated message list.
@Suite("Thread duplicate-message dedup")
struct ThreadDuplicateMessageDedupTests {
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

    // MARK: - ThreadQuery.messages(threadId:db:) dedup

    @Test("messages(threadId:db:) collapses an INBOX/All-Mail duplicate to the INBOX row")
    func messagesDeduplicatesByGmailMessageIdPreferringRoleBearingMailbox() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, inboxMessageId) = try database.dbWriter.write { db -> (Int64, Int64) in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 2)
            try thread.insert(db)
            var allMailMessage = MessageRecord(
                mailboxId: allMailId, uid: 1, date: base, internalDate: base,
                gmailMessageId: 42, threadId: thread.id
            )
            try allMailMessage.insert(db)
            var inboxMessage = MessageRecord(
                mailboxId: inboxId, uid: 1, date: base, internalDate: base,
                gmailMessageId: 42, threadId: thread.id
            )
            try inboxMessage.insert(db)
            return (thread.id!, inboxMessage.id!)
        }

        let messages = try database.dbWriter.read { db in try ThreadQuery.messages(threadId: threadId, db: db) }
        #expect(messages.count == 1)
        #expect(messages.first?.id == inboxMessageId)
        #expect(messages.first?.mailboxId == inboxId)
    }

    @Test("A non-Gmail thread with genuinely distinct messages is unaffected")
    func distinctMessagesWithoutGmailIdsAreNotDeduplicated() throws {
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
            var thread = ThreadRecord(accountId: account.id, lastMessageDate: base, messageCount: 2)
            try thread.insert(db)
            var first = MessageRecord(
                mailboxId: inboxId, uid: 1, messageId: "<one@example.test>",
                date: base, internalDate: base, threadId: thread.id
            )
            try first.insert(db)
            var second = MessageRecord(
                mailboxId: inboxId, uid: 2, messageId: "<two@example.test>",
                date: base.addingTimeInterval(60), internalDate: base.addingTimeInterval(60), threadId: thread.id
            )
            try second.insert(db)
            return thread.id!
        }

        let messages = try database.dbWriter.read { db in try ThreadQuery.messages(threadId: threadId, db: db) }
        #expect(messages.count == 2)
    }

    @Test("Rows sharing an identity key but neither in a role-bearing mailbox: kept exactly once, greater uid wins")
    func defensiveTieBreakWhenNeitherRowIsRoleBearing() throws {
        // Two rows both in All Mail (role .all, not role-bearing) somehow
        // sharing the same gmailMessageId — not expected in practice (a
        // message can't really be filed in the same label twice), but
        // `deduplicate(_:db:)` must not crash and must pick deterministically:
        // the documented tie-break is "greater uid wins".
        let (database, accountId, _, allMailId) = try makeGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, higherUidMessageId) = try database.dbWriter.write { db -> (Int64, Int64) in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 2)
            try thread.insert(db)
            var lower = MessageRecord(
                mailboxId: allMailId, uid: 1, date: base, internalDate: base,
                gmailMessageId: 99, threadId: thread.id
            )
            try lower.insert(db)
            var higher = MessageRecord(
                mailboxId: allMailId, uid: 2, date: base, internalDate: base,
                gmailMessageId: 99, threadId: thread.id
            )
            try higher.insert(db)
            return (thread.id!, higher.id!)
        }

        let messages = try database.dbWriter.read { db in try ThreadQuery.messages(threadId: threadId, db: db) }
        #expect(messages.count == 1)
        #expect(messages.first?.id == higherUidMessageId)
    }

    /// 実機報告 (2026-08-16, Gmail アカウント)「特定の1通に対して削除・
    /// アーカイブ解除・未読化が完全無反応」の再現＆修正確認。role の
    /// 優先だけでタイブレークしていた頃は、role を持つ Trash に取り残された
    /// `MessageRecord.isPendingRelocation` (`uid <= 0`) のゴースト行が、
    /// role の無い All Mail の本物の行 (`uid >= 1`) より優先されてしまい、
    /// ユーザーが実際に見て操作するのが決して昇格しないゴーストになって
    /// いた。ゴーストは role に関わらず必ず負ける、という新しいタイブレーク
    /// がこれを直すことを確認する。
    @Test("A pending-relocation ghost row loses the tie-break to a real row even when the ghost sits in a role-bearing mailbox")
    func ghostRowLosesTieBreakToRealRowEvenInRoleBearingMailbox() throws {
        let (database, accountId, _, allMailId) = try makeGmailDatabase()
        let trashId = try database.dbWriter.write { db -> Int64 in
            var trash = MailboxRecord(accountId: accountId, path: "[Gmail]/Trash", displayPath: "Trash", role: .trash)
            trash = try trash.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return trash.id!
        }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, realMessageId) = try database.dbWriter.write { db -> (Int64, Int64) in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 2)
            try thread.insert(db)
            // The ghost: stuck in Trash (a role-bearing mailbox) with a
            // synthetic placeholder UID, e.g. left behind by R3 or a
            // staleDiscarded op.
            var ghost = MessageRecord(
                mailboxId: trashId, uid: -5, date: base, internalDate: base,
                gmailMessageId: 4242, threadId: thread.id
            )
            try ghost.insert(db)
            // The real, server-confirmed row — All Mail (no recognized
            // role), but with a genuine UID.
            var real = MessageRecord(
                mailboxId: allMailId, uid: 1234, date: base, internalDate: base,
                gmailMessageId: 4242, threadId: thread.id
            )
            try real.insert(db)
            return (thread.id!, real.id!)
        }

        let messages = try database.dbWriter.read { db in try ThreadQuery.messages(threadId: threadId, db: db) }
        #expect(messages.count == 1)
        #expect(messages.first?.id == realMessageId, "the real row must win, not the role-bearing ghost")
        #expect(messages.first?.mailboxId == allMailId)
        #expect(messages.first?.isPendingRelocation == false)
    }

    // MARK: - ThreadAssigner.recomputeAggregates(threadId:db:) singular path

    @Test("recomputeAggregates(threadId:db:) counts the deduplicated messageCount/unreadCount, not the raw row count")
    func recomputeAggregatesUsesDeduplicatedCounts() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 0)
            try thread.insert(db)
            // The All-Mail duplicate is unread; the INBOX row (the one that
            // survives dedup and is what the user actually sees) is read.
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

        try database.dbWriter.write { db in try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db) }

        let thread = try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) }
        #expect(thread?.messageCount == 1, "two rows for the same physical email should count as one message")
        #expect(thread?.unreadCount == 0, "the surviving (INBOX) row is read, even though its All-Mail duplicate is unread")
    }

    // MARK: - Bulk aggregate path (ThreadAssigner.assignAllUnthreaded)

    @Test("assignAllUnthreaded's bulk aggregate path also counts the deduplicated messageCount/unreadCount")
    func bulkAggregatePathMatchesSingularPath() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Two never-before-threaded rows for the same physical Gmail email
        // (same gmailThreadId so BatchThreader joins them into one thread,
        // same gmailMessageId so dedup collapses them into one). The INBOX
        // row is unread; the All-Mail duplicate is read — unreadCount must
        // reflect the surviving (INBOX) row's own state, not "any row
        // unread" or "all rows unread".
        try database.dbWriter.write { db in
            var inboxMessage = MessageRecord(
                mailboxId: inboxId, uid: 1, date: base, internalDate: base,
                flagsRaw: 0, gmailThreadId: 5, gmailMessageId: 5, threadId: nil
            )
            try inboxMessage.insert(db)
            var allMailMessage = MessageRecord(
                mailboxId: allMailId, uid: 1, date: base, internalDate: base,
                flagsRaw: MessageFlags.seen.rawValue, gmailThreadId: 5, gmailMessageId: 5, threadId: nil
            )
            try allMailMessage.insert(db)
        }

        try database.dbWriter.write { db in try ThreadAssigner.assignAllUnthreaded(accountId: accountId, db: db) }

        let threads = try database.dbWriter.read { db in try ThreadRecord.fetchAll(db) }
        #expect(threads.count == 1, "both rows should have joined the same thread via matching gmailThreadId")
        #expect(threads.first?.messageCount == 1)
        #expect(threads.first?.unreadCount == 1, "the surviving INBOX row is unread")
    }

    // MARK: - isPinned (実機報告 2026-08-07「メールの unpin が反映されない」)

    /// `isPinned`は元々「MAXベースで重複に対して安全」という判断で dedup
    /// 前の全行の OR だったが、行アクションが触るのは dedup 済みの代表行
    /// だけなので、All Mail 側の行が1つ`true`のまま残るとピンが永久に
    /// 落ちなかった。`messageCount`/`unreadCount`と同じ dedup 済みの定義へ
    /// 揃えた — その2つと同じく、**Swift パスと一括 SQL パスの両方**を
    /// 同じ入力で突き合わせる (`aggregateUpdateSQL`の doc comment が
    /// 警戒している「定義が散らばって食い違う」リスクが、2実装を同時に
    /// 直すことで顕在化するため)。
    @Test("recomputeAggregates(threadId:db:) の isPinned は dedup 後の代表行だけを見る")
    func recomputeAggregatesUsesDeduplicatedIsPinned() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 0)
            try thread.insert(db)
            // 実機で起きていた状態そのもの: 代表行 (INBOX) は解除済みなのに、
            // 同期が戻した All Mail 側の重複行だけピンが残っている。
            var inboxMessage = MessageRecord(
                mailboxId: inboxId, uid: 1, date: base, internalDate: base,
                flagsRaw: 0, gmailMessageId: 7, threadId: thread.id, isPinnedLocal: false
            )
            try inboxMessage.insert(db)
            var allMailMessage = MessageRecord(
                mailboxId: allMailId, uid: 1, date: base, internalDate: base,
                flagsRaw: MessageFlags.flagged.rawValue, gmailMessageId: 7, threadId: thread.id, isPinnedLocal: true
            )
            try allMailMessage.insert(db)
            return thread.id!
        }

        try database.dbWriter.write { db in try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db) }

        let thread = try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) }
        #expect(thread?.isPinned == false, "生き残った INBOX 行が解除済みなら、All Mail の重複行が残っていてもピンは落ちる")
    }

    @Test("一括 SQL パスの isPinned も dedup 後の代表行だけを見る")
    func bulkAggregatePathUsesDeduplicatedIsPinned() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            var inboxMessage = MessageRecord(
                mailboxId: inboxId, uid: 1, date: base, internalDate: base,
                flagsRaw: 0, gmailThreadId: 5, gmailMessageId: 5, threadId: nil, isPinnedLocal: false
            )
            try inboxMessage.insert(db)
            var allMailMessage = MessageRecord(
                mailboxId: allMailId, uid: 1, date: base, internalDate: base,
                flagsRaw: MessageFlags.flagged.rawValue, gmailThreadId: 5, gmailMessageId: 5, threadId: nil, isPinnedLocal: true
            )
            try allMailMessage.insert(db)
        }

        try database.dbWriter.write { db in try ThreadAssigner.assignAllUnthreaded(accountId: accountId, db: db) }

        let threads = try database.dbWriter.read { db in try ThreadRecord.fetchAll(db) }
        #expect(threads.count == 1)
        #expect(threads.first?.isPinned == false, "Swift パスと同じ結果になること")
    }

    /// 逆向き — 代表行にピンが立っていれば、重複行が解除済みでもピンは立つ。
    @Test("代表行にピンが立っていれば isPinned は true")
    func survivingRowPinnedYieldsPinnedThread() throws {
        let (database, accountId, inboxId, allMailId) = try makeGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 0)
            try thread.insert(db)
            var inboxMessage = MessageRecord(
                mailboxId: inboxId, uid: 1, date: base, internalDate: base,
                flagsRaw: MessageFlags.flagged.rawValue, gmailMessageId: 7, threadId: thread.id, isPinnedLocal: true
            )
            try inboxMessage.insert(db)
            var allMailMessage = MessageRecord(
                mailboxId: allMailId, uid: 1, date: base, internalDate: base,
                flagsRaw: 0, gmailMessageId: 7, threadId: thread.id, isPinnedLocal: false
            )
            try allMailMessage.insert(db)
            return thread.id!
        }

        try database.dbWriter.write { db in try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db) }

        let thread = try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) }
        #expect(thread?.isPinned == true)
    }

    /// 重複が無いスレッドでは、どの行がピン留めされていてもスレッドは
    /// ピン留め扱い (dedup 化の前後で挙動が変わらないこと)。
    @Test("重複が無いスレッドでは1通でもピン留めされていれば isPinned は true")
    func nonDuplicateThreadKeepsOrSemantics() throws {
        let (database, accountId, inboxId, _) = try makeGmailDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 0)
            try thread.insert(db)
            for (index, pinned) in [false, true].enumerated() {
                var message = MessageRecord(
                    mailboxId: inboxId, uid: Int64(index + 1),
                    messageId: "<distinct-\(index)@otegami.test>",
                    date: base, internalDate: base,
                    flagsRaw: pinned ? MessageFlags.flagged.rawValue : 0,
                    threadId: thread.id, isPinnedLocal: pinned
                )
                try message.insert(db)
            }
            return thread.id!
        }

        try database.dbWriter.write { db in try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db) }

        let thread = try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) }
        #expect(thread?.messageCount == 2)
        #expect(thread?.isPinned == true)
    }
}
