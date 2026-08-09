import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// 実機報告 (2026-08-07)「受信箱のグループの画面で一括で Gmail を
/// アーカイブした後、Gmail に移動して再読み込みするとまだ復活してしまう」
/// の再発防止。`PendingOpTargets` の集計そのものと、それを受け取った
/// `EnvelopePersister.upsert` が「未送信のローカル変更がある UID を
/// サーバー由来のエンベロープで作り直さない」ことを固定する。
@Suite("PendingOpTargets — unsent local changes shield a UID from server state")
struct PendingOpTargetsTests {
    private func makeAccount(db: Database) throws -> AccountRecord {
        let account = AccountRecord(
            displayName: "Test", email: "pending@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "pending@otegami.test"
        )
        try account.insert(db)
        return account
    }

    private func makeMailbox(accountId: String, path: String = "INBOX", role: MailboxRoleRecord = .inbox, uidValidity: Int64 = 42, db: Database) throws -> MailboxRecord {
        var mailbox = MailboxRecord(accountId: accountId, path: path, displayPath: path, role: role, uidValidity: uidValidity)
        try mailbox.insert(db)
        return mailbox
    }

    private func makeEnvelope(uid: UInt32, flags: MessageFlags = []) -> FetchedEnvelope {
        FetchedEnvelope(
            uid: uid,
            messageId: "<msg-\(uid)@otegami.test>",
            inReplyTo: nil,
            references: [],
            subject: "件名 \(uid)",
            from: [EmailAddress(name: "Aiko", address: "aiko@otegami.test")],
            to: [EmailAddress(address: "pending@otegami.test")],
            cc: [],
            bcc: [],
            replyTo: [],
            date: Date(timeIntervalSince1970: 1_700_000_000),
            internalDate: Date(timeIntervalSince1970: 1_700_000_000),
            flags: flags,
            size: 512,
            parts: []
        )
    }

    // MARK: - 集計

    @Test("archive op の対象 UID は relocated に入る")
    func archiveOpMarksUIDRelocated() throws {
        let database = try AppDatabase.makeInMemory()
        let targets = try database.dbWriter.write { db -> PendingOpTargets in
            let account = try makeAccount(db: db)
            let inbox = try makeMailbox(accountId: account.id, db: db)
            try OpQueue.enqueueArchive(
                accountId: account.id, sourceMailboxId: try #require(inbox.id), uidValidity: 42,
                uids: [7, 9], db: db
            )
            return try PendingOpTargets.forMailbox(mailboxId: try #require(inbox.id), accountId: account.id, db: db)
        }
        #expect(targets.relocated == [7, 9])
        #expect(targets.flagChanged.isEmpty)
        #expect(targets.blocks(uid: 7))
        #expect(!targets.blocks(uid: 8))
    }

    @Test("setFlags op の対象 UID は flagChanged に入る")
    func setFlagsOpMarksUIDFlagChanged() throws {
        let database = try AppDatabase.makeInMemory()
        let targets = try database.dbWriter.write { db -> PendingOpTargets in
            let account = try makeAccount(db: db)
            let inbox = try makeMailbox(accountId: account.id, db: db)
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: try #require(inbox.id), uidValidity: 42,
                uids: [3], flags: .seen, db: db
            )
            return try PendingOpTargets.forMailbox(mailboxId: try #require(inbox.id), accountId: account.id, db: db)
        }
        #expect(targets.flagChanged == [3])
        #expect(targets.blocks(uid: 3))
    }

    /// `uidValidity` が変わった op は replay 時に stale として破棄される —
    /// ガードし続けるとサーバー状態の取り込みを無駄に止めるだけになる。
    @Test("uidValidity が一致しない op はガードしない")
    func staleUIDValidityIsIgnored() throws {
        let database = try AppDatabase.makeInMemory()
        let targets = try database.dbWriter.write { db -> PendingOpTargets in
            let account = try makeAccount(db: db)
            let inbox = try makeMailbox(accountId: account.id, uidValidity: 42, db: db)
            try OpQueue.enqueueArchive(
                accountId: account.id, sourceMailboxId: try #require(inbox.id), uidValidity: 41,
                uids: [7], db: db
            )
            return try PendingOpTargets.forMailbox(mailboxId: try #require(inbox.id), accountId: account.id, db: db)
        }
        #expect(targets.isEmpty)
    }

    @Test("別のメールボックスを対象にした op はガードしない")
    func otherMailboxOpIsIgnored() throws {
        let database = try AppDatabase.makeInMemory()
        let targets = try database.dbWriter.write { db -> PendingOpTargets in
            let account = try makeAccount(db: db)
            let inbox = try makeMailbox(accountId: account.id, db: db)
            let archive = try makeMailbox(accountId: account.id, path: "Archive", role: .archive, db: db)
            try OpQueue.enqueueArchive(
                accountId: account.id, sourceMailboxId: try #require(archive.id), uidValidity: 42,
                uids: [7], db: db
            )
            return try PendingOpTargets.forMailbox(mailboxId: try #require(inbox.id), accountId: account.id, db: db)
        }
        #expect(targets.isEmpty)
    }

    /// 送信・下書き保存は既存の `(mailboxId, uid)` を対象にしていない。
    @Test("send op は何もガードしない")
    func sendOpGuardsNothing() throws {
        let database = try AppDatabase.makeInMemory()
        let targets = try database.dbWriter.write { db -> PendingOpTargets in
            let account = try makeAccount(db: db)
            let inbox = try makeMailbox(accountId: account.id, db: db)
            var outbox = OutboxMessageRecord(
                accountId: account.id,
                toAddresses: [EmailAddress(address: "recipient@example.com")],
                subject: "送信",
                plainTextBody: "body"
            )
            try outbox.insert(db)
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: try #require(outbox.id), db: db)
            return try PendingOpTargets.forMailbox(mailboxId: try #require(inbox.id), accountId: account.id, db: db)
        }
        #expect(targets.isEmpty)
    }

    // MARK: - Gmail の兄弟行 (2026-08-07 の2度目の unpin 修正)

    /// INBOX と All Mail に同じ物理メッセージの2行を作る。戻り値は
    /// (accountId, inboxId, allMailId)。
    private func makeGmailDuplicate(db: Database) throws -> (accountId: String, inboxId: Int64, allMailId: Int64) {
        let account = AccountRecord(
            displayName: "Gmail", email: "dup@otegami.test", authType: .password, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapUsername: "dup@otegami.test"
        )
        try account.insert(db)
        var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 42)
        try inbox.insert(db)
        var allMail = MailboxRecord(accountId: account.id, path: "[Gmail]/All Mail", displayPath: "All Mail", role: .all, uidValidity: 42)
        try allMail.insert(db)
        var thread = ThreadRecord(accountId: account.id, normalizedSubject: "重複")
        try thread.insert(db)
        let threadId = try #require(thread.id)
        for (mailboxId, uid) in [(try #require(inbox.id), Int64(10)), (try #require(allMail.id), Int64(20))] {
            var message = MessageRecord(
                mailboxId: mailboxId, uid: uid,
                messageId: "<dup@otegami.test>",
                internalDate: Date(timeIntervalSince1970: 1_700_000_000),
                gmailMessageId: 4242,
                threadId: threadId
            )
            try message.insert(db)
        }
        return (account.id, try #require(inbox.id), try #require(allMail.id))
    }

    /// これが無かったために、INBOX で unpin した直後の All Mail 同期が
    /// サーバーの `\Flagged` で兄弟行を戻し、ピンが復活していた。
    @Test("INBOX 対象の setFlags op は All Mail 側の兄弟 UID もガードする")
    func setFlagsOpGuardsSiblingUID() throws {
        let database = try AppDatabase.makeInMemory()
        let targets = try database.dbWriter.write { db -> PendingOpTargets in
            let (accountId, inboxId, allMailId) = try makeGmailDuplicate(db: db)
            try OpQueue.enqueueSetFlags(
                accountId: accountId, mailboxId: inboxId, uidValidity: 42, uids: [10], flags: .seen, db: db
            )
            return try PendingOpTargets.forMailbox(mailboxId: allMailId, accountId: accountId, db: db)
        }
        #expect(targets.flagChanged == [20])
        #expect(targets.blocks(uid: 20))
    }

    @Test("逆方向 (All Mail 対象の op が INBOX 側をガードする) も成り立つ")
    func setFlagsOpGuardsSiblingUIDInBothDirections() throws {
        let database = try AppDatabase.makeInMemory()
        let targets = try database.dbWriter.write { db -> PendingOpTargets in
            let (accountId, inboxId, allMailId) = try makeGmailDuplicate(db: db)
            try OpQueue.enqueueSetFlags(
                accountId: accountId, mailboxId: allMailId, uidValidity: 42, uids: [20], flags: .seen, db: db
            )
            return try PendingOpTargets.forMailbox(mailboxId: inboxId, accountId: accountId, db: db)
        }
        #expect(targets.flagChanged == [10])
    }

    /// **意図的な非対称の固定** — 移動系は所属 (ラベル) の話なので広げない。
    /// Gmail のアーカイブは INBOX ラベルを外すだけで、All Mail 側の行は
    /// 残るのが正しい。ここまで広げると正しい行を消してしまう。
    @Test("archive op は兄弟行までは広げない")
    func relocationOpsDoNotSpreadToSiblings() throws {
        let database = try AppDatabase.makeInMemory()
        let targets = try database.dbWriter.write { db -> PendingOpTargets in
            let (accountId, inboxId, allMailId) = try makeGmailDuplicate(db: db)
            try OpQueue.enqueueArchive(
                accountId: accountId, sourceMailboxId: inboxId, uidValidity: 42, uids: [10], db: db
            )
            return try PendingOpTargets.forMailbox(mailboxId: allMailId, accountId: accountId, db: db)
        }
        #expect(targets.isEmpty)
    }

    /// 別メールボックスを対象にした op の `uidValidity` は、**その
    /// メールボックス自身の値**と突き合わせる (引数のメールボックスの値と
    /// 比べても意味が無い)。
    @Test("別メールボックスの op はそのメールボックス自身の uidValidity で判定する")
    func foreignOpUsesItsOwnMailboxUIDValidity() throws {
        let database = try AppDatabase.makeInMemory()
        let targets = try database.dbWriter.write { db -> PendingOpTargets in
            let (accountId, inboxId, allMailId) = try makeGmailDuplicate(db: db)
            // INBOX の現在の uidValidity は 42。41 の op は stale。
            try OpQueue.enqueueSetFlags(
                accountId: accountId, mailboxId: inboxId, uidValidity: 41, uids: [10], flags: .seen, db: db
            )
            return try PendingOpTargets.forMailbox(mailboxId: allMailId, accountId: accountId, db: db)
        }
        #expect(targets.isEmpty)
    }

    @Test("重複行が無ければ別メールボックスの op は何もガードしない")
    func foreignOpWithoutSiblingGuardsNothing() throws {
        let database = try AppDatabase.makeInMemory()
        let targets = try database.dbWriter.write { db -> PendingOpTargets in
            let account = try makeAccount(db: db)
            let inbox = try makeMailbox(accountId: account.id, db: db)
            let archive = try makeMailbox(accountId: account.id, path: "Archive", role: .archive, db: db)
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: try #require(inbox.id), uidValidity: 42,
                uids: [3], flags: .seen, db: db
            )
            return try PendingOpTargets.forMailbox(mailboxId: try #require(archive.id), accountId: account.id, db: db)
        }
        #expect(targets.isEmpty)
    }

    // MARK: - upsert 側のガード (復活そのもの)

    /// 実機報告そのままの筋道: アーカイブでローカル行が消える → まだ
    /// replay されていない → サーバーはまだそのメールを返す → 取り込むと
    /// 受信トレイに復活していた。
    @Test("アーカイブ済み (未送信) の UID はサーバーのエンベロープで復活しない")
    func archivedUIDIsNotResurrectedBySync() async throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try await database.dbWriter.write { db -> (String, Int64) in
            let account = try makeAccount(db: db)
            let inbox = try makeMailbox(accountId: account.id, db: db)
            return (account.id, try #require(inbox.id))
        }

        // 1. 通常の同期でメールが1通入っている状態。
        try await database.dbWriter.write { db in
            try EnvelopePersister.upsert(envelope: makeEnvelope(uid: 5), mailboxId: mailboxId, accountId: accountId, db: db)
        }
        let insertedCount = try await database.dbWriter.read { db in try MessageRecord.fetchCount(db) }
        #expect(insertedCount == 1)

        // 2. アーカイブ: op を積んでローカル行を消す (Gmail の形 — 仮配置
        //    先が無いので `MessageRemoval` は行そのものを削除する)。
        try await database.dbWriter.write { db in
            try OpQueue.enqueueArchive(accountId: accountId, sourceMailboxId: mailboxId, uidValidity: 42, uids: [5], db: db)
            try MessageRecord.filter(Column("mailboxId") == mailboxId).filter(Column("uid") == 5).deleteAll(db)
        }

        // 3. 次の同期: サーバーはまだ UID 5 を返す。
        try await database.dbWriter.write { db in
            let pendingTargets = try PendingOpTargets.forMailbox(mailboxId: mailboxId, accountId: accountId, db: db)
            try EnvelopePersister.upsert(envelope: makeEnvelope(uid: 5), mailboxId: mailboxId, accountId: accountId, pendingTargets: pendingTargets, db: db)
        }
        let afterSync = try await database.dbWriter.read { db in try MessageRecord.fetchCount(db) }
        #expect(afterSync == 0, "未送信のアーカイブ op がある間は復活してはいけない")
    }

    /// op が replay されて `opQueue` から消えれば、ガードも自然に外れる。
    @Test("op が無くなればサーバーのエンベロープを通常どおり取り込む")
    func guardLiftsOnceOpIsGone() async throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try await database.dbWriter.write { db -> (String, Int64) in
            let account = try makeAccount(db: db)
            let inbox = try makeMailbox(accountId: account.id, db: db)
            try OpQueue.enqueueArchive(accountId: account.id, sourceMailboxId: try #require(inbox.id), uidValidity: 42, uids: [5], db: db)
            return (account.id, try #require(inbox.id))
        }

        // replay 相当 (あるいは診断画面の「未送信の操作を破棄」) で op が消える。
        try await database.dbWriter.write { db in
            _ = try OpQueue.discardAll(accountId: accountId, db: db)
        }

        try await database.dbWriter.write { db in
            let pendingTargets = try PendingOpTargets.forMailbox(mailboxId: mailboxId, accountId: accountId, db: db)
            try EnvelopePersister.upsert(envelope: makeEnvelope(uid: 5), mailboxId: mailboxId, accountId: accountId, pendingTargets: pendingTargets, db: db)
        }
        let count = try await database.dbWriter.read { db in try MessageRecord.fetchCount(db) }
        #expect(count == 1)
    }

    /// 既読が未読へ巻き戻る側。`setFlags` op が未送信のうちは、サーバーの
    /// 古い `\Seen` をローカルへ書き戻してはいけない。
    @Test("既読化が未送信の UID はサーバーの古いフラグで上書きされない")
    func pendingSeenIsNotOverwrittenByServerFlags() async throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try await database.dbWriter.write { db -> (String, Int64) in
            let account = try makeAccount(db: db)
            let inbox = try makeMailbox(accountId: account.id, db: db)
            return (account.id, try #require(inbox.id))
        }

        // ローカルで既読にした (フラグはローカルで立ち、op は未送信)。
        try await database.dbWriter.write { db in
            try EnvelopePersister.upsert(envelope: makeEnvelope(uid: 5, flags: .seen), mailboxId: mailboxId, accountId: accountId, db: db)
            try OpQueue.enqueueSetFlags(accountId: accountId, mailboxId: mailboxId, uidValidity: 42, uids: [5], flags: .seen, db: db)
        }

        // サーバーはまだ未読のまま返す。
        try await database.dbWriter.write { db in
            let pendingTargets = try PendingOpTargets.forMailbox(mailboxId: mailboxId, accountId: accountId, db: db)
            try EnvelopePersister.upsert(envelope: makeEnvelope(uid: 5, flags: []), mailboxId: mailboxId, accountId: accountId, pendingTargets: pendingTargets, db: db)
        }
        let flagsRaw = try await database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT flagsRaw FROM message WHERE mailboxId = ? AND uid = 5", arguments: [mailboxId])
        }
        #expect(flagsRaw == MessageFlags.seen.rawValue, "未送信の既読化がサーバーの古いフラグで巻き戻ってはいけない")
    }

    @Test("ガード対象でない UID は通常どおり取り込まれる")
    func unrelatedUIDIsUnaffected() async throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try await database.dbWriter.write { db -> (String, Int64) in
            let account = try makeAccount(db: db)
            let inbox = try makeMailbox(accountId: account.id, db: db)
            try OpQueue.enqueueArchive(accountId: account.id, sourceMailboxId: try #require(inbox.id), uidValidity: 42, uids: [5], db: db)
            return (account.id, try #require(inbox.id))
        }

        try await database.dbWriter.write { db in
            let pendingTargets = try PendingOpTargets.forMailbox(mailboxId: mailboxId, accountId: accountId, db: db)
            for uid in [5, 6] as [UInt32] {
                try EnvelopePersister.upsert(envelope: makeEnvelope(uid: uid), mailboxId: mailboxId, accountId: accountId, pendingTargets: pendingTargets, db: db)
            }
        }
        let uids = try await database.dbWriter.read { db in
            try Int64.fetchAll(db, sql: "SELECT uid FROM message WHERE mailboxId = ? ORDER BY uid", arguments: [mailboxId])
        }
        #expect(uids == [6])
    }

    // MARK: targetMailboxIds

    /// `targetMailboxIds` は `forMailbox` の裏返し — 「この op はどの
    /// メールボックスにガードを掛けるか」。両者の定義が食い違うと
    /// `OpQueueProcessor` が op を消したときにゲートを外し損ねる (あるいは
    /// 無関係なメールボックスの `lastUnseenSweepAt` を消す) ので、
    /// 全 op 種別について対応を固定しておく。
    @Test("targetMailboxIds が各 op 種別のガード対象メールボックスを返す")
    func targetMailboxIdsCoversEveryKind() async throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, source, destination) = try await database.dbWriter.write { db -> (String, Int64, Int64) in
            let account = try makeAccount(db: db)
            let inbox = try makeMailbox(accountId: account.id, db: db)
            var other = MailboxRecord(
                accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive, uidValidity: 42
            )
            try other.insert(db)
            return (account.id, try #require(inbox.id), try #require(other.id))
        }

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSetFlags(accountId: accountId, mailboxId: source, uidValidity: 42, uids: [1], flags: .seen, db: db)
            try OpQueue.enqueueMove(accountId: accountId, sourceMailboxId: source, uidValidity: 42, uids: [2], destinationMailboxId: destination, db: db)
            try OpQueue.enqueueDelete(accountId: accountId, sourceMailboxId: source, uidValidity: 42, uids: [3], db: db)
            try OpQueue.enqueueJunk(accountId: accountId, sourceMailboxId: source, uidValidity: 42, uids: [4], db: db)
            try OpQueue.enqueueArchive(accountId: accountId, sourceMailboxId: source, uidValidity: 42, uids: [5], db: db)
            try OpQueue.enqueueUnarchive(accountId: accountId, sourceMailboxId: source, uidValidity: 42, uids: [6], db: db)
        }

        let ops = try await database.dbWriter.read { db in try OpQueueRecord.order(Column("id")).fetchAll(db) }
        #expect(ops.count == 6)
        for op in ops {
            #expect(
                PendingOpTargets.targetMailboxIds(of: op) == [source],
                "\(op.kind) は移動元/自メールボックスにガードを掛ける"
            )
        }
    }

    @Test("送信・下書き保存はガード対象を持たない")
    func targetMailboxIdsIsEmptyForOpsWithoutExistingUIDs() async throws {
        let database = try AppDatabase.makeInMemory()
        let accountId = try await database.dbWriter.write { db -> String in
            let account = try makeAccount(db: db)
            _ = try makeMailbox(accountId: account.id, db: db)
            return account.id
        }
        try await database.dbWriter.write { db in
            try OpQueue.enqueueSend(accountId: accountId, outboxMessageId: 1, db: db)
        }

        let ops = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        for op in ops {
            #expect(PendingOpTargets.targetMailboxIds(of: op).isEmpty)
        }
    }
}
