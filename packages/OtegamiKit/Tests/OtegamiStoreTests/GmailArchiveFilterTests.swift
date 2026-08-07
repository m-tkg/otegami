import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// Task #52, 2: Gmail の「アーカイブ」は単純な All Mail (role `.all`) 全件
/// ではなく、ユーザー指定の Gmail 検索式 `-in:spam -in:trash -is:sent
/// -in:drafts -in:inbox` と等価な集合 — All Mail のメッセージのうち、同一
/// アカウントの INBOX/Sent/Drafts にも存在するもの (= 未アーカイブ/送信
/// コピー/下書きの写し) を除外する。判定は`MessageRecord.gmailMessageId`
/// (`X-GM-MSGID`) の同一アカウント内突き合わせ — `GmailArchiveFilter
/// .excludeUnarchivedSQL`が実装する WHERE 断片を、`ThreadQuery.request
/// (mailboxId:)`/`unifiedInboxRequest(accountIds:role:)`双方から検証する。
@Suite("GmailArchiveFilter")
struct GmailArchiveFilterTests {
    private func makeDatabase() throws -> (
        database: AppDatabase, gmailAccountId: String,
        allMailId: Int64, inboxId: Int64, sentId: Int64, draftsId: Int64
    ) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Gmail", email: "g@example.test", authType: .oauth2, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapUsername: "g@example.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        let (allMailId, inboxId, sentId, draftsId) = try database.dbWriter.write { db -> (Int64, Int64, Int64, Int64) in
            var allMail = MailboxRecord(accountId: account.id, path: "[Gmail]/All Mail", displayPath: "All Mail", role: .all)
            allMail = try allMail.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            inbox = try inbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var sent = MailboxRecord(accountId: account.id, path: "[Gmail]/Sent Mail", displayPath: "Sent Mail", role: .sent)
            sent = try sent.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var drafts = MailboxRecord(accountId: account.id, path: "[Gmail]/Drafts", displayPath: "Drafts", role: .drafts)
            drafts = try drafts.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return (allMail.id!, inbox.id!, sent.id!, drafts.id!)
        }
        return (database, account.id, allMailId, inboxId, sentId, draftsId)
    }

    /// Inserts one `ThreadRecord` plus one message in `allMailId` carrying
    /// `gmailMessageId`, and — when `duplicateMailboxId` is non-`nil` — a
    /// second message (same thread, same `gmailMessageId`, different
    /// `mailboxId`/`uid`) mirroring how the *same* physical Gmail message
    /// shows up as a separate row per label/mailbox it's filed under.
    @discardableResult
    private func insertGmailMessage(
        accountId: String, allMailId: Int64, gmailMessageId: Int64, date: Date,
        duplicateInMailboxId: Int64? = nil, db: Database
    ) throws -> Int64 {
        var thread = ThreadRecord(accountId: accountId, lastMessageDate: date, messageCount: duplicateInMailboxId == nil ? 1 : 2)
        try thread.insert(db)
        var allMailMessage = MessageRecord(
            mailboxId: allMailId, uid: gmailMessageId, date: date, internalDate: date,
            gmailMessageId: gmailMessageId, threadId: thread.id
        )
        try allMailMessage.insert(db)
        if let duplicateInMailboxId {
            var duplicate = MessageRecord(
                mailboxId: duplicateInMailboxId, uid: gmailMessageId, date: date, internalDate: date,
                gmailMessageId: gmailMessageId, threadId: thread.id
            )
            try duplicate.insert(db)
        }
        return thread.id!
    }

    @Test("request(mailboxId: allMailId) excludes an All Mail message that's also in INBOX")
    func requestExcludesInboxDuplicate() throws {
        let (database, accountId, allMailId, inboxId, _, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try database.dbWriter.write { db in
            try insertGmailMessage(accountId: accountId, allMailId: allMailId, gmailMessageId: 1, date: base, duplicateInMailboxId: inboxId, db: db)
        }

        let threadIds = try database.dbWriter.read { db in
            try ThreadQuery.request(mailboxId: allMailId).fetchAll(db).map(\.id)
        }
        #expect(threadIds.isEmpty, "A message still in INBOX isn't archived yet, so it shouldn't count as one")
    }

    @Test("request(mailboxId: allMailId) excludes an All Mail message that's also in Sent")
    func requestExcludesSentDuplicate() throws {
        let (database, accountId, allMailId, _, sentId, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try database.dbWriter.write { db in
            try insertGmailMessage(accountId: accountId, allMailId: allMailId, gmailMessageId: 1, date: base, duplicateInMailboxId: sentId, db: db)
        }

        let threadIds = try database.dbWriter.read { db in
            try ThreadQuery.request(mailboxId: allMailId).fetchAll(db).map(\.id)
        }
        #expect(threadIds.isEmpty, "A message that's just Gmail's own sent-copy shouldn't count as archived")
    }

    @Test("request(mailboxId: allMailId) excludes an All Mail message that's also in Drafts")
    func requestExcludesDraftsDuplicate() throws {
        let (database, accountId, allMailId, _, _, draftsId) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try database.dbWriter.write { db in
            try insertGmailMessage(accountId: accountId, allMailId: allMailId, gmailMessageId: 1, date: base, duplicateInMailboxId: draftsId, db: db)
        }

        let threadIds = try database.dbWriter.read { db in
            try ThreadQuery.request(mailboxId: allMailId).fetchAll(db).map(\.id)
        }
        #expect(threadIds.isEmpty, "A draft's copy in All Mail shouldn't count as archived")
    }

    @Test("request(mailboxId: allMailId) includes a message that's only in All Mail")
    func requestIncludesGenuinelyArchivedMessage() throws {
        let (database, accountId, allMailId, _, _, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let archivedThread = try database.dbWriter.write { db in
            try insertGmailMessage(accountId: accountId, allMailId: allMailId, gmailMessageId: 1, date: base, db: db)
        }

        let threadIds = try database.dbWriter.read { db in
            try ThreadQuery.request(mailboxId: allMailId).fetchAll(db).map(\.id)
        }
        #expect(threadIds == [archivedThread], "A message with no INBOX/Sent/Drafts duplicate is genuinely archived")
    }

    @Test("unifiedInboxRequest(role: .archive) maps Gmail to All Mail and applies the same archive definition")
    func unifiedInboxRequestMapsGmailArchiveWithExclusion() throws {
        let (database, accountId, allMailId, inboxId, _, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (archived, _) = try database.dbWriter.write { db -> (Int64, Int64) in
            let archived = try insertGmailMessage(accountId: accountId, allMailId: allMailId, gmailMessageId: 1, date: base, db: db)
            let notArchived = try insertGmailMessage(
                accountId: accountId, allMailId: allMailId, gmailMessageId: 2, date: base.addingTimeInterval(60),
                duplicateInMailboxId: inboxId, db: db
            )
            return (archived, notArchived)
        }

        let threadIds = try database.dbWriter.read { db in
            try ThreadQuery.unifiedInboxRequest(accountIds: [accountId], role: .archive).fetchAll(db).map(\.id)
        }
        #expect(threadIds == [archived], "Expected only the genuinely-archived thread from Gmail's All Mail")
    }

    @Test("unifiedInboxFlatSummaries(role: .archive) applies the same exclusion in flat mode")
    func unifiedInboxFlatSummariesAppliesExclusion() throws {
        let (database, accountId, allMailId, inboxId, _, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            _ = try insertGmailMessage(accountId: accountId, allMailId: allMailId, gmailMessageId: 1, date: base, db: db)
            _ = try insertGmailMessage(
                accountId: accountId, allMailId: allMailId, gmailMessageId: 2, date: base.addingTimeInterval(60),
                duplicateInMailboxId: inboxId, db: db
            )
        }

        let flat = try database.dbWriter.read { db in
            try ThreadQuery.unifiedInboxFlatSummaries(accountIds: [accountId], role: .archive, db: db)
        }
        #expect(flat.count == 1, "Expected only the genuinely-archived All Mail message, not the still-in-INBOX one")
    }

    /// 実機報告「iOS で Gmail のさっき受信したメールをアーカイブしたらどこにも
    /// 表示されなくなった」の表示側の担保: `MessageRemoval` は All Mail 行が
    /// まだ同期されていない Gmail メールをアーカイブするとき、その行を All
    /// Mail へ擬似 UID (`MessageRecord.isPendingRelocation`、`uid <= 0`) で
    /// 移送する。表示クエリは同期カーソル (`MessageQuery.maxUID`/`minUID`)
    /// と違って `uid > 0` を要求しないので、その行はそのままアーカイブとして
    /// 見える — これが「アーカイブした瞬間から見える」の根拠であり、うっかり
    /// 表示側に `uid > 0` を足すと即座に退行する。
    @Test("a pending-relocation All Mail row (uid <= 0) counts as archived in both grouped and flat mode")
    func pendingRelocationRowCountsAsArchived() throws {
        let (database, accountId, allMailId, _, _, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(
                mailboxId: allMailId, uid: 1, date: base, internalDate: base,
                gmailMessageId: 7, threadId: thread.id
            )
            try message.insert(db)
            // What `MessageRemoval` writes: same row, moved into All Mail with
            // a placeholder UID derived from its own id.
            message.uid = -message.id!
            try message.update(db)
            return thread.id!
        }

        let (grouped, flat, isArchived) = try database.dbWriter.read { db in
            (
                try ThreadQuery.unifiedInboxRequest(accountIds: [accountId], role: .archive).fetchAll(db).map(\.id),
                try ThreadQuery.unifiedInboxFlatSummaries(accountIds: [accountId], role: .archive, db: db),
                try ThreadQuery.isThreadArchived(threadId: threadId, db: db)
            )
        }
        #expect(grouped == [threadId])
        #expect(flat.count == 1)
        #expect(isArchived == true)
    }

    @Test("a pending-relocation All Mail row is excluded again once the same message reappears in INBOX (undo)")
    func pendingRelocationRowIsExcludedAfterUndo() throws {
        let (database, accountId, allMailId, inboxId, _, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(
                mailboxId: allMailId, uid: 1, date: base, internalDate: base,
                gmailMessageId: 8, threadId: thread.id
            )
            try message.insert(db)
            message.uid = -message.id!
            try message.update(db)
            // An INBOX row for the same message appears again — either undo
            // restored it, or アーカイブ解除's COPY got synced back.
            var restored = MessageRecord(
                mailboxId: inboxId, uid: 5, date: base, internalDate: base,
                gmailMessageId: 8, threadId: thread.id
            )
            try restored.insert(db)
            return thread.id!
        }

        let (grouped, isArchived) = try database.dbWriter.read { db in
            (
                try ThreadQuery.unifiedInboxRequest(accountIds: [accountId], role: .archive).fetchAll(db).map(\.id),
                try ThreadQuery.isThreadArchived(threadId: threadId, db: db)
            )
        }
        #expect(grouped.isEmpty)
        #expect(isArchived == false)
    }

    @Test("unreadCounts(accountId:) excludes All Mail's not-yet-archived unread messages from the badge")
    func unreadCountsExcludesUnarchivedAllMailMessages() throws {
        let (database, accountId, allMailId, inboxId, _, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            // A genuinely archived, unread message.
            var archivedThread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 1)
            try archivedThread.insert(db)
            var archived = MessageRecord(mailboxId: allMailId, uid: 1, date: base, internalDate: base, gmailMessageId: 1, threadId: archivedThread.id)
            try archived.insert(db)

            // The same inbox message duplicated into All Mail — both copies
            // unread; the All Mail copy shouldn't count toward its badge.
            var inboxThread = ThreadRecord(accountId: accountId, lastMessageDate: base.addingTimeInterval(60), messageCount: 2)
            try inboxThread.insert(db)
            var inboxCopy = MessageRecord(mailboxId: inboxId, uid: 2, date: base.addingTimeInterval(60), internalDate: base.addingTimeInterval(60), gmailMessageId: 2, threadId: inboxThread.id)
            try inboxCopy.insert(db)
            var allMailCopy = MessageRecord(mailboxId: allMailId, uid: 2, date: base.addingTimeInterval(60), internalDate: base.addingTimeInterval(60), gmailMessageId: 2, threadId: inboxThread.id)
            try allMailCopy.insert(db)
        }

        let counts = try database.dbWriter.read { db in try MessageQuery.unreadCounts(accountId: accountId, db: db) }
        #expect(counts[allMailId] == 1, "Expected only the genuinely-archived message in the All Mail badge, not the INBOX-duplicated one")
        #expect(counts[inboxId] == 1)
    }

    @Test("unifiedInboxUnreadCount(role: .archive) matches the thread-list definition for Gmail")
    func unifiedInboxUnreadCountMatchesArchiveDefinition() throws {
        let (database, accountId, allMailId, inboxId, _, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            _ = try insertGmailMessage(accountId: accountId, allMailId: allMailId, gmailMessageId: 1, date: base, db: db)
            _ = try insertGmailMessage(
                accountId: accountId, allMailId: allMailId, gmailMessageId: 2, date: base.addingTimeInterval(60),
                duplicateInMailboxId: inboxId, db: db
            )
        }

        let count = try database.dbWriter.read { db in
            try MessageQuery.unifiedInboxUnreadCount(accountIds: [accountId], role: .archive, db: db)
        }
        #expect(count == 1)
    }

    /// Regression: a non-Gmail account's `.archive`-role mailbox must keep
    /// working exactly as before — `GmailArchiveFilter`'s guard clause
    /// (`account.kind = 'gmail'`) should make it a no-op here.
    @Test("A non-Gmail account's archive mailbox is unaffected by the Gmail exclusion filter")
    func nonGmailArchiveMailboxIsUnaffected() throws {
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
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let archivedThread = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: account.id, lastMessageDate: base, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(mailboxId: archiveId, uid: 1, date: base, internalDate: base, threadId: thread.id)
            try message.insert(db)
            return thread.id!
        }
        _ = inboxId

        let threadIds = try database.dbWriter.read { db in
            try ThreadQuery.unifiedInboxRequest(accountIds: [account.id], role: .archive).fetchAll(db).map(\.id)
        }
        #expect(threadIds == [archivedThread])
    }

    // MARK: - Task #141: 「すべてのメール」(role `.all`) の非Gmail「全 mailbox
    // 横断」定義

    /// `unifiedInboxRequest(role: .all)`/`unifiedInboxFlatSummaries(role:
    /// .all)`/`MessageQuery.unifiedInboxUnreadCount(role: .all)`が共有する
    /// フィクスチャ — Gmail アカウント (All Mail に「本当にアーカイブ済み」
    /// 1件+「INBOXにも残っている(=未アーカイブ)」1件) と、`\All`
    /// special-useを持たない非Gmailアカウント (INBOX 1件 + Archive 1件、
    /// どちらも「すべてのメール」に含まれるべき) の両方を用意する。
    private func makeMixedAccountsDatabase() throws -> (
        database: AppDatabase, gmailAccountId: String, allMailId: Int64, gmailInboxId: Int64,
        imapAccountId: String, imapInboxId: Int64, imapArchiveId: Int64
    ) {
        let (database, gmailAccountId, allMailId, gmailInboxId, _, _) = try makeDatabase()
        let imapAccount = AccountRecord(
            displayName: "IMAP", email: "i2@example.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "i2@example.test"
        )
        let (imapInboxId, imapArchiveId) = try database.dbWriter.write { db -> (Int64, Int64) in
            try imapAccount.insert(db)
            var inbox = MailboxRecord(accountId: imapAccount.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            inbox = try inbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var archive = MailboxRecord(accountId: imapAccount.id, path: "Archive", displayPath: "Archive", role: .archive)
            archive = try archive.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return (inbox.id!, archive.id!)
        }
        return (database, gmailAccountId, allMailId, gmailInboxId, imapAccount.id, imapInboxId, imapArchiveId)
    }

    @Test("unifiedInboxRequest(role: .all) includes a non-Gmail account's mail from every mailbox, not just one role")
    func unifiedInboxRequestAllRoleSpansEveryNonGmailMailbox() throws {
        let (database, gmailAccountId, allMailId, gmailInboxId, imapAccountId, imapInboxId, imapArchiveId) = try makeMixedAccountsDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (gmailArchived, imapInboxThread, imapArchiveThread) = try database.dbWriter.write { db -> (Int64, Int64, Int64) in
            // Gmail: only the genuinely-archived All Mail message counts —
            // the INBOX-duplicated one stays excluded, same as `.archive`.
            let gmailArchived = try insertGmailMessage(accountId: gmailAccountId, allMailId: allMailId, gmailMessageId: 1, date: base, db: db)
            _ = try insertGmailMessage(
                accountId: gmailAccountId, allMailId: allMailId, gmailMessageId: 2, date: base.addingTimeInterval(60),
                duplicateInMailboxId: gmailInboxId, db: db
            )
            // Non-Gmail: both its INBOX and Archive mailboxes should count
            // — "すべてのメール" for a non-Gmail account is every one of its
            // mailboxes, not one role.
            var imapInboxThread = ThreadRecord(accountId: imapAccountId, lastMessageDate: base.addingTimeInterval(120), messageCount: 1)
            try imapInboxThread.insert(db)
            var imapInboxMessage = MessageRecord(mailboxId: imapInboxId, uid: 1, date: base.addingTimeInterval(120), internalDate: base.addingTimeInterval(120), threadId: imapInboxThread.id)
            try imapInboxMessage.insert(db)

            var imapArchiveThread = ThreadRecord(accountId: imapAccountId, lastMessageDate: base.addingTimeInterval(180), messageCount: 1)
            try imapArchiveThread.insert(db)
            var imapArchiveMessage = MessageRecord(mailboxId: imapArchiveId, uid: 1, date: base.addingTimeInterval(180), internalDate: base.addingTimeInterval(180), threadId: imapArchiveThread.id)
            try imapArchiveMessage.insert(db)

            return (gmailArchived, imapInboxThread.id!, imapArchiveThread.id!)
        }

        let threadIds = try database.dbWriter.read { db in
            try ThreadQuery.unifiedInboxRequest(accountIds: [gmailAccountId, imapAccountId], role: .all).fetchAll(db).map(\.id)
        }
        #expect(
            Set(threadIds) == Set([gmailArchived, imapInboxThread, imapArchiveThread]),
            "Expected the Gmail account's genuinely-archived All Mail thread plus both of the non-Gmail account's threads"
        )
    }

    @Test("unifiedInboxFlatSummaries(role: .all) applies the same non-Gmail any-mailbox scope in flat mode")
    func unifiedInboxFlatSummariesAllRoleSpansEveryNonGmailMailbox() throws {
        let (database, gmailAccountId, allMailId, _, imapAccountId, imapInboxId, imapArchiveId) = try makeMixedAccountsDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            _ = try insertGmailMessage(accountId: gmailAccountId, allMailId: allMailId, gmailMessageId: 1, date: base, db: db)

            var imapInboxThread = ThreadRecord(accountId: imapAccountId, lastMessageDate: base.addingTimeInterval(60), messageCount: 1)
            try imapInboxThread.insert(db)
            var imapInboxMessage = MessageRecord(mailboxId: imapInboxId, uid: 1, date: base.addingTimeInterval(60), internalDate: base.addingTimeInterval(60), threadId: imapInboxThread.id)
            try imapInboxMessage.insert(db)

            var imapArchiveThread = ThreadRecord(accountId: imapAccountId, lastMessageDate: base.addingTimeInterval(120), messageCount: 1)
            try imapArchiveThread.insert(db)
            var imapArchiveMessage = MessageRecord(mailboxId: imapArchiveId, uid: 1, date: base.addingTimeInterval(120), internalDate: base.addingTimeInterval(120), threadId: imapArchiveThread.id)
            try imapArchiveMessage.insert(db)
        }

        let flat = try database.dbWriter.read { db in
            try ThreadQuery.unifiedInboxFlatSummaries(accountIds: [gmailAccountId, imapAccountId], role: .all, db: db)
        }
        #expect(flat.count == 3, "Expected 1 genuinely-archived Gmail message + the non-Gmail account's INBOX and Archive messages")
    }

    @Test("unifiedInboxUnreadCount(role: .all) sums the non-Gmail account's every mailbox, not just one role")
    func unifiedInboxUnreadCountAllRoleSpansEveryNonGmailMailbox() throws {
        let (database, gmailAccountId, allMailId, gmailInboxId, imapAccountId, imapInboxId, imapArchiveId) = try makeMixedAccountsDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            // Gmail: 1 genuinely-archived unread message, 1 excluded (still in INBOX).
            _ = try insertGmailMessage(accountId: gmailAccountId, allMailId: allMailId, gmailMessageId: 1, date: base, db: db)
            _ = try insertGmailMessage(
                accountId: gmailAccountId, allMailId: allMailId, gmailMessageId: 2, date: base.addingTimeInterval(60),
                duplicateInMailboxId: gmailInboxId, db: db
            )
            // Non-Gmail: 1 unread in INBOX, 1 unread in Archive — both count.
            var imapInboxMessage = MessageRecord(mailboxId: imapInboxId, uid: 1, date: base.addingTimeInterval(120), internalDate: base.addingTimeInterval(120))
            try imapInboxMessage.insert(db)
            var imapArchiveMessage = MessageRecord(mailboxId: imapArchiveId, uid: 1, date: base.addingTimeInterval(180), internalDate: base.addingTimeInterval(180))
            try imapArchiveMessage.insert(db)
        }

        let count = try database.dbWriter.read { db in
            try MessageQuery.unifiedInboxUnreadCount(accountIds: [gmailAccountId, imapAccountId], role: .all, db: db)
        }
        #expect(count == 3, "Expected 1 (Gmail, archived-only) + 2 (non-Gmail, every mailbox)")
    }
}
