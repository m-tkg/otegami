import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// Task #120 (実機報告「アーカイブ解除しても受信箱に pull-to-refresh まで現れない」),
/// end-to-end: `MessageRemoval.commit(.unarchive, ...)` relocates a message
/// into INBOX locally, *before* any network round trip — this suite locks in
/// both halves of that fix working together: the relocated row is genuinely
/// visible via `ThreadQuery` immediately, and once a real `AccountSyncer
/// .performIncrementalSync` pass actually fetches that message's envelope
/// from the (fake) server, `AccountSyncer.reconcilePendingRelocation` adopts
/// the real UID onto the *same* row rather than leaving a duplicate. See
/// `MessageRemovalTests.swift` for the pure-`MessageRemoval` unit coverage of
/// the relocation/undo logic itself; this file is the FakeIMAPSession-driven
/// scenario the task explicitly asked for.
@Suite("Task #120: pending relocation reconciles with the next real sync")
struct MessageRelocationReconciliationTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Test", email: "unarchive-test@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "unarchive-test@otegami.test"
        )
    }

    @Test("unarchive → the thread appears in the INBOX query immediately, then the next incremental sync reconciles the row onto its real UID without duplicating it")
    func unarchiveThenSyncReconcilesWithoutDuplicate() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let (inboxId, archiveId) = try await database.dbWriter.write { db -> (Int64, Int64) in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1, uidNext: 1)
            try inbox.insert(db)
            var archive = MailboxRecord(accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive, uidValidity: 1, uidNext: 6)
            try archive.insert(db)
            return (inbox.id!, archive.id!)
        }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try await database.dbWriter.write { db -> (Int64, Int64) in
            var thread = ThreadRecord(accountId: account.id, lastMessageDate: date, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(
                mailboxId: archiveId, uid: 5, messageId: "<unarchive-repro@otegami.test>",
                subject: "アーカイブ解除テスト", date: date, internalDate: date, threadId: thread.id
            )
            try message.insert(db)
            return (thread.id!, message.id!)
        }

        // Step 1: unarchive — purely local, no network involved yet.
        let summary = try await database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }
        let snapshot = try await database.dbWriter.write { db in
            try MessageRemoval.commit(.unarchive, summary: summary, accountId: account.id, db: db)
        }
        #expect(snapshot != nil)

        let inboxThreadsImmediately = try await database.dbWriter.read { db in
            try ThreadQuery.request(mailboxId: inboxId).fetchAll(db).map(\.id)
        }
        #expect(inboxThreadsImmediately == [threadId], "the unarchived thread must appear in the INBOX query immediately, before any sync")

        let relocatedRow = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId) }
        #expect(relocatedRow?.mailboxId == inboxId)
        #expect(relocatedRow?.isPendingRelocation == true)

        let archiveThreadsImmediately = try await database.dbWriter.read { db in
            try ThreadQuery.request(mailboxId: archiveId).fetchAll(db).map(\.id)
        }
        #expect(archiveThreadsImmediately == [], "and must disappear from the Archive query at the same moment")

        // Step 2: the server has now actually applied the unarchive (a real
        // `OpQueueProcessor` replay would COPY/MOVE it into INBOX) —
        // simulated here by scripting FakeIMAPSession's INBOX listing to
        // report the message's real, server-assigned UID under the same
        // Message-ID.
        let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let archiveInfo = MailboxInfo(path: "Archive", displayPath: "Archive", role: .archive, attributes: [])
        let realEnvelope = FetchedEnvelope(
            uid: 42, messageId: "<unarchive-repro@otegami.test>", inReplyTo: nil, references: [],
            subject: "アーカイブ解除テスト", from: [], to: [], cc: [], bcc: [], replyTo: [],
            date: date, internalDate: date, flags: [], size: 100
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inboxInfo, archiveInfo],
                envelopesByPath: ["INBOX": [realEnvelope]],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 43, highestModSeq: 0, messageCount: 1),
                    "Archive": MailboxStatus(uidValidity: 1, uidNext: 6, highestModSeq: 0, messageCount: 0),
                ]
            ))
        }
        _ = try await syncer.performIncrementalSync(
            auth: .password(username: "unarchive-test@otegami.test", password: "test1234")
        )

        // Reconciled onto the real UID, same row id — never duplicated.
        let inboxMessagesAfterSync = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == inboxId).fetchAll(db)
        }
        #expect(inboxMessagesAfterSync.count == 1, "must not duplicate — exactly one row for this message in INBOX after the real sync")
        #expect(inboxMessagesAfterSync.first?.id == messageId, "the same row that was relocated, not a fresh insert")
        #expect(inboxMessagesAfterSync.first?.uid == 42)
        #expect(inboxMessagesAfterSync.first?.isPendingRelocation == false)

        let inboxThreadsAfterSync = try await database.dbWriter.read { db in
            try ThreadQuery.request(mailboxId: inboxId).fetchAll(db).map(\.id)
        }
        #expect(inboxThreadsAfterSync == [threadId])
    }

    /// CONDSTORE counterpart of `pendingRelocationConflictingWithAlreadyRealRowMergesWithoutDuplicating`
    /// below — same collision (a pending relocation row's real UID already
    /// occupied locally by a genuine, independently-synced duplicate), but
    /// exercised through `MailboxSyncer.condstoreFlagChangeSync` rather than
    /// the non-CONDSTORE `refetchAndDiffFlags`. This is exactly the risk
    /// Phase 2 item 2.1 called out explicitly: naively switching the
    /// CONDSTORE path to a flags-only fast path would see UID 42 as "known
    /// locally" (the already-real row), diff its flags, and — whether or
    /// not the flags actually changed — never call `EnvelopePersister
    /// .upsert` (and therefore never `reconcilePendingRelocation`) for it at
    /// all, since the flags-only fast path only re-fetches a full envelope
    /// for UIDs it *doesn't* already recognize. Without the
    /// `hasPendingRelocations` fallback this test locks in, the pending row
    /// would sit there forever, orphaned, exactly the Task #183 bug this
    /// mailbox's non-CONDSTORE equivalent (`refetchAndDiffFlags`) already
    /// guards against.
    @Test("CONDSTORE flags-only fast path falls back to a full envelope changedSince fetch when a pending relocation row collides with an already-real duplicate")
    func condstorePendingRelocationConflictingWithAlreadyRealRowMergesWithoutDuplicating() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let (inboxId, archiveId) = try await database.dbWriter.write { db -> (Int64, Int64) in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1, uidNext: 1)
            try inbox.insert(db)
            // `highestModSeq: 3` (not 0): stored `highestModSeq == 0` now
            // routes `incrementalSync` through `MailboxSyncer`'s baseline
            // guard (a flags-only `refetchAndDiffFlags` refetch) rather
            // than `condstoreFlagChangeSync`'s CHANGEDSINCE-based path —
            // this test specifically exercises the latter's pending-
            // relocation collision handling, so it needs a stored modSeq
            // that's non-zero but still below the server's reported `5`.
            var archive = MailboxRecord(accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive, uidValidity: 1, uidNext: 43, highestModSeq: 3)
            try archive.insert(db)
            return (inbox.id!, archive.id!)
        }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let sharedMessageId = "<condstore-dup-conflict-repro@otegami.test>"

        // The message this device is about to (locally) archive.
        let (threadId, pendingMessageId) = try await database.dbWriter.write { db -> (Int64, Int64) in
            var thread = ThreadRecord(accountId: account.id, lastMessageDate: date, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(
                mailboxId: inboxId, uid: 5, messageId: sharedMessageId,
                subject: "重複合流テスト (CONDSTORE)", date: date, internalDate: date, threadId: thread.id
            )
            try message.insert(db)
            return (thread.id!, message.id!)
        }

        let summary = try await database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: pendingMessageId)
            )
        }
        _ = try await database.dbWriter.write { db in
            try MessageRemoval.commit(.archive, summary: summary, accountId: account.id, db: db)
        }
        let pendingRow = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: pendingMessageId) }
        #expect(pendingRow?.mailboxId == archiveId)
        #expect(pendingRow?.isPendingRelocation == true)

        // A genuine, already-synced copy of the *same* message already
        // sitting at the real destination UID (42) in Archive — UID 42 is
        // therefore already inside the mailbox's synced window
        // (`uidNext: 43` above), so step 1's "new mail" window never
        // touches it either; only `condstoreFlagChangeSync` (step 2) can
        // discover it changed.
        let realArchiveMessageId = try await database.dbWriter.write { db -> Int64 in
            var already = MessageRecord(
                mailboxId: archiveId, uid: 42, messageId: sharedMessageId,
                subject: "重複合流テスト (CONDSTORE)", date: date, internalDate: date, threadId: threadId
            )
            try already.insert(db)
            return already.id!
        }

        // The server reports UID 42's flags changed via CONDSTORE
        // `changedSince` — modeling e.g. another client flagging it.
        let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let archiveInfo = MailboxInfo(path: "Archive", displayPath: "Archive", role: .archive, attributes: [])
        let realEnvelope = FetchedEnvelope(
            uid: 42, messageId: sharedMessageId, inReplyTo: nil, references: [],
            subject: "重複合流テスト (CONDSTORE)", from: [], to: [], cc: [], bcc: [], replyTo: [],
            date: date, internalDate: date, flags: [.flagged], size: 100
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inboxInfo, archiveInfo],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "Archive": MailboxStatus(uidValidity: 1, uidNext: 43, highestModSeq: 5, messageCount: 1),
                ],
                capabilitiesToReport: [.condstore, .qresync],
                changedSinceEnvelopesByPath: ["Archive": [realEnvelope]],
                qresyncVanishedUIDsByPath: ["Archive": []]
            ))
        }
        _ = try await syncer.performIncrementalSync(
            auth: .password(username: account.imapUsername, password: "test1234"), scope: .mailbox(path: "Archive")
        )

        let archiveMessagesAfterSync = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == archiveId).filter(Column("messageId") == sharedMessageId).fetchAll(db)
        }
        #expect(archiveMessagesAfterSync.count == 1, "must not duplicate — the pending row merges into the already-real one instead of colliding with it")
        #expect(archiveMessagesAfterSync.first?.id == realArchiveMessageId, "the already-real row survives; the pending one is discarded")
        #expect(archiveMessagesAfterSync.first?.uid == 42)

        let pendingRowAfterSync = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: pendingMessageId) }
        #expect(pendingRowAfterSync == nil, "the redundant pending row is gone rather than left orphaned forever")
    }

    /// Task #127: before this task, `ThreadDetailView`'s own archive/junk/delete
    /// (本文画面フッターツールバーの "…" メニュー) was a separate,
    /// hand-rolled implementation that never called `MessageRemoval.commit`
    /// at all — so it never got this same immediate-relocation behavior.
    /// `ThreadDetailView.threadSummary(threadId:singleMessageId:accountId:
    /// db:)` now builds its summary via `ThreadSummary(flatMessage:
    /// accountId:)` whenever `singleMessageId` is set (the flat-mode/
    /// resolved-single-message entry — the common case for opening a
    /// message from the unified inbox), exactly mirroring this test: same
    /// constructor, same `MessageRemoval.commit` call, so this locks in
    /// that the body screen's code path gets the identical immediate
    /// relocation + no-duplicate-after-sync guarantee the list/swipe path
    /// already had, this time for `.archive` starting from a `flatMessage`
    /// summary instead of a `thread`/`latestMessage` one.
    @Test("archive from a flat/single-message ThreadSummary (ThreadDetailView's own construction) relocates immediately and reconciles without duplicating")
    func archiveFromFlatMessageSummaryThenSyncReconcilesWithoutDuplicate() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let (inboxId, archiveId) = try await database.dbWriter.write { db -> (Int64, Int64) in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1, uidNext: 6)
            try inbox.insert(db)
            var archive = MailboxRecord(accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive, uidValidity: 1, uidNext: 1)
            try archive.insert(db)
            return (inbox.id!, archive.id!)
        }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try await database.dbWriter.write { db -> (Int64, Int64) in
            var thread = ThreadRecord(accountId: account.id, lastMessageDate: date, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(
                mailboxId: inboxId, uid: 5, messageId: "<threaddetail-archive-repro@otegami.test>",
                subject: "本文画面アーカイブテスト", date: date, internalDate: date, threadId: thread.id
            )
            try message.insert(db)
            return (thread.id!, message.id!)
        }

        // Step 1: archive — built exactly the way `ThreadDetailView
        // .threadSummary(threadId:singleMessageId:accountId:db:)` builds it
        // for a non-`nil` `singleMessageId` (this screen's flat/resolved-
        // single-message entry), not `ThreadSummary(thread:latestMessage:)`.
        let snapshot = try await database.dbWriter.write { db -> MessageRemoval.Snapshot? in
            let message = try #require(try MessageRecord.fetchOne(db, key: messageId))
            let summary = ThreadSummary(flatMessage: message, accountId: account.id)
            return try MessageRemoval.commit(.archive, summary: summary, accountId: account.id, db: db)
        }
        #expect(snapshot != nil, "must actually remove — otherwise ThreadDetailView.commitRemoval would skip notifyThreadRemoved()/replaySoon() entirely")

        let relocatedRow = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId) }
        #expect(relocatedRow?.mailboxId == archiveId, "relocated into Archive immediately, before any network round trip")
        #expect(relocatedRow?.isPendingRelocation == true)

        let archiveThreadsImmediately = try await database.dbWriter.read { db in
            try ThreadQuery.request(mailboxId: archiveId).fetchAll(db).map(\.id)
        }
        #expect(archiveThreadsImmediately == [threadId], "visible in the Archive query immediately — the whole point of Task #120's relocation, now reachable from ThreadDetailView too")

        let inboxThreadsImmediately = try await database.dbWriter.read { db in
            try ThreadQuery.request(mailboxId: inboxId).fetchAll(db).map(\.id)
        }
        #expect(inboxThreadsImmediately == [], "and gone from INBOX at the same moment")

        // Step 2: the server has now actually applied the archive — scripted
        // the same way `unarchiveThenSyncReconcilesWithoutDuplicate` above
        // scripts its own real sync.
        let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let archiveInfo = MailboxInfo(path: "Archive", displayPath: "Archive", role: .archive, attributes: [])
        let realEnvelope = FetchedEnvelope(
            uid: 1, messageId: "<threaddetail-archive-repro@otegami.test>", inReplyTo: nil, references: [],
            subject: "本文画面アーカイブテスト", from: [], to: [], cc: [], bcc: [], replyTo: [],
            date: date, internalDate: date, flags: [], size: 100
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inboxInfo, archiveInfo],
                envelopesByPath: ["Archive": [realEnvelope]],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 6, highestModSeq: 0, messageCount: 0),
                    "Archive": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1),
                ]
            ))
        }
        // `scope: .mailbox("Archive")`, not the default `.inboxOnly` —
        // unlike the unarchive scenario above (whose destination, INBOX, is
        // exactly what `.inboxOnly` already covers), archive's destination
        // is a non-INBOX mailbox that a plain default-scope sync wouldn't
        // touch at all.
        _ = try await syncer.performIncrementalSync(
            auth: .password(username: account.imapUsername, password: "test1234"), scope: .mailbox(path: "Archive")
        )

        // Reconciled onto the real UID, same row id — never duplicated, even
        // though this test's summary was built the `flatMessage` way
        // `ThreadDetailView` uses rather than the `thread`/`latestMessage`
        // way `MessageListView`/`AccountDigestView` use.
        let archiveMessagesAfterSync = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == archiveId).fetchAll(db)
        }
        #expect(archiveMessagesAfterSync.count == 1, "must not duplicate")
        #expect(archiveMessagesAfterSync.first?.id == messageId, "the same row that was relocated, not a fresh insert")
        #expect(archiveMessagesAfterSync.first?.uid == 1)
        #expect(archiveMessagesAfterSync.first?.isPendingRelocation == false)

        let archiveThreadsAfterSync = try await database.dbWriter.read { db in
            try ThreadQuery.request(mailboxId: archiveId).fetchAll(db).map(\.id)
        }
        #expect(archiveThreadsAfterSync == [threadId])
    }

    /// Task #183 (実機報告「iCloud の Archive メールボックスの同期が毎回
    /// `UNIQUE constraint failed: message.mailboxId, message.uid` で失敗する」):
    /// the destination `(mailboxId, uid)` a pending-relocation row is about
    /// to adopt can already be occupied by a *genuine*, independently-
    /// synced row for the exact same message — e.g. another client already
    /// completed the same archive server-side, and this device's own
    /// Archive sync happened to observe that real row before this device's
    /// own local relocation got a chance to reconcile. Before this task,
    /// `AccountSyncer.reconcilePendingRelocation` blindly rewrote the
    /// pending row's `uid` onto the real one regardless, tripping the
    /// uniqueness constraint every single sync pass thereafter (no self-
    /// heal — the pending row was never cleaned up). This locks in the fix:
    /// the sync must not throw, must not leave a visible duplicate, and
    /// must carry the pending row's local-only pin state forward onto the
    /// survivor.
    @Test("a pending relocation row reconciles onto an already-real duplicate at the destination without duplicating or crashing")
    func pendingRelocationConflictingWithAlreadyRealRowMergesWithoutDuplicating() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let (inboxId, archiveId) = try await database.dbWriter.write { db -> (Int64, Int64) in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1, uidNext: 1)
            try inbox.insert(db)
            var archive = MailboxRecord(accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive, uidValidity: 1, uidNext: 43)
            try archive.insert(db)
            return (inbox.id!, archive.id!)
        }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let sharedMessageId = "<dup-conflict-repro@otegami.test>"

        // The message this device is about to (locally) archive, pinned so
        // the merge-forward of local-only state is actually exercised.
        let (threadId, pendingMessageId) = try await database.dbWriter.write { db -> (Int64, Int64) in
            var thread = ThreadRecord(accountId: account.id, lastMessageDate: date, messageCount: 1)
            try thread.insert(db)
            // Task #212 (ピン留めとサーバーの `\Flagged` の常時連動化):
            // `isPinnedLocal`単独でなく`.flagged`も一緒に立てておく —
            // 常時連動下では`AccountSyncer.upsert`が毎回サーバーの
            // `\Flagged`を`isPinnedLocal`へ無条件で反映するため、この
            // fixture 自身がその不変条件 (ピンなら`.flagged`も立って
            // いる) を満たしていないと、この後の再同期で
            // `isPinnedLocal`が正規化されてしまい、このテストが検証
            // したい「マージでローカル状態が引き継がれる」ことと無関係
            // な理由で落ちる。
            var message = MessageRecord(
                mailboxId: inboxId, uid: 5, messageId: sharedMessageId,
                subject: "重複合流テスト", date: date, internalDate: date,
                flagsRaw: MessageFlags.flagged.rawValue,
                threadId: thread.id,
                isPinnedLocal: true
            )
            try message.insert(db)
            return (thread.id!, message.id!)
        }

        // Local archive: relocates `pendingMessageId` into Archive with a
        // placeholder UID, same as the other tests in this file. Committed
        // *before* the already-real duplicate below is inserted — this
        // thread has only one message at this point, so `MessageRemoval
        // .commit`'s own `ThreadQuery.actionTargets`/`deduplicate` (which
        // already collapses same-`messageId` rows *within a thread* before
        // any action runs) never gets a chance to hide either row from the
        // other; the point of this test is the sync-time reconciliation
        // race, not that pre-existing action-target dedup.
        let summary = try await database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: pendingMessageId)
            )
        }
        _ = try await database.dbWriter.write { db in
            try MessageRemoval.commit(.archive, summary: summary, accountId: account.id, db: db)
        }
        let pendingRow = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: pendingMessageId) }
        #expect(pendingRow?.mailboxId == archiveId)
        #expect(pendingRow?.isPendingRelocation == true)

        // A genuine, already-synced copy of the *same* message now sitting
        // at the real destination UID (42) in Archive — the "some other
        // sync already caught up" half of the race, arriving only now
        // (e.g. this device's own initial/full sync of Archive completing
        // independently) so it can't have been deduplicated away above.
        let realArchiveMessageId = try await database.dbWriter.write { db -> Int64 in
            var already = MessageRecord(
                mailboxId: archiveId, uid: 42, messageId: sharedMessageId,
                subject: "重複合流テスト", date: date, internalDate: date, threadId: threadId
            )
            try already.insert(db)
            return already.id!
        }

        // The server confirms the same real UID (42) the independently-
        // synced copy already has — before this task's fix, reconciling the
        // pending row onto `uid: 42` here threw the uniqueness violation.
        let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let archiveInfo = MailboxInfo(path: "Archive", displayPath: "Archive", role: .archive, attributes: [])
        // Task #212: `.flagged` set too (see the pinned fixture above's
        // comment) — under always-on pin/flag sync, the server confirming
        // this message is expected to also confirm the `\Flagged` bit that
        // the earlier local pin's own `setFlags` op would have pushed.
        let realEnvelope = FetchedEnvelope(
            uid: 42, messageId: sharedMessageId, inReplyTo: nil, references: [],
            subject: "重複合流テスト", from: [], to: [], cc: [], bcc: [], replyTo: [],
            date: date, internalDate: date, flags: [.flagged], size: 100
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inboxInfo, archiveInfo],
                envelopesByPath: ["Archive": [realEnvelope]],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "Archive": MailboxStatus(uidValidity: 1, uidNext: 43, highestModSeq: 0, messageCount: 1),
                ]
            ))
        }
        _ = try await syncer.performIncrementalSync(
            auth: .password(username: account.imapUsername, password: "test1234"), scope: .mailbox(path: "Archive")
        )

        let archiveMessagesAfterSync = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == archiveId).filter(Column("messageId") == sharedMessageId).fetchAll(db)
        }
        #expect(archiveMessagesAfterSync.count == 1, "must not duplicate — the pending row merges into the already-real one instead of colliding with it")
        #expect(archiveMessagesAfterSync.first?.id == realArchiveMessageId, "the already-real row survives; the pending one is discarded")
        #expect(archiveMessagesAfterSync.first?.uid == 42)
        #expect(archiveMessagesAfterSync.first?.isPinnedLocal == true, "the discarded pending row's local-only pin state is merged forward onto the survivor")

        let pendingRowAfterSync = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: pendingMessageId) }
        #expect(pendingRowAfterSync == nil, "the redundant pending row is gone rather than left orphaned")
    }

    /// Task #183: a device that already hit the bug above before this fix
    /// shipped can be left with more than one leftover pending-relocation
    /// row for the same message (e.g. one crashed reconciliation attempt
    /// per subsequent sync pass, each leaving its own placeholder behind).
    /// Locks in that the very next sync after upgrading self-heals: every
    /// matching pending row collapses onto a single real row rather than
    /// the sync continuing to fail forever.
    @Test("two leftover pending relocation rows for the same message collapse onto one real row on the next sync")
    func twoLeftoverPendingRelocationRowsCollapseOnNextSync() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let archiveId = try await database.dbWriter.write { db -> Int64 in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1, uidNext: 1)
            try inbox.insert(db)
            var archive = MailboxRecord(accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive, uidValidity: 1, uidNext: 6)
            try archive.insert(db)
            return archive.id!
        }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let sharedMessageId = "<dup-pending-repro@otegami.test>"

        let (threadId, firstPendingId) = try await database.dbWriter.write { db -> (Int64, Int64) in
            var thread = ThreadRecord(accountId: account.id, lastMessageDate: date, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(
                mailboxId: archiveId, uid: -1, messageId: sharedMessageId,
                subject: "多重仮配置行テスト", date: date, internalDate: date, threadId: thread.id
            )
            try message.insert(db)
            return (thread.id!, message.id!)
        }
        // A second, leftover placeholder for the exact same message — the
        // "device already hit this bug before" leftover this task's
        // self-heal must clean up. Pinned, so the merge-forward is
        // actually exercised on this branch too. Task #212: `.flagged` set
        // alongside `isPinnedLocal` (and the `realEnvelope` below also
        // reports `.flagged`) — under always-on pin/flag sync,
        // `AccountSyncer.upsert` unconditionally mirrors the server's
        // `\Flagged` bit into `isPinnedLocal` on every resync, so this
        // fixture has to satisfy that invariant itself or the post-merge
        // resync would normalize `isPinnedLocal` back down for a reason
        // unrelated to what this test is actually checking (the merge
        // logic, not the resync's own flag-mirroring).
        let secondPendingId = try await database.dbWriter.write { db -> Int64 in
            var stale = MessageRecord(
                mailboxId: archiveId, uid: -2, messageId: sharedMessageId,
                subject: "多重仮配置行テスト", date: date, internalDate: date,
                flagsRaw: MessageFlags.flagged.rawValue,
                threadId: threadId,
                isPinnedLocal: true
            )
            try stale.insert(db)
            return stale.id!
        }

        let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let archiveInfo = MailboxInfo(path: "Archive", displayPath: "Archive", role: .archive, attributes: [])
        let realEnvelope = FetchedEnvelope(
            uid: 42, messageId: sharedMessageId, inReplyTo: nil, references: [],
            subject: "多重仮配置行テスト", from: [], to: [], cc: [], bcc: [], replyTo: [],
            date: date, internalDate: date, flags: [.flagged], size: 100
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inboxInfo, archiveInfo],
                envelopesByPath: ["Archive": [realEnvelope]],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "Archive": MailboxStatus(uidValidity: 1, uidNext: 43, highestModSeq: 0, messageCount: 1),
                ]
            ))
        }
        // Before this task's fix, this threw the very first time it hit
        // whichever pending row's rewrite happened to collide with the
        // other's placeholder having already been promoted — the recovery
        // this test exists for.
        _ = try await syncer.performIncrementalSync(
            auth: .password(username: account.imapUsername, password: "test1234"), scope: .mailbox(path: "Archive")
        )

        let archiveMessagesAfterSync = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == archiveId).filter(Column("messageId") == sharedMessageId).fetchAll(db)
        }
        #expect(archiveMessagesAfterSync.count == 1, "both pending rows collapse onto a single real row")
        #expect(archiveMessagesAfterSync.first?.uid == 42)
        #expect(archiveMessagesAfterSync.first?.isPendingRelocation == false)
        #expect(archiveMessagesAfterSync.first?.isPinnedLocal == true, "the discarded duplicate's local-only pin state survives the merge")

        let survivorId = archiveMessagesAfterSync.first?.id
        #expect(survivorId == firstPendingId || survivorId == secondPendingId, "the survivor is one of the two original rows, not a third fresh insert")

        let threadAfterSync = try await database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) }
        #expect(threadAfterSync?.messageCount == 1, "collapsing the duplicate must not leave the thread double-counting it")
    }

    /// 実機報告「iOS で Gmail のさっき受信したメールをアーカイブしたらどこにも
    /// 表示されなくなった」, end-to-end. A Gmail archive now relocates into All
    /// Mail (`MessageRemoval.relocationDestinationId`) instead of deleting the
    /// row, and the archive op reports All Mail so a targeted resync actually
    /// runs (`OpQueueProcessor`'s `.archive` Gmail branch). This locks in that
    /// the two halves meet: visible as archived at once, then adopted onto the
    /// real UID by that All Mail sync — one row, never two, since フラット表示
    /// wouldn't dedup a second one.
    @Test("Gmail archive → visible in All Mail immediately, then the All Mail sync adopts the placeholder onto its real UID")
    func gmailArchiveThenAllMailSyncReconcilesWithoutDuplicate() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Gmail", email: "gmail-archive@otegami.test", authType: .oauth2, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls,
            imapUsername: "gmail-archive@otegami.test"
        )
        try await database.dbWriter.write { db in try account.insert(db) }

        let (inboxId, allMailId) = try await database.dbWriter.write { db -> (Int64, Int64) in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1, uidNext: 6)
            try inbox.insert(db)
            var allMail = MailboxRecord(
                accountId: account.id, path: "[Gmail]/All Mail", displayPath: "[Gmail]/All Mail",
                role: .all, uidValidity: 1, uidNext: 1
            )
            try allMail.insert(db)
            return (inbox.id!, allMail.id!)
        }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try await database.dbWriter.write { db -> (Int64, Int64) in
            var thread = ThreadRecord(accountId: account.id, lastMessageDate: date, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(
                mailboxId: inboxId, uid: 5, messageId: "<gmail-archive-repro@otegami.test>",
                subject: "Gmail アーカイブテスト", date: date, internalDate: date,
                gmailMessageId: 555, threadId: thread.id
            )
            try message.insert(db)
            return (thread.id!, message.id!)
        }

        let snapshot = try await database.dbWriter.write { db -> MessageRemoval.Snapshot? in
            let message = try #require(try MessageRecord.fetchOne(db, key: messageId))
            let summary = ThreadSummary(flatMessage: message, accountId: account.id)
            return try MessageRemoval.commit(.archive, summary: summary, accountId: account.id, db: db)
        }
        #expect(snapshot != nil)

        let (relocatedRow, archivedImmediately, inboxImmediately) = try await database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try ThreadQuery.unifiedInboxRequest(accountIds: [account.id], role: .archive).fetchAll(db).map(\.id),
                try ThreadQuery.unifiedInboxRequest(accountIds: [account.id], role: .inbox).fetchAll(db).map(\.id)
            )
        }
        #expect(relocatedRow?.mailboxId == allMailId, "relocated into All Mail immediately, before any network round trip")
        #expect(relocatedRow?.isPendingRelocation == true)
        #expect(archivedImmediately == [threadId], "the reported bug: this used to be empty because the row was deleted outright")
        #expect(inboxImmediately.isEmpty)

        // The server has now applied the unlabel, and the targeted resync the
        // archive op schedules runs against All Mail.
        let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let allMailInfo = MailboxInfo(path: "[Gmail]/All Mail", displayPath: "[Gmail]/All Mail", role: .all, attributes: [])
        let realEnvelope = FetchedEnvelope(
            uid: 1, messageId: "<gmail-archive-repro@otegami.test>", inReplyTo: nil, references: [],
            subject: "Gmail アーカイブテスト", from: [], to: [], cc: [], bcc: [], replyTo: [],
            date: date, internalDate: date, flags: [], size: 100
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inboxInfo, allMailInfo],
                envelopesByPath: ["[Gmail]/All Mail": [realEnvelope]],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 6, highestModSeq: 0, messageCount: 0),
                    "[Gmail]/All Mail": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1),
                ]
            ))
        }
        _ = try await syncer.performIncrementalSync(
            auth: .password(username: account.imapUsername, password: "test1234"),
            scope: .mailbox(path: "[Gmail]/All Mail")
        )

        let allMailRows = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == allMailId).fetchAll(db)
        }
        #expect(allMailRows.count == 1, "must not duplicate — フラット表示 doesn't dedup by message identity")
        #expect(allMailRows.first?.id == messageId, "the same row that was relocated, not a fresh insert")
        #expect(allMailRows.first?.uid == 1)
        #expect(allMailRows.first?.isPendingRelocation == false)

        let (archivedAfterSync, flatAfterSync) = try await database.dbWriter.read { db in
            (
                try ThreadQuery.unifiedInboxRequest(accountIds: [account.id], role: .archive).fetchAll(db).map(\.id),
                try ThreadQuery.unifiedInboxFlatSummaries(accountIds: [account.id], role: .archive, db: db)
            )
        }
        #expect(archivedAfterSync == [threadId])
        #expect(flatAfterSync.count == 1)
    }
}
