import Foundation
import GRDB
import Testing
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// 実機報告 (2026-08-07)「メールの unpin が反映されない」の再発防止。
///
/// Gmail の二重ラベルでは同じメールが INBOX と All Mail の2行として同期
/// される。`ThreadQuery.actionTargets(for:db:)` は dedup 済みの代表行しか
/// 返さないのに、`ThreadRecord.isPinned` の集約は dedup 前の全行の OR
/// なので、代表行だけ解除しても All Mail 側の行が `isPinnedLocal == true`
/// のまま残り、スレッドのピンが落ちなかった — ピン留めは OR なので代表行
/// だけで効いてしまうため、「付けられるのに外せない」という非対称に
/// 見えていた。
@Suite("MessagePinReadState — Gmail の重複行もローカル状態を揃える")
struct MessagePinReadStateDuplicateTests {
    /// INBOX と All Mail に同じ `gmailMessageId` で2行、両方ピン留め済みの
    /// スレッドを作る。戻り値は (accountId, threadId, dedup 済み代表行)。
    private func makePinnedGmailDuplicate(db: Database, pinned: Bool = true, seen: Bool = false) throws -> (accountId: String, threadId: Int64, targets: [MessageRecord]) {
        let account = AccountRecord(
            displayName: "Gmail", email: "dup@otegami.test", authType: .password, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapUsername: "dup@otegami.test"
        )
        try account.insert(db)
        var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1)
        try inbox.insert(db)
        var allMail = MailboxRecord(accountId: account.id, path: "[Gmail]/All Mail", displayPath: "All Mail", role: .all, uidValidity: 1)
        try allMail.insert(db)

        var thread = ThreadRecord(accountId: account.id, normalizedSubject: "重複スレッド")
        try thread.insert(db)
        let threadId = try #require(thread.id)

        var flags: MessageFlags = []
        if pinned { flags.insert(.flagged) }
        if seen { flags.insert(.seen) }

        for (mailboxId, uid) in [(try #require(inbox.id), Int64(10)), (try #require(allMail.id), Int64(20))] {
            var message = MessageRecord(
                mailboxId: mailboxId, uid: uid,
                messageId: "<dup@otegami.test>",
                subject: "重複スレッド", normalizedSubject: "重複スレッド",
                internalDate: Date(timeIntervalSince1970: 1_700_000_000),
                flagsRaw: flags.rawValue,
                gmailMessageId: 4242,
                threadId: threadId,
                isPinnedLocal: pinned
            )
            try message.insert(db)
        }
        try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)

        let storedThread = try #require(try ThreadRecord.fetchOne(db, key: threadId))
        let summaries = try ThreadQuery.summaries(forThreads: [storedThread], db: db)
        let summary = try #require(summaries.first)
        let targets = try ThreadQuery.actionTargets(for: summary, db: db)
        // 前提の確認: 呼び出し側に渡るのは dedup 済みの1行だけ (これが
        // このバグの出発点)。
        #expect(targets.count == 1)
        return (account.id, threadId, targets)
    }

    @Test("unpin が重複行にも及び、スレッドの isPinned が落ちる")
    func unpinClearsDuplicateSiblingSoThreadAggregateFollows() throws {
        let database = try AppDatabase.makeInMemory()
        let isPinned = try database.dbWriter.write { db -> Bool in
            let (accountId, threadId, targets) = try makePinnedGmailDuplicate(db: db)
            let before = try #require(try ThreadRecord.fetchOne(db, key: threadId))
            #expect(before.isPinned)

            try MessagePinReadState.applyPinState(
                pinning: false, messages: targets, threadId: threadId, accountId: accountId, db: db
            )
            let after = try #require(try ThreadRecord.fetchOne(db, key: threadId))
            return after.isPinned
        }
        #expect(!isPinned, "代表行だけ解除しても、重複行が残っていると OR 集約でピンが落ちない")
    }

    @Test("unpin 後はどちらの行も isPinnedLocal が false")
    func unpinClearsEveryRow() throws {
        let database = try AppDatabase.makeInMemory()
        let pinnedFlags = try database.dbWriter.write { db -> [Bool] in
            let (accountId, threadId, targets) = try makePinnedGmailDuplicate(db: db)
            try MessagePinReadState.applyPinState(
                pinning: false, messages: targets, threadId: threadId, accountId: accountId, db: db
            )
            return try MessageRecord.filter(Column("threadId") == threadId).order(Column("uid")).fetchAll(db).map(\.isPinnedLocal)
        }
        #expect(pinnedFlags == [false, false])
    }

    /// サーバーへ送る op は代表行のぶんだけでよい — Gmail のフラグは
    /// ラベルではなくメッセージに付くため。二重に積むと未送信 op が
    /// 無駄に増える。
    @Test("重複行のぶんの setFlags op は積まない")
    func siblingUpdateDoesNotEnqueueExtraOps() throws {
        let database = try AppDatabase.makeInMemory()
        let opCount = try database.dbWriter.write { db -> Int in
            let (accountId, threadId, targets) = try makePinnedGmailDuplicate(db: db)
            try MessagePinReadState.applyPinState(
                pinning: false, messages: targets, threadId: threadId, accountId: accountId, db: db
            )
            return try OpQueueRecord.fetchCount(db)
        }
        #expect(opCount == 1)
    }

    @Test("ピン留め側も両方の行に及ぶ")
    func pinAlsoAppliesToEveryRow() throws {
        let database = try AppDatabase.makeInMemory()
        let pinnedFlags = try database.dbWriter.write { db -> [Bool] in
            let (accountId, threadId, targets) = try makePinnedGmailDuplicate(db: db, pinned: false)
            try MessagePinReadState.applyPinState(
                pinning: true, messages: targets, threadId: threadId, accountId: accountId, db: db
            )
            return try MessageRecord.filter(Column("threadId") == threadId).order(Column("uid")).fetchAll(db).map(\.isPinnedLocal)
        }
        #expect(pinnedFlags == [true, true])
    }

    @Test("既読化も重複行に及ぶ")
    func markingReadAppliesToEveryRow() throws {
        let database = try AppDatabase.makeInMemory()
        let seenFlags = try database.dbWriter.write { db -> [Bool] in
            let (accountId, threadId, targets) = try makePinnedGmailDuplicate(db: db, pinned: false, seen: false)
            try MessagePinReadState.applyReadState(
                markingRead: true, messages: targets, threadId: threadId, accountId: accountId, db: db
            )
            return try MessageRecord.filter(Column("threadId") == threadId).order(Column("uid")).fetchAll(db)
                .map { $0.flags.contains(.seen) }
        }
        #expect(seenFlags == [true, true])
    }

    /// 重複が無い (非 Gmail の) 普通のスレッドでは何も変わらないこと。
    @Test("重複が無いスレッドでは従来どおり1行だけ更新する")
    func nonDuplicateThreadIsUnaffected() throws {
        let database = try AppDatabase.makeInMemory()
        let (pinnedFlags, opCount) = try database.dbWriter.write { db -> ([Bool], Int) in
            let account = AccountRecord(
                displayName: "IMAP", email: "plain@otegami.test", authType: .password,
                imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "plain@otegami.test"
            )
            try account.insert(db)
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1)
            try inbox.insert(db)
            var thread = ThreadRecord(accountId: account.id, normalizedSubject: "単独")
            try thread.insert(db)
            let threadId = try #require(thread.id)
            var message = MessageRecord(
                mailboxId: try #require(inbox.id), uid: 1,
                messageId: "<plain@otegami.test>",
                subject: "単独", normalizedSubject: "単独",
                internalDate: Date(timeIntervalSince1970: 1_700_000_000),
                flagsRaw: MessageFlags.flagged.rawValue,
                threadId: threadId,
                isPinnedLocal: true
            )
            try message.insert(db)
            try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)

            let targets = try ThreadQuery.messages(threadId: threadId, db: db)
            try MessagePinReadState.applyPinState(
                pinning: false, messages: targets, threadId: threadId, accountId: account.id, db: db
            )
            let flags = try MessageRecord.filter(Column("threadId") == threadId).fetchAll(db).map(\.isPinnedLocal)
            return (flags, try OpQueueRecord.fetchCount(db))
        }
        #expect(pinnedFlags == [false])
        #expect(opCount == 1)
    }
}
