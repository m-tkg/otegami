import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// 実機報告 (2026-08-07)「メールの unpin が反映されない」の**本丸**の回帰
/// テスト。1度目の修正 (`ThreadQuery.duplicateSiblings`) はローカル DB の
/// 整合だけを直したが、**この層のテストが無かったせいで実機では直らなかった**。
///
/// 壊れていた筋道:
/// 1. INBOX の行で unpin → INBOX 対象の `setFlags` op が積まれ、代表行と
///    All Mail 側の兄弟行が両方ローカルで `false` になる
/// 2. All Mail メールボックスの同期が走る。サーバーの `\Flagged` はまだ
///    `true` (op が未送信、あるいは送信直後で反映前)
/// 3. `PendingOpTargets.forMailbox(All Mail)` は、op の payload が INBOX の
///    `mailboxId` を指しているので **All Mail の UID を1つもブロックしない**
/// 4. `MailboxSyncer.applyFlagsOnly` / `EnvelopePersister.upsert` が
///    All Mail 行を `isPinnedLocal = true` に戻す
/// 5. `ThreadRecord.isPinned` が `true` に戻り、UI にピンが残り続ける
///
/// `MailboxSyncerTests` と同じ「2つの `AccountSyncer` を同じ in-memory DB に
/// 向け、それぞれ別の `FakeIMAPSession.Script` (= その時点のサーバー) で
/// 動かす」形。
@Suite("MailboxSyncer — Gmail の二重ラベル行とピン")
struct MailboxSyncerGmailPinTests {
    private let auth = MailAuth.password(username: "gmail@otegami.test", password: "test1234")
    private let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
    private let allMail = MailboxInfo(path: "[Gmail]/All Mail", displayPath: "All Mail", role: .all, attributes: [])

    private func makeGmailAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Gmail", email: "gmail@otegami.test", authType: .password, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapUsername: "gmail@otegami.test"
        )
    }

    /// 同じ物理メッセージの INBOX 側/All Mail 側それぞれの見え方 — 同じ
    /// `gmailMessageId`/`gmailThreadId` で UID だけが違う (Gmail の IMAP
    /// モデルそのまま)。
    private func makeEnvelope(uid: UInt32, flags: MessageFlags) -> FetchedEnvelope {
        FetchedEnvelope(
            uid: uid,
            messageId: "<pinned@otegami.test>",
            inReplyTo: nil,
            references: [],
            subject: "ピン留めしたメール",
            from: [EmailAddress(name: "Aiko", address: "aiko@otegami.test")],
            to: [EmailAddress(address: "gmail@otegami.test")],
            cc: [], bcc: [], replyTo: [],
            date: Date(timeIntervalSince1970: 1_700_000_000),
            internalDate: Date(timeIntervalSince1970: 1_700_000_000),
            flags: flags,
            size: 512,
            gmailThreadId: 999,
            gmailMessageId: 4242
        )
    }

    private func script(flags: MessageFlags, capabilities: Set<IMAPCapability> = []) -> FakeIMAPSession.Script {
        FakeIMAPSession.Script(
            mailboxes: [inbox, allMail],
            envelopesByPath: [
                "INBOX": [makeEnvelope(uid: 10, flags: flags)],
                "[Gmail]/All Mail": [makeEnvelope(uid: 20, flags: flags)],
            ],
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: 11, highestModSeq: 0, messageCount: 1),
                "[Gmail]/All Mail": MailboxStatus(uidValidity: 1, uidNext: 21, highestModSeq: 0, messageCount: 1),
            ],
            capabilitiesToReport: capabilities
        )
    }

    /// 初回同期でピン留め済みの2行を作り、ユーザー操作と同じ経路
    /// (`ThreadQuery.actionTargets` → `MessagePinReadState.applyPinState`)
    /// で unpin したところまで進める。
    private func seedAndUnpin(database: AppDatabase) async throws -> AccountRecord {
        let account = makeGmailAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let seedScript = script(flags: [.flagged])
        let seeder = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: seedScript)
        }
        _ = try await seeder.performInitialSync(auth: auth)

        try await database.dbWriter.write { db in
            let threads = try ThreadRecord.fetchAll(db)
            #expect(threads.count == 1, "同じ gmailThreadId の2行は1スレッドに入る")
            let thread = try #require(threads.first)
            let threadId = try #require(thread.id)
            #expect(thread.isPinned, "初期状態はピン留め済み")
            #expect(try MessageRecord.fetchCount(db) == 2, "INBOX と All Mail の2行が同期されている")

            let summaries = try ThreadQuery.summaries(forThreads: [thread], db: db)
            let targets = try ThreadQuery.actionTargets(for: try #require(summaries.first), db: db)
            try MessagePinReadState.applyPinState(
                pinning: false, messages: targets, threadId: threadId, accountId: account.id, db: db
            )
        }

        let afterUnpin = try await database.dbWriter.read { db in
            (
                pinned: try MessageRecord.fetchAll(db).map(\.isPinnedLocal),
                threadPinned: try #require(try ThreadRecord.fetchOne(db)).isPinned,
                opCount: try OpQueueRecord.fetchCount(db)
            )
        }
        #expect(afterUnpin.pinned == [false, false])
        #expect(!afterUnpin.threadPinned)
        #expect(afterUnpin.opCount == 1, "サーバーへ送る op は代表行のぶんだけ")
        return account
    }

    private func runIncrementalSync(
        account: AccountRecord,
        database: AppDatabase,
        capabilities: Set<IMAPCapability> = []
    ) async throws {
        // サーバーはまだ両方の UID を `\Flagged` として報告する
        // (op が未送信、あるいは送信直後で反映前の状態)。
        let serverScript = script(flags: [.flagged], capabilities: capabilities)
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: serverScript)
        }
        // `scope: .all` — 既定の `.inboxOnly` だと All Mail が同期対象に
        // ならず、このバグの舞台 (All Mail 側の兄弟行が戻される) がそもそも
        // 再現しない。実機では All Mail を開いての pull-to-refresh や
        // バックグラウンドの全メールボックス同期がこれに当たる。
        _ = try await syncer.performIncrementalSync(auth: auth, scope: .all)
    }

    @Test("未送信の op がある間、All Mail 側の同期がピンを戻さない")
    func syncDoesNotRestorePinWhileOpIsPending() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = try await seedAndUnpin(database: database)

        try await runIncrementalSync(account: account, database: database)

        let after = try await database.dbWriter.read { db in
            (
                pinned: try MessageRecord.fetchAll(db).map(\.isPinnedLocal),
                threadPinned: try #require(try ThreadRecord.fetchOne(db)).isPinned
            )
        }
        #expect(after.pinned == [false, false], "All Mail 側の兄弟行もガードされていなければならない")
        #expect(!after.threadPinned)
    }

    /// CONDSTORE 対応サーバーでは `condstoreFlagChangeSync` を通るが、
    /// どちらの経路も `applyFlagsDiffAndReconcileUnknown` に合流するので
    /// 期待値は同じ。
    @Test("CONDSTORE 経路でもピンが戻らない")
    func condstorePathDoesNotRestorePin() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = try await seedAndUnpin(database: database)

        try await runIncrementalSync(account: account, database: database, capabilities: [.condstore])

        let after = try await database.dbWriter.read { db in
            (
                pinned: try MessageRecord.fetchAll(db).map(\.isPinnedLocal),
                threadPinned: try #require(try ThreadRecord.fetchOne(db)).isPinned
            )
        }
        #expect(after.pinned == [false, false])
        #expect(!after.threadPinned)
    }

    /// ガードが**永久固着**していないことの確認 — op が `opQueue` から
    /// 消えれば (replay 成功、あるいは診断画面の「未送信の操作を破棄」)、
    /// サーバーの状態が改めて取り込まれる。これを固定しないと
    /// 「ピンを永久に凍結しただけ」の修正と区別がつかない。
    @Test("op が無くなればサーバーのピン状態を取り込む")
    func guardLiftsOnceOpIsGone() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = try await seedAndUnpin(database: database)

        try await database.dbWriter.write { db in
            _ = try OpQueue.discardAll(accountId: account.id, db: db)
        }
        try await runIncrementalSync(account: account, database: database)

        let after = try await database.dbWriter.read { db in
            (
                pinned: try MessageRecord.fetchAll(db).map(\.isPinnedLocal),
                threadPinned: try #require(try ThreadRecord.fetchOne(db)).isPinned
            )
        }
        #expect(after.pinned == [true, true], "op が無ければサーバーが真実")
        #expect(after.threadPinned)
    }
}
