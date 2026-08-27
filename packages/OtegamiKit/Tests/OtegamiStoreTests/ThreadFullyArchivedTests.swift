import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// 実機報告 (2026-08-27)「スレッドの親がアーカイブ済みの場合、新しく来た
/// メールのアーカイブができない」の回帰テスト。
///
/// 詳細画面のアーカイブ/迷惑メールスロットは Task #184 で OR 集約
/// (`ThreadQuery.isThreadArchived` — 1通でもアーカイブ済みなら `true`) を
/// 見ていた。そのため「読み終えてアーカイブ → 返信が届く」でできる混在
/// スレッドではスロットが「アーカイブ解除」に化け、
/// `MessageRemoval.commit(.unarchive)` がアーカイブ場所にいる行しか触らない
/// ために新着が素通りして無反応になっていた。スロット判定を AND 集約
/// (`isThreadFullyArchived`/`isThreadFullyJunk` = まだ操作できる行が残って
/// いないか) に移したのがこのファイルの対象。
///
/// バッジ側 (`ThreadSummary.isArchived`、Task #151 の OR 集約) は据え置きな
/// ので、混在スレッドでは「バッジは付くがスロットは『アーカイブ』のまま」に
/// なる — その食い違いが意図どおりであることも併せて固定する。
@Suite("ThreadQuery.isThreadFullyArchived / isThreadFullyJunk")
struct ThreadFullyArchivedTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 非 Gmail (`role == .archive` を直接見る)

    private func makeNonGmailDatabase() throws -> (
        database: AppDatabase, accountId: String, inboxId: Int64, archiveId: Int64, junkId: Int64, customId: Int64
    ) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "IMAP", email: "i@example.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "i@example.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        let ids = try database.dbWriter.write { db -> (Int64, Int64, Int64, Int64) in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            inbox = try inbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var archive = MailboxRecord(accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive)
            archive = try archive.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var junk = MailboxRecord(accountId: account.id, path: "Junk", displayPath: "Junk", role: .junk)
            junk = try junk.upsertAndFetch(db, onConflict: ["accountId", "path"])
            // role を持たない自作フォルダ — 「アーカイブ済みではない」側に
            // 数えられることを確かめるため (`messageIsArchivedSQL` が
            // `role = 'archive'` にも Gmail 分岐にも当たらない行)。
            var custom = MailboxRecord(accountId: account.id, path: "Projects", displayPath: "Projects", role: .none)
            custom = try custom.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return (inbox.id!, archive.id!, junk.id!, custom.id!)
        }
        return (database, account.id, ids.0, ids.1, ids.2, ids.3)
    }

    /// `mailboxIds` の各メールボックスに1通ずつ入った1スレッドを作る。
    private func makeThread(in database: AppDatabase, accountId: String, mailboxIds: [Int64]) throws -> Int64 {
        try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: Self.base, messageCount: mailboxIds.count)
            try thread.insert(db)
            for (index, mailboxId) in mailboxIds.enumerated() {
                var message = MessageRecord(
                    mailboxId: mailboxId, uid: Int64(index + 1), date: Self.base, internalDate: Self.base, threadId: thread.id
                )
                try message.insert(db)
            }
            return thread.id!
        }
    }

    @Test("親が Archive・新着が INBOX の混在スレッド: fullyArchived == false (バッジの OR は true のまま)")
    func mixedThreadIsNotFullyArchived() throws {
        let (database, accountId, inboxId, archiveId, _, _) = try makeNonGmailDatabase()
        let threadId = try makeThread(in: database, accountId: accountId, mailboxIds: [archiveId, inboxId])

        let (fully, anyArchived) = try database.dbWriter.read { db in
            (
                try ThreadQuery.isThreadFullyArchived(threadId: threadId, db: db),
                try ThreadQuery.isThreadArchived(threadId: threadId, db: db)
            )
        }
        #expect(fully == false, "INBOX の新着がまだアーカイブできる — スロットは「アーカイブ」であるべき")
        #expect(anyArchived == true, "バッジ側の OR 集約は据え置き (Task #151)")
    }

    @Test("全メッセージが Archive: fullyArchived == true")
    func fullyArchivedThread() throws {
        let (database, accountId, _, archiveId, _, _) = try makeNonGmailDatabase()
        let threadId = try makeThread(in: database, accountId: accountId, mailboxIds: [archiveId, archiveId])

        let fully = try database.dbWriter.read { db in
            try ThreadQuery.isThreadFullyArchived(threadId: threadId, db: db)
        }
        #expect(fully == true)
    }

    @Test("全メッセージが INBOX: fullyArchived == false")
    func notArchivedAtAll() throws {
        let (database, accountId, inboxId, _, _, _) = try makeNonGmailDatabase()
        let threadId = try makeThread(in: database, accountId: accountId, mailboxIds: [inboxId])

        let fully = try database.dbWriter.read { db in
            try ThreadQuery.isThreadFullyArchived(threadId: threadId, db: db)
        }
        #expect(fully == false)
    }

    @Test("Archive + role なしの自作フォルダ: fullyArchived == false")
    func customFolderCountsAsArchivable() throws {
        let (database, accountId, _, archiveId, _, customId) = try makeNonGmailDatabase()
        let threadId = try makeThread(in: database, accountId: accountId, mailboxIds: [archiveId, customId])

        let fully = try database.dbWriter.read { db in
            try ThreadQuery.isThreadFullyArchived(threadId: threadId, db: db)
        }
        #expect(fully == false, "role を持たないフォルダの行はまだアーカイブできる — `commit(.archive)` の対象になる")
    }

    @Test("メッセージが1通も無いスレッド: fullyArchived == false")
    func emptyThreadIsNotFullyArchived() throws {
        let (database, accountId, _, _, _, _) = try makeNonGmailDatabase()
        let threadId = try makeThread(in: database, accountId: accountId, mailboxIds: [])

        let fully = try database.dbWriter.read { db in
            try ThreadQuery.isThreadFullyArchived(threadId: threadId, db: db)
        }
        #expect(fully == false, "アーカイブできる行が無いことを「全部アーカイブ済み」とは呼ばない")
    }

    // MARK: - 迷惑メール (同じ AND 集約)

    @Test("Junk + INBOX の混在スレッド: fullyJunk == false (バッジの OR は true のまま)")
    func mixedThreadIsNotFullyJunk() throws {
        let (database, accountId, inboxId, _, junkId, _) = try makeNonGmailDatabase()
        let threadId = try makeThread(in: database, accountId: accountId, mailboxIds: [junkId, inboxId])

        let (fully, anyJunk) = try database.dbWriter.read { db in
            (
                try ThreadQuery.isThreadFullyJunk(threadId: threadId, db: db),
                try ThreadQuery.isThreadJunk(threadId: threadId, db: db)
            )
        }
        #expect(fully == false, "INBOX の行はまだ迷惑メールにできる")
        #expect(anyJunk == true)
    }

    @Test("全メッセージが Junk: fullyJunk == true")
    func fullyJunkThread() throws {
        let (database, accountId, _, _, junkId, _) = try makeNonGmailDatabase()
        let threadId = try makeThread(in: database, accountId: accountId, mailboxIds: [junkId, junkId])

        let fully = try database.dbWriter.read { db in
            try ThreadQuery.isThreadFullyJunk(threadId: threadId, db: db)
        }
        #expect(fully == true)
    }

    @Test("メッセージが1通も無いスレッド: fullyJunk == false")
    func emptyThreadIsNotFullyJunk() throws {
        let (database, accountId, _, _, _, _) = try makeNonGmailDatabase()
        let threadId = try makeThread(in: database, accountId: accountId, mailboxIds: [])

        let fully = try database.dbWriter.read { db in
            try ThreadQuery.isThreadFullyJunk(threadId: threadId, db: db)
        }
        #expect(fully == false)
    }

    // MARK: - Gmail (アーカイブの実体は All Mail、INBOX 重複を除いたもの)

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

    @Test("Gmail: アーカイブ済みの親 + INBOX にも重複する新着 → fullyArchived == false")
    func gmailMixedThreadIsNotFullyArchived() throws {
        let (database, accountId, allMailId, inboxId) = try makeGmailDatabase()
        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: Self.base, messageCount: 3)
            try thread.insert(db)
            // 親: All Mail にしか無い = アーカイブ済み。
            var archived = MessageRecord(
                mailboxId: allMailId, uid: 1, date: Self.base, internalDate: Self.base, gmailMessageId: 1, threadId: thread.id
            )
            try archived.insert(db)
            // 新着: INBOX と All Mail の両方に居る = まだアーカイブしていない。
            var freshInbox = MessageRecord(
                mailboxId: inboxId, uid: 2, date: Self.base, internalDate: Self.base, gmailMessageId: 2, threadId: thread.id
            )
            try freshInbox.insert(db)
            var freshAllMail = MessageRecord(
                mailboxId: allMailId, uid: 3, date: Self.base, internalDate: Self.base, gmailMessageId: 2, threadId: thread.id
            )
            try freshAllMail.insert(db)
            return thread.id!
        }

        let (fully, anyArchived) = try database.dbWriter.read { db in
            (
                try ThreadQuery.isThreadFullyArchived(threadId: threadId, db: db),
                try ThreadQuery.isThreadArchived(threadId: threadId, db: db)
            )
        }
        #expect(fully == false, "新着はまだ INBOX ラベルを持つ — スロットは「アーカイブ」であるべき")
        #expect(anyArchived == true)
    }

    @Test("Gmail: 全メッセージが All Mail のみ → fullyArchived == true")
    func gmailFullyArchivedThread() throws {
        let (database, accountId, allMailId, _) = try makeGmailDatabase()
        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: Self.base, messageCount: 2)
            try thread.insert(db)
            for (index, gmailMessageId) in [Int64(1), Int64(2)].enumerated() {
                var message = MessageRecord(
                    mailboxId: allMailId, uid: Int64(index + 1), date: Self.base, internalDate: Self.base,
                    gmailMessageId: gmailMessageId, threadId: thread.id
                )
                try message.insert(db)
            }
            return thread.id!
        }

        let fully = try database.dbWriter.read { db in
            try ThreadQuery.isThreadFullyArchived(threadId: threadId, db: db)
        }
        #expect(fully == true)
    }
}
