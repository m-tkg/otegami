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

    /// Task #127 (`PENDING.md`「Task #120」節の follow-up 候補、着手):
    /// before this task, `ThreadDetailView`'s own archive/junk/delete
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
}
