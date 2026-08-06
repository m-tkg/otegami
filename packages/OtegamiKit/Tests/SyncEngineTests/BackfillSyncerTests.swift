import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// 古いメールのバックフィル同期: direct scenario tests for `BackfillSyncer`,
/// the same "build the actor directly, drive it against a scripted
/// `FakeIMAPSession`" shape `MailboxSyncerTests` uses for `MailboxSyncer`.
/// `BackfillSyncer.backfillOneBatch` doesn't itself `connect`/`select` (the
/// caller — `SyncCoordinator` in production — already did), so these tests
/// call it directly against a bare `FakeIMAPSession` without going through
/// `AccountSyncer`/`SyncCoordinator` at all.
@Suite("BackfillSyncer")
struct BackfillSyncerTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Test", email: "test@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test@otegami.test"
        )
    }

    private func makeEnvelope(uid: UInt32, subject: String) -> FetchedEnvelope {
        FetchedEnvelope(
            uid: uid,
            messageId: "<seed-\(uid)@otegami.test>",
            inReplyTo: nil,
            references: [],
            subject: subject,
            from: [EmailAddress(name: "Aiko", address: "aiko@otegami.test")],
            to: [EmailAddress(address: "test@otegami.test")],
            cc: [], bcc: [], replyTo: [],
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            internalDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            flags: [],
            size: 512
        )
    }

    /// Inserts `account` and a bare `MailboxRecord` (no messages) with the
    /// given starting `backfillLowerBound`, returning the freshly-fetched
    /// record (with its assigned `id`).
    private func makeMailbox(database: AppDatabase, account: AccountRecord, backfillLowerBound: Int64) async throws -> MailboxRecord {
        try await database.dbWriter.write { db in
            try account.insert(db)
            var mailbox = MailboxRecord(
                accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox,
                backfillLowerBound: backfillLowerBound
            )
            try mailbox.insert(db)
            return mailbox
        }
    }

    // MARK: (a) cursor progression

    @Test("one batch fetches [max(1, cursor-500), cursor-1] and advances the cursor to the batch's lower bound")
    func batchFetchesExpectedRangeAndAdvancesCursor() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        let mailbox = try await makeMailbox(database: database, account: account, backfillLowerBound: 600)

        let script = FakeIMAPSession.Script(envelopesByPath: [
            "INBOX": [makeEnvelope(uid: 150, subject: "古いメール1"), makeEnvelope(uid: 200, subject: "古いメール2")],
        ])
        let session = FakeIMAPSession(config: account.imapConfig, script: script)
        let backfillSyncer = BackfillSyncer(database: database)

        let result = try await backfillSyncer.backfillOneBatch(
            mailboxRecord: mailbox, mailboxPath: "INBOX", accountId: account.id, session: session
        )

        #expect(result?.messagesFetched == 2)
        #expect(result?.newLowerBound == 100, "600 - 500 = 100")
        #expect(result?.isComplete == false)

        let fetchedRanges = await session.fetchedRanges
        #expect(fetchedRanges.count == 1)
        #expect(fetchedRanges[0].lowerBound == 100)
        #expect(fetchedRanges[0].upperBound == 599)

        let updatedMailbox = try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: mailbox.id!) }
        #expect(updatedMailbox?.backfillLowerBound == 100)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.count == 2)
        #expect(Set(messages.map(\.subject)) == ["古いメール1", "古いメール2"])
    }

    @Test("a batch whose UID range has no messages still advances the cursor (walked, not skipped)")
    func emptyRangeStillAdvancesCursor() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        let mailbox = try await makeMailbox(database: database, account: account, backfillLowerBound: 600)

        // No envelopes scripted for "INBOX" at all — every message in this
        // batch's UID range was long since expunged server-side.
        let session = FakeIMAPSession(config: account.imapConfig, script: FakeIMAPSession.Script())
        let backfillSyncer = BackfillSyncer(database: database)

        let result = try await backfillSyncer.backfillOneBatch(
            mailboxRecord: mailbox, mailboxPath: "INBOX", accountId: account.id, session: session
        )

        #expect(result?.messagesFetched == 0)
        #expect(result?.newLowerBound == 100)
        #expect(result?.isComplete == false)

        let updatedMailbox = try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: mailbox.id!) }
        #expect(updatedMailbox?.backfillLowerBound == 100, "must still advance even though nothing came back")
    }

    // MARK: (b) completion

    @Test("a batch whose lower bound clamps to 1 marks the mailbox complete")
    func batchReachingUID1MarksComplete() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        // 300 - 500 clamps to 1, so this single batch should finish the mailbox.
        let mailbox = try await makeMailbox(database: database, account: account, backfillLowerBound: 300)

        let session = FakeIMAPSession(config: account.imapConfig, script: FakeIMAPSession.Script(
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 1, subject: "最古のメール")]]
        ))
        let backfillSyncer = BackfillSyncer(database: database)

        let result = try await backfillSyncer.backfillOneBatch(
            mailboxRecord: mailbox, mailboxPath: "INBOX", accountId: account.id, session: session
        )

        #expect(result?.newLowerBound == 1)
        #expect(result?.isComplete == true)

        let fetchedRanges = await session.fetchedRanges
        #expect(fetchedRanges[0].lowerBound == 1)
        #expect(fetchedRanges[0].upperBound == 299)
    }

    @Test("a mailbox already at cursor 1 is a no-op — no session calls, isComplete true")
    func alreadyCompleteMailboxIsNoOp() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        let mailbox = try await makeMailbox(database: database, account: account, backfillLowerBound: 1)

        let session = FakeIMAPSession(config: account.imapConfig, script: FakeIMAPSession.Script(
            // If `backfillOneBatch` incorrectly issued a fetch anyway, this
            // scripted failure would make that visible as a thrown error
            // rather than silently succeeding.
            failFetchEnvelopes: .serverError(underlyingDescription: "should not be called")
        ))
        let backfillSyncer = BackfillSyncer(database: database)

        let result = try await backfillSyncer.backfillOneBatch(
            mailboxRecord: mailbox, mailboxPath: "INBOX", accountId: account.id, session: session
        )

        #expect(result?.messagesFetched == 0)
        #expect(result?.newLowerBound == 1)
        #expect(result?.isComplete == true)

        let fetchedRanges = await session.fetchedRanges
        #expect(fetchedRanges.isEmpty)
    }

    // MARK: (c) resetCursor

    @Test("resetCursor derives the cursor from the mailbox's current local minimum UID")
    func resetCursorDerivesFromLocalMinUID() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        // Starts at the default (1) — `resetCursor` should raise it to
        // reflect the messages already stored below.
        let mailbox = try await makeMailbox(database: database, account: account, backfillLowerBound: 1)

        try await database.dbWriter.write { db in
            for uid in [420, 450, 499] as [Int64] {
                var message = MessageRecord(mailboxId: mailbox.id!, uid: uid, subject: "msg-\(uid)", internalDate: Date())
                try message.insert(db)
            }
        }

        try await database.dbWriter.write { db in try BackfillSyncer.resetCursor(mailboxId: mailbox.id!, db: db) }

        let updatedMailbox = try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: mailbox.id!) }
        #expect(updatedMailbox?.backfillLowerBound == 420)
    }

    @Test("resetCursor leaves an empty mailbox at 1 (nothing to backfill)")
    func resetCursorForEmptyMailboxStaysComplete() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        let mailbox = try await makeMailbox(database: database, account: account, backfillLowerBound: 999)

        try await database.dbWriter.write { db in try BackfillSyncer.resetCursor(mailboxId: mailbox.id!, db: db) }

        let updatedMailbox = try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: mailbox.id!) }
        #expect(updatedMailbox?.backfillLowerBound == 1)
    }

    // MARK: (d) FTS indexing (design point 4: backfilled mail must be locally searchable)

    @Test("a backfilled message is indexed into messageSearchIndex the same way a normal sync's envelopes are")
    func backfilledMessageIsSearchable() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        let mailbox = try await makeMailbox(database: database, account: account, backfillLowerBound: 600)

        let session = FakeIMAPSession(config: account.imapConfig, script: FakeIMAPSession.Script(
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 150, subject: "検索できる古いメール")]]
        ))
        let backfillSyncer = BackfillSyncer(database: database)
        _ = try await backfillSyncer.backfillOneBatch(
            mailboxRecord: mailbox, mailboxPath: "INBOX", accountId: account.id, session: session
        )

        let matchedIds = try await database.dbWriter.read { db in
            try Int64.fetchAll(db, sql: "SELECT rowid FROM messageSearchIndex WHERE messageSearchIndex MATCH ?", arguments: ["検索できる"])
        }
        #expect(!matchedIds.isEmpty, "backfilled envelope must go through EnvelopePersister.upsert's FTSIndexer.reindex like any other sync path")
    }
}
