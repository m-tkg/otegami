import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

@Suite("OpQueueProcessor replay — setFlags")
struct OpQueueProcessorSetFlagsTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
    }

    /// Inserts an account plus an INBOX (and, unless `withTrash` is
    /// `false`, a Trash-role mailbox) directly — `OpQueueProcessor` only
    /// ever reads mailbox rows to resolve a path/uidValidity, so tests
    /// don't need a real sync pass to set this up.
    private func makeAccountWithMailboxes(
        database: AppDatabase,
        inboxUidValidity: Int64 = 1,
        withTrash: Bool = true,
        account: AccountRecord? = nil,
        withSent: Bool = false
    ) async throws -> (account: AccountRecord, inbox: MailboxRecord, trash: MailboxRecord?, sent: MailboxRecord?) {
        let account = account ?? makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let (inbox, trash, sent) = try await database.dbWriter.write { db -> (MailboxRecord, MailboxRecord?, MailboxRecord?) in
            var inboxRecord = MailboxRecord(
                accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox,
                uidValidity: inboxUidValidity
            )
            try inboxRecord.insert(db)

            var trashRecord: MailboxRecord?
            if withTrash {
                var record = MailboxRecord(accountId: account.id, path: "Trash", displayPath: "Trash", role: .trash)
                try record.insert(db)
                trashRecord = record
            }

            var sentRecord: MailboxRecord?
            if withSent {
                var record = MailboxRecord(accountId: account.id, path: "Sent", displayPath: "Sent", role: .sent)
                try record.insert(db)
                sentRecord = record
            }
            return (inboxRecord, trashRecord, sentRecord)
        }
        return (account, inbox, trash, sent)
    }

    /// Inserts a bare `message` row so a test can assert on local state
    /// (e.g. that the flags an offline action already applied locally are
    /// what `replay` mirrors to the server) without going through a full
    /// sync pass.
    @discardableResult
    private func insertMessage(mailboxId: Int64, uid: Int64, flags: MessageFlags, database: AppDatabase) async throws -> MessageRecord {
        try await database.dbWriter.write { db in
            var message = MessageRecord(mailboxId: mailboxId, uid: uid, internalDate: Date(), flagsRaw: flags.rawValue)
            try message.insert(db)
            return message
        }
    }

    private let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

    // MARK: (e) offline enqueue → replay succeeds once reconnected

    @Test("replay applies a queued setFlags op to the server and removes it from the queue")
    func replayAppliesSetFlags() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database)
        let messageId = try await insertMessage(mailboxId: inbox.id!, uid: 42, flags: [], database: database).id!

        // Simulate the offline UI flow: local flag update + enqueue,
        // committed together (MessageView/MessageListView's pattern).
        try await database.dbWriter.write { db in
            var message = try MessageRecord.fetchOne(db, key: messageId)!
            message.flags.insert(.seen)
            try message.update(db)
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [42], flags: message.flags, db: db
            )
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)
        #expect(result.discardedStale == 0)

        #expect(recorder.storeCalls.count == 1)
        let call = try #require(recorder.storeCalls.first)
        #expect(call.path == "INBOX")
        #expect(call.change.uids.uids == [42])
        #expect(call.change.op == .replace)
        #expect(call.change.flags == .seen)

        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remaining.isEmpty)
    }

    @Test("an overlapping replay request drains operations enqueued after the active pass began")
    func overlappingReplayDrainsNewOperation() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [41], flags: .seen, db: db
            )
        }

        let gate = FakeIMAPSession.AsyncCallGate()
        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(storeGate: gate)
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }

        let activeReplay = Task { try await processor.replay(account: account, auth: auth) }
        await gate.waitUntilEntered()

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [42], flags: .seen, db: db
            )
        }
        let overlappingReplay = Task { try await processor.replay(account: account, auth: auth) }

        await gate.open()
        _ = try await activeReplay.value
        _ = try await overlappingReplay.value

        #expect(recorder.storeCalls.map { $0.change.uids.uids } == [[41], [42]])
        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remaining.isEmpty)
    }

    // MARK: (d) idempotent replay, generation-mismatch discard

    @Test("replaying the same absolute-flags op twice issues the same STORE each time (idempotent)")
    func replayIsIdempotent() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database)

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }

        // Enqueue, replay, then enqueue an *identical* op again (as if the
        // same UI action fired twice, or a retry re-enqueued it) and
        // replay again.
        for _ in 0..<2 {
            try await database.dbWriter.write { db in
                try OpQueue.enqueueSetFlags(
                    accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                    uids: [7], flags: .seen, db: db
                )
            }
            let result = try await processor.replay(account: account, auth: auth)
            #expect(result.succeeded == 1)
        }

        #expect(recorder.storeCalls.count == 2)
        // Same absolute flags both times — replaying twice converges to
        // the same server-side state rather than compounding.
        #expect(recorder.storeCalls.allSatisfy { $0.change.flags == .seen && $0.change.op == .replace })

        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remaining.isEmpty)
    }

    @Test("replay discards an op whose uidValidity no longer matches the mailbox")
    func replayDiscardsStaleGeneration() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database, inboxUidValidity: 5)

        try await database.dbWriter.write { db in
            // Enqueued against uidValidity 1 (an older generation than the
            // mailbox's current 5 — e.g. the mailbox was recreated between
            // enqueue and replay).
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: 1,
                uids: [42], flags: .seen, db: db
            )
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 0)
        #expect(result.discardedStale == 1)
        #expect(recorder.storeCalls.isEmpty)

        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remaining.isEmpty)
    }

    @Test("a stale-discarded op is recorded in opQueueStaleDiscard before being removed from opQueue")
    func replayRecordsStaleDiscardBeforeRemoving() async throws {
        // 実機報告「Gmail で既読化/アーカイブしてもサーバに反映されず、
        // 再読込でサーバ状態に巻き戻る」の調査可能化: `.staleDiscarded`が
        // opQueueから無言で消えるだけだった旧挙動を防ぐ回帰テスト —
        // `replayDiscardsStaleGeneration`(直前のテスト)と同じセットアップで
        // 発生させ、`opQueue`から消える*前*に`opQueueStaleDiscard`へ理由付き
        // で記録されていることを確認する。
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database, inboxUidValidity: 5)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: 1,
                uids: [42], flags: .seen, db: db
            )
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.discardedStale == 1)

        let remainingOps = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remainingOps.isEmpty)

        let discards = try await database.dbWriter.read { db in try OpQueueStaleDiscardRecord.fetchAll(db) }
        let discard = try #require(discards.first)
        #expect(discards.count == 1)
        #expect(discard.accountId == account.id)
        #expect(discard.kind == OpQueueKind.setFlags.rawValue)
        #expect(!discard.reason.isEmpty)
    }

    // MARK: `op: FlagOp` (プッシュ通知からの既読化 — see `SetFlagsOpPayload`'s doc comment)

    @Test("SetFlagsOpPayload round-trips op through JSON, defaulting to .replace when the key is absent")
    func setFlagsOpPayloadCodingRoundTrips() throws {
        let withAdd = SetFlagsOpPayload(mailboxId: 1, uidValidity: 1, uids: [42], flagsRaw: MessageFlags.seen.rawValue, op: .add)
        let decodedAdd = try JSONDecoder().decode(SetFlagsOpPayload.self, from: try JSONEncoder().encode(withAdd))
        #expect(decodedAdd == withAdd)
        #expect(decodedAdd.op == .add)

        // Simulates an `opQueue` row persisted before `op` existed: no
        // `op` key in the JSON at all. Must still decode, falling back to
        // `.replace` — the only behavior such a row could have meant.
        let legacyJSON = Data(
            """
            {"mailboxId":1,"uidValidity":1,"uids":[42],"flagsRaw":\(MessageFlags.seen.rawValue)}
            """.utf8
        )
        let decodedLegacy = try JSONDecoder().decode(SetFlagsOpPayload.self, from: legacyJSON)
        #expect(decodedLegacy.op == .replace)
        #expect(decodedLegacy.mailboxId == 1)
        #expect(decodedLegacy.uids == [42])
    }

    @Test("replay issues +FLAGS (op: .add) instead of a full replace when the op was enqueued with op: .add")
    func replayAppliesSetFlagsWithAddOp() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database)

        // Simulates マーク-as-read from a push notification: no local
        // message row exists yet, only a mailboxId/uid pair — enqueueing
        // with op: .add so the STORE only sets \Seen without clobbering
        // any other server-side flags on the message.
        try await database.dbWriter.write { db in
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [99], flags: .seen, op: .add, db: db
            )
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)
        #expect(result.discardedStale == 0)

        #expect(recorder.storeCalls.count == 1)
        let call = try #require(recorder.storeCalls.first)
        #expect(call.path == "INBOX")
        #expect(call.change.uids.uids == [99])
        #expect(call.change.op == .add)
        #expect(call.change.flags == .seen)

        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remaining.isEmpty)
    }
}
