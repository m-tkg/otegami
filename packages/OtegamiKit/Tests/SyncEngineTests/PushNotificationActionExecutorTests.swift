import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

/// Coverage for `PushNotificationActionExecutor.execute(...)` — the entry
/// point `AppDelegate` calls when a push notification's "既読にする"/
/// "アーカイブ" action button is tapped. The target message is
/// `(INBOX, targetUID(uidNext:latestUid:))`: the relay's `latestUid` when
/// the push carried one, otherwise the `uid = max(uidNext - 1, 1)`
/// heuristic (see `targetUID(uidNext:latestUid:)`'s own doc comment).
@Suite("PushNotificationActionExecutor")
struct PushNotificationActionExecutorTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
    }

    /// Inserts an account plus an INBOX mailbox directly, mirroring
    /// `OpQueueProcessorTests+SetFlags.swift`'s identical helper — no real
    /// sync pass is needed for these tests.
    private func makeAccountWithInbox(database: AppDatabase) async throws -> (account: AccountRecord, inbox: MailboxRecord) {
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let inbox = try await database.dbWriter.write { db -> MailboxRecord in
            var record = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1)
            try record.insert(db)
            return record
        }
        return (account, inbox)
    }

    /// Inserts a single-message thread in `mailboxId` at `uid` — the shape
    /// `MessagePinReadState`/`MessageRemoval` both expect a target message
    /// to already have (a `threadId`, since both recompute that thread's
    /// aggregate row after acting).
    @discardableResult
    private func insertSingleMessageThread(
        accountId: String, mailboxId: Int64, uid: Int64, isPinnedLocal: Bool = false, database: AppDatabase
    ) async throws -> (threadId: Int64, messageId: Int64) {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return try await database.dbWriter.write { db in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: date, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(
                mailboxId: mailboxId, uid: uid, date: date, internalDate: date,
                threadId: thread.id, isPinnedLocal: isPinnedLocal
            )
            try message.insert(db)
            return (thread.id!, message.id!)
        }
    }

    private let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

    // MARK: 1. Local message exists — reflected via MessagePinReadState / MessageRemoval

    @Test("markRead on a synced message marks it \\Seen locally and best-effort replays a +FLAGS STORE")
    func markReadWithLocalMessageAppliesReadStateAndReplays() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithInbox(database: database)
        // uidNext 43 → target uid 42, matching `execute`'s
        // `max(uidNext - 1, 1)` heuristic.
        let (_, messageId) = try await insertSingleMessageThread(accountId: account.id, mailboxId: inbox.id!, uid: 42, database: database)

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])

        await PushNotificationActionExecutor.execute(
            action: .markRead, accountId: account.id, uidNext: 43, database: database,
            auth: { _ in self.auth },
            sessionFactory: { config in FakeIMAPSession(config: config, script: script, recorder: recorder) }
        )

        let message = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId) }
        #expect(message?.flags.contains(.seen) == true)

        // The best-effort replay ran to completion and drained the opQueue
        // — `MessagePinReadState.applyReadState` enqueues with the default
        // `op: .replace` (a fully-known local flag state, unlike the
        // not-found branch below).
        let call = try #require(recorder.storeCalls.first)
        #expect(call.path == "INBOX")
        #expect(call.change.uids.uids == [42])
        #expect(call.change.op == .replace)
        #expect(call.change.flags == .seen)

        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchCount(db) }
        #expect(remaining == 0)
    }

    @Test("archive on a synced message removes it locally via MessageRemoval and enqueues an archive op")
    func archiveWithLocalMessageAppliesRemoval() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithInbox(database: database)
        let (threadId, messageId) = try await insertSingleMessageThread(accountId: account.id, mailboxId: inbox.id!, uid: 5, database: database)

        // No credentials available — this test only asserts on the local
        // commit, not the replay (covered by the markRead test above and
        // by `OpQueueProcessorTests+Archive.swift` for the archive op
        // itself).
        await PushNotificationActionExecutor.execute(
            action: .archive, accountId: account.id, uidNext: 6, database: database,
            auth: { _ in nil },
            sessionFactory: { config in FakeIMAPSession(config: config, script: .init(mailboxes: [], statusByPath: [:])) }
        )

        let (message, thread, opCount) = try await database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try ThreadRecord.fetchOne(db, key: threadId),
                try OpQueueRecord.fetchCount(db)
            )
        }
        // No Archive-role mailbox known locally, so `MessageRemoval.commit`
        // removes the row outright (rather than relocating it) — the
        // thread had only this one message, so it's gone too.
        #expect(message == nil)
        #expect(thread == nil)
        #expect(opCount == 1)
    }

    // MARK: 2. No local copy — enqueue against (mailboxId, uid) directly

    @Test("markRead with no local copy enqueues setFlags with op: .add (not .replace)")
    func markReadWithNoLocalCopyEnqueuesAddOp() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithInbox(database: database)

        await PushNotificationActionExecutor.execute(
            action: .markRead, accountId: account.id, uidNext: 100, database: database,
            auth: { _ in nil },
            sessionFactory: { config in FakeIMAPSession(config: config, script: .init(mailboxes: [], statusByPath: [:])) }
        )

        let ops = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(ops.count == 1)
        let op = try #require(ops.first)
        #expect(op.kind == OpQueueKind.setFlags.rawValue)
        let payload = try JSONDecoder().decode(SetFlagsOpPayload.self, from: op.payload)
        #expect(payload.mailboxId == inbox.id)
        #expect(payload.uids == [99])
        #expect(payload.op == .add, "must be .add, not the default .replace — there's no local copy to know the message's other flags from")
        #expect(MessageFlags(rawValue: payload.flagsRaw) == .seen)
    }

    @Test("archive with no local copy enqueues an archive op against (mailboxId, uid)")
    func archiveWithNoLocalCopyEnqueuesArchiveOp() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithInbox(database: database)

        await PushNotificationActionExecutor.execute(
            action: .archive, accountId: account.id, uidNext: 51, database: database,
            auth: { _ in nil },
            sessionFactory: { config in FakeIMAPSession(config: config, script: .init(mailboxes: [], statusByPath: [:])) }
        )

        let ops = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(ops.count == 1)
        let op = try #require(ops.first)
        #expect(op.kind == OpQueueKind.archive.rawValue)
        let payload = try JSONDecoder().decode(ArchiveOpPayload.self, from: op.payload)
        #expect(payload.sourceMailboxId == inbox.id)
        #expect(payload.uids == [50])
    }

    // MARK: 3. Credential resolution failure — skip replay, don't crash

    @Test("auth resolving nil still commits the local change but skips replay")
    func authReturningNilSkipsReplayWithoutCrashing() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithInbox(database: database)
        let (_, messageId) = try await insertSingleMessageThread(accountId: account.id, mailboxId: inbox.id!, uid: 7, database: database)

        let recorder = FakeIMAPSession.CallRecorder()
        await PushNotificationActionExecutor.execute(
            action: .markRead, accountId: account.id, uidNext: 8, database: database,
            auth: { _ in nil },
            sessionFactory: { config in
                FakeIMAPSession(config: config, script: .init(mailboxes: [], statusByPath: [:]), recorder: recorder)
            }
        )

        let message = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId) }
        #expect(message?.flags.contains(.seen) == true, "the local commit still applies even though replay is skipped")
        // No credentials resolved → no IMAP session should even connect
        // for a replay attempt.
        #expect(recorder.storeCalls.isEmpty)
    }

    // MARK: 4. Pinned thread archive guard — swallowed, not thrown

    @Test("archiving a pinned message's thread swallows ArchiveGuardError and ends normally")
    func archiveOnPinnedThreadSwallowsGuardError() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithInbox(database: database)
        let (threadId, messageId) = try await insertSingleMessageThread(
            accountId: account.id, mailboxId: inbox.id!, uid: 3, isPinnedLocal: true, database: database
        )
        try await database.dbWriter.write { db in try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db) }

        // Must not throw/crash despite `MessageRemoval.commit` raising
        // `ArchiveGuardError.pinned` internally.
        await PushNotificationActionExecutor.execute(
            action: .archive, accountId: account.id, uidNext: 4, database: database,
            auth: { _ in nil },
            sessionFactory: { config in FakeIMAPSession(config: config, script: .init(mailboxes: [], statusByPath: [:])) }
        )

        let (message, opCount) = try await database.dbWriter.read { db in
            (try MessageRecord.fetchOne(db, key: messageId), try OpQueueRecord.fetchCount(db))
        }
        #expect(message?.mailboxId == inbox.id, "untouched — the pinned guard rejected the archive")
        #expect(opCount == 0)
    }

    // MARK: Unknown account / no INBOX — no-ops without crashing

    @Test("an unknown accountId is a no-op")
    func unknownAccountIsNoOp() async throws {
        let database = try AppDatabase.makeInMemory()
        await PushNotificationActionExecutor.execute(
            action: .markRead, accountId: "does-not-exist", uidNext: 10, database: database,
            auth: { _ in nil },
            sessionFactory: { config in FakeIMAPSession(config: config, script: .init(mailboxes: [], statusByPath: [:])) }
        )
        let opCount = try await database.dbWriter.read { db in try OpQueueRecord.fetchCount(db) }
        #expect(opCount == 0)
    }

    // MARK: resolveOpenTarget — notification tap (default action) navigation

    @Test("resolveOpenTarget returns the synced message's threadId/messageId")
    func resolveOpenTargetReturnsSyncedMessage() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithInbox(database: database)
        // uidNext 43 → target uid 42, matching the same heuristic as `execute`.
        let (threadId, messageId) = try await insertSingleMessageThread(accountId: account.id, mailboxId: inbox.id!, uid: 42, database: database)

        let target = await PushNotificationActionExecutor.resolveOpenTarget(accountId: account.id, uidNext: 43, database: database)
        #expect(target?.threadId == threadId)
        #expect(target?.messageId == messageId)
    }

    @Test("resolveOpenTarget returns nil for a message not yet synced locally")
    func resolveOpenTargetReturnsNilWhenNotSynced() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _) = try await makeAccountWithInbox(database: database)

        let target = await PushNotificationActionExecutor.resolveOpenTarget(accountId: account.id, uidNext: 100, database: database)
        #expect(target == nil)
    }

    @Test("resolveOpenTarget returns nil for an unknown accountId")
    func resolveOpenTargetReturnsNilForUnknownAccount() async throws {
        let database = try AppDatabase.makeInMemory()
        let target = await PushNotificationActionExecutor.resolveOpenTarget(accountId: "does-not-exist", uidNext: 10, database: database)
        #expect(target == nil)
    }

    // MARK: fetchAndResolveOpenTarget — INBOX優先同期を伴う通知タップ

    /// `resolveOpenTarget`の`FetchedEnvelope`版ヘルパー — サーバー側に
    /// 存在するがローカル未同期のメッセージを`FakeIMAPSession.Script`で
    /// 表現するために必要。`AccountSyncerTests+Incremental.swift`の
    /// `makeInbox(uid:subject:)`と同じ最小限の envelope。
    private func makeEnvelope(uid: UInt32) -> FetchedEnvelope {
        FetchedEnvelope(
            uid: uid,
            messageId: "<seed-\(uid)@otegami.test>",
            inReplyTo: nil,
            references: [],
            subject: "新着",
            from: [EmailAddress(name: "Aiko", address: "aiko@otegami.test")],
            to: [EmailAddress(address: "test1@otegami.test")],
            cc: [], bcc: [], replyTo: [],
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            internalDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            flags: [], size: 512
        )
    }

    @Test("fetchAndResolveOpenTarget already-synced message returns it without syncing")
    func fetchAndResolveOpenTargetReturnsAlreadySyncedMessageWithoutSyncing() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithInbox(database: database)
        let (threadId, messageId) = try await insertSingleMessageThread(accountId: account.id, mailboxId: inbox.id!, uid: 42, database: database)

        let recorder = FakeIMAPSession.CallRecorder()
        let target = await PushNotificationActionExecutor.fetchAndResolveOpenTarget(
            accountId: account.id, uidNext: 43, database: database,
            auth: { _ in self.auth },
            sessionFactory: { config in FakeIMAPSession(config: config, script: .init(mailboxes: [], statusByPath: [:]), recorder: recorder) }
        )
        #expect(target?.threadId == threadId)
        #expect(target?.messageId == messageId)
        #expect(recorder.storeCalls.isEmpty, "already-synced target must not trigger a sync connection")
    }

    @Test("fetchAndResolveOpenTarget syncs the INBOX and finds a message that just arrived")
    func fetchAndResolveOpenTargetSyncsInboxForUnsyncedMessage() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _) = try await makeAccountWithInbox(database: database)

        let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let script = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 42)]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 43, highestModSeq: 0, messageCount: 1)]
        )

        let target = await PushNotificationActionExecutor.fetchAndResolveOpenTarget(
            accountId: account.id, uidNext: 43, database: database,
            auth: { _ in self.auth },
            sessionFactory: { config in FakeIMAPSession(config: config, script: script) }
        )

        let target1 = try #require(target)
        let message = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: target1.messageId) }
        #expect(message?.uid == 42, "the priority INBOX sync should have pulled in the just-arrived message")
    }

    @Test("fetchAndResolveOpenTarget uses the single-UID fast path without listing mailboxes or syncing the whole INBOX")
    func fetchAndResolveOpenTargetFastPathSkipsFullSync() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _) = try await makeAccountWithInbox(database: database)

        // `mailboxes: []` — a full incremental sync could not even find the
        // INBOX in this script, so a resolved target proves the fast path
        // (local mailbox record + targeted single-UID fetch) did the work.
        let script = FakeIMAPSession.Script(
            mailboxes: [],
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 42)]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 43, highestModSeq: 0, messageCount: 1)]
        )

        let recorder = FakeIMAPSession.CallRecorder()
        let target = await PushNotificationActionExecutor.fetchAndResolveOpenTarget(
            accountId: account.id, uidNext: 43, database: database,
            auth: { _ in self.auth },
            sessionFactory: { config in FakeIMAPSession(config: config, script: script, recorder: recorder) }
        )

        let target1 = try #require(target)
        let message = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: target1.messageId) }
        #expect(message?.uid == 42)
        #expect(recorder.listMailboxesCallCount == 0, "the fast path must not pay for a LIST — the INBOX is already known locally")
    }

    @Test("fetchAndResolveOpenTarget falls back to a full INBOX sync when uidValidity changed")
    func fetchAndResolveOpenTargetFallsBackOnUidValidityMismatch() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _) = try await makeAccountWithInbox(database: database)

        // Local INBOX record has uidValidity 1 (makeAccountWithInbox), the
        // server reports 2 — every UID was reassigned, so the fast path's
        // single-UID upsert must not run; the full sync's uidValidity
        // handling (windowed resync) takes over instead.
        let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let script = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 42)]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 2, uidNext: 43, highestModSeq: 0, messageCount: 1)]
        )

        let recorder = FakeIMAPSession.CallRecorder()
        let target = await PushNotificationActionExecutor.fetchAndResolveOpenTarget(
            accountId: account.id, uidNext: 43, database: database,
            auth: { _ in self.auth },
            sessionFactory: { config in FakeIMAPSession(config: config, script: script, recorder: recorder) }
        )

        let target1 = try #require(target)
        let message = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: target1.messageId) }
        #expect(message?.uid == 42)
        #expect(recorder.listMailboxesCallCount > 0, "the uidValidity mismatch must have routed through the full sync")
    }

    @Test("fetchAndResolveOpenTarget returns nil when credentials can't be resolved")
    func fetchAndResolveOpenTargetReturnsNilWithoutAuth() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _) = try await makeAccountWithInbox(database: database)

        let target = await PushNotificationActionExecutor.fetchAndResolveOpenTarget(
            accountId: account.id, uidNext: 43, database: database,
            auth: { _ in nil },
            sessionFactory: { config in FakeIMAPSession(config: config, script: .init(mailboxes: [], statusByPath: [:])) }
        )
        #expect(target == nil)
    }

    @Test("fetchAndResolveOpenTarget returns nil when the target still isn't found after syncing")
    func fetchAndResolveOpenTargetReturnsNilWhenStillNotFoundAfterSync() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _) = try await makeAccountWithInbox(database: database)

        let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let script = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0)]
        )

        let target = await PushNotificationActionExecutor.fetchAndResolveOpenTarget(
            accountId: account.id, uidNext: 43, database: database,
            auth: { _ in self.auth },
            sessionFactory: { config in FakeIMAPSession(config: config, script: script) }
        )
        #expect(target == nil)
    }

    // MARK: targetUID — latestUid 優先 (実機バグ: Gmail で通知タップからメールが開けない)

    @Test("targetUID prefers the relay's latestUid over the uidNext - 1 heuristic")
    func targetUIDPrefersLatestUid() {
        // UIDNEXT が「現存する最大 UID + 1」でないサーバー (実機報告は Gmail)
        // — 推測なら 99 を探してしまうが、リレーが実際に FETCH できた UID は
        // 42 なので、そちらが対象。
        #expect(PushNotificationActionExecutor.targetUID(uidNext: 100, latestUid: 42) == 42)
    }

    @Test("targetUID falls back to the heuristic when the push carried no latestUid")
    func targetUIDFallsBackWithoutLatestUid() {
        // 旧リレー/`RELAY_CONTENT_PREVIEW` off — 従来どおりの推測。
        #expect(PushNotificationActionExecutor.targetUID(uidNext: 100, latestUid: nil) == 99)
        #expect(PushNotificationActionExecutor.targetUID(uidNext: 1, latestUid: nil) == 1)
        #expect(PushNotificationActionExecutor.targetUID(uidNext: 0, latestUid: nil) == 1)
    }

    @Test("targetUID ignores a latestUid outside the 32-bit IMAP UID range")
    func targetUIDIgnoresOutOfRangeLatestUid() {
        // ペイロード上の型は `Int64` — 想定外の値をそのまま `UInt32(_:)` に
        // 渡すとクラッシュするので、範囲外は推測に落ちる。
        #expect(PushNotificationActionExecutor.targetUID(uidNext: 100, latestUid: 0) == 99)
        #expect(PushNotificationActionExecutor.targetUID(uidNext: 100, latestUid: -1) == 99)
        #expect(PushNotificationActionExecutor.targetUID(uidNext: 100, latestUid: Int64(UInt32.max) + 1) == 99)
        #expect(PushNotificationActionExecutor.targetUID(uidNext: 100, latestUid: Int64(UInt32.max)) == UInt32.max)
    }

    /// 実機バグの回帰テスト: Gmail のように UIDNEXT が飛ぶサーバーでは
    /// `uidNext - 1` に該当するメッセージが存在しない。ローカル DB には
    /// (通常の差分同期が取り込んだ) 正しい行があるのに、解決だけが推測 UID を
    /// 探していたため何度再試行しても `nil` になり「メールを読み込めません
    /// でした」で固定されていた。
    @Test("resolveOpenTarget finds the locally-synced message when UIDNEXT skipped ahead")
    func resolveOpenTargetUsesLatestUidWhenUidNextSkippedAhead() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithInbox(database: database)
        let (threadId, messageId) = try await insertSingleMessageThread(
            accountId: account.id, mailboxId: inbox.id!, uid: 42, database: database
        )

        // uidNext=100 → 推測は uid 99 (ローカルにもサーバーにも無い)。
        let target = await PushNotificationActionExecutor.resolveOpenTarget(
            accountId: account.id, uidNext: 100, latestUid: 42, database: database
        )
        #expect(target?.threadId == threadId)
        #expect(target?.messageId == messageId)

        let withoutLatestUid = await PushNotificationActionExecutor.resolveOpenTarget(
            accountId: account.id, uidNext: 100, database: database
        )
        #expect(withoutLatestUid == nil, "推測だけでは見つからない状況であることの確認 (テスト自体の妥当性)")
    }

    @Test("fetchAndResolveOpenTarget resolves without any network when latestUid names a locally-synced message")
    func fetchAndResolveOpenTargetUsesLatestUidWithoutSyncing() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithInbox(database: database)
        let (threadId, _) = try await insertSingleMessageThread(
            accountId: account.id, mailboxId: inbox.id!, uid: 42, database: database
        )

        let recorder = FakeIMAPSession.CallRecorder()
        let target = await PushNotificationActionExecutor.fetchAndResolveOpenTarget(
            accountId: account.id, uidNext: 100, latestUid: 42, database: database,
            auth: { _ in self.auth },
            sessionFactory: { config in FakeIMAPSession(config: config, script: .init(mailboxes: [], statusByPath: [:]), recorder: recorder) }
        )
        #expect(target?.threadId == threadId)
        #expect(recorder.storeCalls.isEmpty, "already-synced target must not trigger a sync connection")
    }

    @Test("execute acts on the latestUid message, not the uidNext - 1 guess")
    func executeUsesLatestUid() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithInbox(database: database)
        let (_, targetMessageId) = try await insertSingleMessageThread(
            accountId: account.id, mailboxId: inbox.id!, uid: 42, database: database
        )
        let (_, bystanderMessageId) = try await insertSingleMessageThread(
            accountId: account.id, mailboxId: inbox.id!, uid: 99, database: database
        )

        await PushNotificationActionExecutor.execute(
            action: .markRead, accountId: account.id, uidNext: 100, latestUid: 42, database: database,
            auth: { _ in nil },
            sessionFactory: { config in FakeIMAPSession(config: config, script: .init(mailboxes: [], statusByPath: [:])) }
        )

        let (target, bystander) = try await database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: targetMessageId),
                try MessageRecord.fetchOne(db, key: bystanderMessageId)
            )
        }
        #expect(target?.flags.contains(.seen) == true)
        #expect(bystander?.flags.contains(.seen) == false, "推測 UID (99) の無関係なメールを既読にしてはいけない")
    }
}
