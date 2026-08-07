import Foundation
import GRDB
import Testing
@testable import OtegamiStore

/// 実機報告「『すべてのメール』の未読件数が iOS と macOS で違う」の原因が
/// 「その端末がどこまでメールを取り込めているか」の差だったことを受けて
/// 追加した診断用クエリ (`MailboxBackfillProgressQuery`) のテスト。
@Suite("MailboxBackfillProgressQuery aggregates backfill cursors per account")
struct MailboxBackfillProgressQueryTests {
    private func makeAccount(displayName: String, email: String, db: Database) throws -> AccountRecord {
        let account = AccountRecord(
            displayName: displayName, email: email, authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: email
        )
        try account.insert(db)
        return account
    }

    @discardableResult
    private func makeMailbox(
        accountId: String,
        path: String,
        role: MailboxRoleRecord,
        uidNext: Int64,
        backfillLowerBound: Int64,
        isHidden: Bool = false,
        messageCount: Int = 0,
        db: Database
    ) throws -> Int64 {
        var mailbox = MailboxRecord(
            accountId: accountId, path: path, displayPath: path, role: role,
            uidNext: uidNext, isHidden: isHidden, backfillLowerBound: backfillLowerBound
        )
        mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
        let mailboxId = try #require(mailbox.id)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<messageCount {
            var message = MessageRecord(
                mailboxId: mailboxId, uid: Int64(index + 1), subject: "m\(index)",
                internalDate: base.addingTimeInterval(Double(index))
            )
            try message.insert(db)
        }
        return mailboxId
    }

    @Test("backfillLowerBound == 1 のメールボックスだけのアカウントは完了扱い")
    func completedAccountHasNoPendingMailboxes() throws {
        let database = try AppDatabase.makeInMemory()
        let progress = try database.dbWriter.write { db -> [MailboxBackfillProgressQuery.AccountProgress] in
            let account = try makeAccount(displayName: "完了", email: "done@otegami.test", db: db)
            try makeMailbox(accountId: account.id, path: "INBOX", role: .inbox, uidNext: 101, backfillLowerBound: 1, messageCount: 3, db: db)
            try makeMailbox(accountId: account.id, path: "Archive", role: .archive, uidNext: 51, backfillLowerBound: 1, messageCount: 2, db: db)
            return try MailboxBackfillProgressQuery.progress(accountIds: [account.id], db: db)
        }

        #expect(progress.count == 1)
        #expect(progress[0].isComplete)
        #expect(progress[0].mailboxCount == 2)
        #expect(progress[0].syncedMessageCount == 5)
        #expect(progress[0].pendingMailboxes.isEmpty)
    }

    @Test("まだ遡り切れていないメールボックスは残りの多い順に並ぶ")
    func pendingMailboxesSortedByRemainingRange() throws {
        let database = try AppDatabase.makeInMemory()
        let progress = try database.dbWriter.write { db -> [MailboxBackfillProgressQuery.AccountProgress] in
            let account = try makeAccount(displayName: "途中", email: "wip@otegami.test", db: db)
            try makeMailbox(accountId: account.id, path: "INBOX", role: .inbox, uidNext: 1001, backfillLowerBound: 201, messageCount: 4, db: db)
            try makeMailbox(accountId: account.id, path: "All", role: .all, uidNext: 1001, backfillLowerBound: 801, messageCount: 6, db: db)
            try makeMailbox(accountId: account.id, path: "Sent", role: .sent, uidNext: 11, backfillLowerBound: 1, messageCount: 1, db: db)
            return try MailboxBackfillProgressQuery.progress(accountIds: [account.id], db: db)
        }

        let account = try #require(progress.first)
        #expect(!account.isComplete)
        #expect(account.mailboxCount == 3)
        #expect(account.syncedMessageCount == 11)
        // 残り UID が多い (= lowerBound が大きい) 方が先頭。
        #expect(account.pendingMailboxes.map(\.displayPath) == ["All", "INBOX"])
    }

    /// `SyncCoordinator.runBackfill`が非表示メールボックスを対象外にする
    /// のと同じ条件 — 対象外のものを「未完了」として並べると永久に減らない
    /// 残件に見えてしまう。
    @Test("非表示メールボックスは集計から除外される")
    func hiddenMailboxesAreExcluded() throws {
        let database = try AppDatabase.makeInMemory()
        let progress = try database.dbWriter.write { db -> [MailboxBackfillProgressQuery.AccountProgress] in
            let account = try makeAccount(displayName: "非表示あり", email: "hidden@otegami.test", db: db)
            try makeMailbox(accountId: account.id, path: "INBOX", role: .inbox, uidNext: 101, backfillLowerBound: 1, messageCount: 2, db: db)
            try makeMailbox(accountId: account.id, path: "Noisy", role: .none, uidNext: 5001, backfillLowerBound: 4001, isHidden: true, messageCount: 9, db: db)
            return try MailboxBackfillProgressQuery.progress(accountIds: [account.id], db: db)
        }

        let account = try #require(progress.first)
        #expect(account.isComplete)
        #expect(account.mailboxCount == 1)
        #expect(account.syncedMessageCount == 2)
    }

    @Test("scannedFraction は UID 範囲ベースの目安、未同期は nil")
    func scannedFractionSemantics() throws {
        let halfway = MailboxBackfillProgressQuery.MailboxProgress(
            mailboxId: 1, displayPath: "All", role: .all,
            backfillLowerBound: 501, uidNext: 1001, syncedMessageCount: 10
        )
        #expect(halfway.scannedFraction == 0.5)
        #expect(!halfway.isComplete)

        let complete = MailboxBackfillProgressQuery.MailboxProgress(
            mailboxId: 2, displayPath: "INBOX", role: .inbox,
            backfillLowerBound: 1, uidNext: 1001, syncedMessageCount: 10
        )
        #expect(complete.scannedFraction == 1.0)
        #expect(complete.isComplete)

        // 一度も同期していないメールボックス (`uidNext`が初期値 0) は割合を
        // 出せない。
        let neverSynced = MailboxBackfillProgressQuery.MailboxProgress(
            mailboxId: 3, displayPath: "New", role: .none,
            backfillLowerBound: 1, uidNext: 0, syncedMessageCount: 0
        )
        #expect(neverSynced.scannedFraction == nil)
    }

    @Test("アカウント別に分かれ、指定していないアカウントは含まれない")
    func scopesToRequestedAccounts() throws {
        let database = try AppDatabase.makeInMemory()
        let (targetId, progress) = try database.dbWriter.write { db -> (String, [MailboxBackfillProgressQuery.AccountProgress]) in
            let target = try makeAccount(displayName: "対象", email: "target@otegami.test", db: db)
            let other = try makeAccount(displayName: "対象外", email: "other@otegami.test", db: db)
            try makeMailbox(accountId: target.id, path: "INBOX", role: .inbox, uidNext: 101, backfillLowerBound: 51, messageCount: 2, db: db)
            try makeMailbox(accountId: other.id, path: "INBOX", role: .inbox, uidNext: 101, backfillLowerBound: 51, messageCount: 7, db: db)
            return (target.id, try MailboxBackfillProgressQuery.progress(accountIds: [target.id], db: db))
        }

        #expect(progress.count == 1)
        #expect(progress[0].accountId == targetId)
        #expect(progress[0].syncedMessageCount == 2)
    }

    @Test("アカウント指定が空なら空配列")
    func emptyAccountIdsReturnsEmpty() throws {
        let database = try AppDatabase.makeInMemory()
        let progress = try database.dbWriter.read { db in
            try MailboxBackfillProgressQuery.progress(accountIds: [], db: db)
        }
        #expect(progress.isEmpty)
    }
}
