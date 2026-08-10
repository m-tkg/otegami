import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// 古いメールのバックフィル同期: exercises `SyncCoordinator
/// .syncAccountIncrementally`'s post-sync backfill trigger end to end
/// against `FakeIMAPSession` — the coordinator-level counterpart to
/// `BackfillSyncerTests`' direct actor tests. Same "detached background
/// `Task`, awaited deterministically via a test-only hook" shape
/// `UnifiedInboxPrefetchTests`' Task #63 section uses for the sibling
/// post-sync prefetch trigger (`waitForPendingBackfillForTesting()` here,
/// `waitForPendingPostSyncPrefetchForTesting()` there).
@Suite("SyncCoordinator backfill")
struct SyncCoordinatorBackfillTests {
    private let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

    private func makeAccount() -> AccountRecord {
        AccountRecord(
            id: "account-1", displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
    }

    private func makeEnvelope(uid: UInt32) -> FetchedEnvelope {
        FetchedEnvelope(
            uid: uid,
            messageId: "<seed-\(uid)@otegami.test>",
            inReplyTo: nil,
            references: [],
            subject: "msg-\(uid)",
            from: [EmailAddress(name: "Aiko", address: "aiko@otegami.test")],
            to: [EmailAddress(address: "test1@otegami.test")],
            cc: [], bcc: [], replyTo: [],
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            internalDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            flags: [],
            size: 512
        )
    }

    /// Same `SessionBox` shape `MailboxSyncerTests`/`MessageBodiesPrefetchTests`
    /// use to inspect the specific `FakeIMAPSession` instance a later call
    /// (here, the detached backfill pass) built, after the enclosing test
    /// has already awaited it to completion.
    private final class SessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _session: FakeIMAPSession?
        var session: FakeIMAPSession? {
            get { lock.withLock { _session } }
            set { lock.withLock { _session = newValue } }
        }
    }

    // MARK: (a) coexistence with normal sync — cursor progression end to end

    /// Seeds a 20-message "recent window" (uid 81–100) via `performInitialSync`
    /// against a *narrow* script, matching how a real mailbox's initial sync
    /// only ever sees its own recent-window fetch — then runs one
    /// `syncAccountIncrementally` pass against a *wide* script (uid 1–101,
    /// the "real" server state new-mail/backfill fetches can now see) and
    /// confirms both the normal sync's own new-mail step (uid 101) *and*
    /// the background backfill pass (uid 1–80) land locally from that one
    /// call — without either interfering with the other.
    @Test("backfill runs automatically after a normal sync completes, and coexists with that sync's own new-mail/flag-sync work")
    func backfillRunsAfterNormalSyncAndCoexists() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let initialScript = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            envelopesByPath: ["INBOX": (81...100).map(makeEnvelope)],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 101, highestModSeq: 0, messageCount: 20)]
        )
        let initialCoordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: initialScript) }
        _ = try await initialCoordinator.syncAccount(account, auth: auth)

        let afterInitial = try await database.dbWriter.read { db in
            try MailboxRecord.filter(Column("accountId") == account.id).filter(Column("path") == "INBOX").fetchOne(db)!
        }
        #expect(afterInitial.backfillLowerBound == 81, "cursor should start at the initial sync's own window minimum")

        // The "real" server: every message 1–101, so both the normal sync's
        // new-mail step (101) and the backfill pass (1–80) have something
        // to find.
        let wideScript = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            envelopesByPath: ["INBOX": (1...101).map(makeEnvelope)],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 102, highestModSeq: 0, messageCount: 101)]
        )
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: wideScript) }

        // `schedulesPostSyncPrefetch: false` — keep this pass focused on the
        // backfill trigger; the unrelated body-prefetch trigger opening its
        // own connection at the same time isn't this test's concern.
        let progress = try await coordinator.syncAccountIncrementally(account, auth: auth, schedulesPostSyncPrefetch: false)
        #expect(progress.newMessages == 1, "the normal sync's own new-mail step must still find uid 101")

        await coordinator.waitForPendingBackfillForTesting()

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.count == 101, "1–100 (20 initial + 80 backfilled) + 101 (new mail)")
        #expect(Set(messages.map(\.uid)) == Set((1...101).map(Int64.init)))

        let afterBackfill = try await database.dbWriter.read { db in
            try MailboxRecord.fetchOne(db, key: afterInitial.id!)
        }
        #expect(afterBackfill?.backfillLowerBound == 1, "80 UIDs fit in a single ≤500-UID batch — one background pass should finish this mailbox")
    }

    // MARK: (b) batch caps — per mailbox and per cycle

    @Test("caps backfill batches at backfillBatchesPerMailboxPerCycle per mailbox and backfillMaxBatchesPerCycle overall")
    func batchesAreCappedPerMailboxAndPerCycle() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in
            try account.insert(db)
            // `uidValidity: 1` matching the script below: keeps
            // `MailboxSyncer.incrementalSync` on its ordinary (non-full-
            // resync) path, which never touches `backfillLowerBound` — the
            // huge starting cursor below must survive this pass's normal
            // sync step untouched, so this batch-cap test is measuring only
            // the backfill pass's own behavior.
            var inbox = MailboxRecord(
                accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox,
                uidValidity: 1, uidNext: 1, backfillLowerBound: 5000
            )
            try inbox.insert(db)
            var archive = MailboxRecord(
                accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive,
                backfillLowerBound: 5000
            )
            try archive.insert(db)
            var work = MailboxRecord(
                accountId: account.id, path: "Work", displayPath: "Work", role: .none,
                backfillLowerBound: 5000
            )
            try work.insert(db)
            // `backfillLowerBound: 5000` means "everything from uid 5000 up
            // is already stored locally" — so each window's lower edge has
            // to actually exist as a row. Without it (`MessageQuery.maxUID`
            // returning `nil`) `MailboxSyncer.incrementalSync` takes its
            // "no locally stored message" branch instead of the ordinary
            // incremental path, re-establishing the recent window and
            // resetting these very cursors via `BackfillSyncer.resetCursor`
            // — see that branch's doc comment (実機バグ: 受信トレイ空運用の
            // Gmail で UID 空間全体をスキャンして5分かかっていた件).
            for mailbox in [inbox, archive, work] {
                var seed = MessageRecord(mailboxId: mailbox.id!, uid: 5000, subject: "window-edge", internalDate: Date())
                try seed.insert(db)
            }
        }

        let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let script = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 1),
                "Archive": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 1),
                "Work": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 1),
            ]
        )
        let sessionBox = SessionBox()
        let coordinator = SyncCoordinator(database: database) { config in
            let session = FakeIMAPSession(config: config, script: script)
            sessionBox.session = session
            return session
        }

        _ = try await coordinator.syncAccountIncrementally(account, auth: auth, schedulesPostSyncPrefetch: false)
        await coordinator.waitForPendingBackfillForTesting()

        // The backfill pass opens its own connection *after* the normal
        // sync's — `sessionBox` holds whichever session `sessionFactory`
        // built most recently, which by the time
        // `waitForPendingBackfillForTesting()` returns is guaranteed to be
        // the backfill pass's own session (the normal sync above has
        // already fully returned).
        let backfillSession = sessionBox.session
        let fetchedRanges = await backfillSession?.fetchedRanges ?? []
        #expect(fetchedRanges.count == SyncCoordinator.backfillMaxBatchesPerCycle, "overall per-cycle cap")

        let selectedPaths = await backfillSession?.selectedPaths ?? []
        #expect(selectedPaths == ["INBOX", "Archive"], "INBOX sorts first (role == .inbox); Work is never even selected once the per-cycle cap is spent on the first two")
        #expect(Set(selectedPaths).count == 2, "each selected mailbox got batches, but no more than 2 distinct mailboxes were touched")

        let mailboxes = try await database.dbWriter.read { db in
            try MailboxRecord.filter(Column("accountId") == account.id).fetchAll(db)
        }
        let byPath = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.path, $0) })
        #expect(byPath["INBOX"]?.backfillLowerBound == 4000, "5000 - 2 batches * 500")
        #expect(byPath["Archive"]?.backfillLowerBound == 4000, "5000 - 2 batches * 500")
        #expect(byPath["Work"]?.backfillLowerBound == 5000, "untouched once the per-cycle cap was already spent")
    }

    // MARK: (c) schedulesBackfill: false suppresses the trigger entirely

    @Test("schedulesBackfill: false suppresses the backfill trigger entirely")
    func schedulesBackfillFalseSuppressesTrigger() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in
            try account.insert(db)
            var inbox = MailboxRecord(
                accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox,
                uidValidity: 1, uidNext: 1, backfillLowerBound: 600
            )
            try inbox.insert(db)
            // `backfillLowerBound: 600` means "everything from uid 600 up is
            // already stored locally" — so the window's lower edge has to
            // actually exist as a row. Without it (`MessageQuery.maxUID`
            // returning `nil`) `MailboxSyncer.incrementalSync` takes its
            // "no locally stored message" branch instead of the ordinary
            // incremental path, re-establishing the recent window and
            // resetting this very cursor via `BackfillSyncer.resetCursor` —
            // see that branch's doc comment (実機バグ: 受信トレイ空運用の
            // Gmail で UID 空間全体をスキャンして5分かかっていた件).
            var seed = MessageRecord(mailboxId: inbox.id!, uid: 600, subject: "window-edge", internalDate: Date())
            try seed.insert(db)
        }

        let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 1)]
        )
        let coordinator = SyncCoordinator(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }

        _ = try await coordinator.syncAccountIncrementally(
            account, auth: auth, schedulesPostSyncPrefetch: false, schedulesBackfill: false
        )
        await coordinator.waitForPendingBackfillForTesting()

        // The normal sync above already made exactly one connection of its
        // own; if `schedulesBackfill: false` failed to suppress the
        // trigger, a second connection (the backfill pass's) would show up
        // here too.
        #expect(recorder.connectCount == 1)

        let mailbox = try await database.dbWriter.read { db in
            try MailboxRecord.filter(Column("accountId") == account.id).filter(Column("path") == "INBOX").fetchOne(db)
        }
        #expect(mailbox?.backfillLowerBound == 600, "untouched — no backfill pass ran")
    }

    // MARK: (d) a fully-backfilled account opens no connection at all

    @Test("a background pass with nothing left to backfill never opens a connection")
    func completedAccountOpensNoConnection() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in
            try account.insert(db)
            var inbox = MailboxRecord(
                accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox,
                uidValidity: 1, uidNext: 1, backfillLowerBound: 1
            )
            try inbox.insert(db)
        }

        let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0)]
        )
        let coordinator = SyncCoordinator(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }

        _ = try await coordinator.syncAccountIncrementally(account, auth: auth, schedulesPostSyncPrefetch: false)
        await coordinator.waitForPendingBackfillForTesting()

        // Only the normal sync's own connection — the backfill pass found
        // no pending candidates and returned before ever calling
        // `sessionFactory`.
        #expect(recorder.connectCount == 1)
    }
}
