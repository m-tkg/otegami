import Foundation
import GRDB
import Testing
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// 実機報告 (2026-08-27)「スレッドの親がアーカイブ済みの場合、新しく来た
/// メールのアーカイブができない」の DB 側の裏取り。
///
/// スロット判定を AND 集約に移した (`ThreadQuery.isThreadFullyArchived`、
/// `ThreadFullyArchivedTests`) 対になるテストで、こちらは
/// 「そのスロットが選ぶ `MessageRemoval.Kind` を混在スレッドに commit すると
/// 実際に何が動くか」を固定する:
///
/// - `.archive` — まだアーカイブされていない行だけを移送し、既にアーカイブ
///   場所にいる行は `isAlreadyArchived` ガードが素通りさせる。つまり報告の
///   「新着をアーカイブする」は成立する。
/// - `.unarchive` — その逆で、アーカイブ場所にいる行しか戻さない。修正前の
///   スロットはこちらを選んでいたので、新着は一切触られずユーザーには
///   無反応に見えていた。
@Suite("MessageRemoval (一部だけアーカイブ済みのスレッド)")
struct MessageRemovalMixedThreadTests {
    private func makeDatabase() throws -> (
        database: AppDatabase, accountId: String, inboxId: Int64, archiveId: Int64
    ) {
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
        return (database, account.id, inboxId, archiveId)
    }

    /// 報告そのままの形: 先にアーカイブした親が Archive に、あとから届いた
    /// 返信が INBOX にある1スレッド。
    private func insertMixedThread(
        accountId: String, inboxId: Int64, archiveId: Int64, db: Database
    ) throws -> (threadId: Int64, archivedId: Int64, freshId: Int64) {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 2)
        try thread.insert(db)
        var archived = MessageRecord(
            mailboxId: archiveId, uid: 11, date: base.addingTimeInterval(-100),
            internalDate: base.addingTimeInterval(-100), threadId: thread.id
        )
        try archived.insert(db)
        var fresh = MessageRecord(
            mailboxId: inboxId, uid: 22, date: base, internalDate: base, threadId: thread.id
        )
        try fresh.insert(db)
        return (thread.id!, archived.id!, fresh.id!)
    }

    private func groupedSummary(threadId: Int64, db: Database) throws -> ThreadSummary {
        ThreadSummary(thread: try ThreadRecord.fetchOne(db, key: threadId)!, latestMessage: nil)
    }

    @Test("`.archive` は INBOX の新着だけを移送し、既にアーカイブ済みの親は触らない")
    func archiveMovesOnlyTheFreshMessage() throws {
        let (database, accountId, inboxId, archiveId) = try makeDatabase()
        let ids = try database.dbWriter.write { db in
            try insertMixedThread(accountId: accountId, inboxId: inboxId, archiveId: archiveId, db: db)
        }

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.archive, summary: try groupedSummary(threadId: ids.threadId, db: db), accountId: accountId, db: db)
        }
        let committed = try #require(snapshot, "新着がアーカイブ対象になるので nil にはならない")
        #expect(committed.messages.map(\.id) == [ids.freshId], "動いたのは INBOX にいた新着だけ")

        let (archivedRow, freshRow, ops) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: ids.archivedId),
                try MessageRecord.fetchOne(db, key: ids.freshId),
                try OpQueueRecord.fetchAll(db)
            )
        }
        let untouched = try #require(archivedRow)
        #expect(untouched.mailboxId == archiveId, "既にアーカイブ場所にいる親は据え置き")
        #expect(untouched.uid == 11, "親の UID も書き換えない (移送されていない)")

        let relocated = try #require(freshRow, "新着は削除ではなく Archive へ移送される")
        #expect(relocated.mailboxId == archiveId)
        #expect(relocated.isPendingRelocation, "本物の UID は次の同期が採番するまで仮の値")

        #expect(ops.count == 1, "サーバー op は新着の1件だけ — 親には何も積まない")
        #expect(ops.first?.kind == OpQueueKind.archive.rawValue)
    }

    @Test("`.archive` のあとスレッドは fullyArchived になる")
    func threadBecomesFullyArchivedAfterArchive() throws {
        let (database, accountId, inboxId, archiveId) = try makeDatabase()
        let ids = try database.dbWriter.write { db in
            try insertMixedThread(accountId: accountId, inboxId: inboxId, archiveId: archiveId, db: db)
        }
        try database.dbWriter.write { db in
            _ = try MessageRemoval.commit(.archive, summary: try groupedSummary(threadId: ids.threadId, db: db), accountId: accountId, db: db)
        }

        let fully = try database.dbWriter.read { db in
            try ThreadQuery.isThreadFullyArchived(threadId: ids.threadId, db: db)
        }
        #expect(fully == true, "ここで初めてスロットが「アーカイブ解除」に切り替わる")
    }

    /// 修正前のスロットが選んでいた `Kind`。新着が素通りすること自体は
    /// `MessageRemoval` の設計どおりで、問題はこれをスロットが選んでいた
    /// ことの方 — その根拠として挙動を固定しておく。
    @Test("`.unarchive` はアーカイブ済みの親だけを戻し、INBOX の新着は素通りする")
    func unarchiveLeavesTheFreshMessageAlone() throws {
        let (database, accountId, inboxId, archiveId) = try makeDatabase()
        let ids = try database.dbWriter.write { db in
            try insertMixedThread(accountId: accountId, inboxId: inboxId, archiveId: archiveId, db: db)
        }

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.unarchive, summary: try groupedSummary(threadId: ids.threadId, db: db), accountId: accountId, db: db)
        }
        let committed = try #require(snapshot)
        #expect(committed.messages.map(\.id) == [ids.archivedId], "戻ったのは親だけ")

        let (archivedRow, freshRow) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: ids.archivedId),
                try MessageRecord.fetchOne(db, key: ids.freshId)
            )
        }
        #expect(try #require(archivedRow).mailboxId == inboxId, "親は受信トレイへ")
        let fresh = try #require(freshRow)
        #expect(fresh.mailboxId == inboxId, "新着は動かない — ユーザーから見ると「アーカイブできない」")
        #expect(fresh.uid == 22, "新着の行はまったく書き換えられない")
    }
}
