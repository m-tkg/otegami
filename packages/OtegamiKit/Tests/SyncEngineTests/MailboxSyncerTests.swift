import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// Scenario tests for `MailboxSyncer.incrementalSync`, driven the same way
/// `AccountSyncerTests` drives `performInitialSync`: two `AccountSyncer`
/// instances against the same in-memory database, each built with a fresh
/// `FakeIMAPSession.Script` representing "the server, as of this sync
/// pass" — the first sync seeds local state via `performInitialSync`, the
/// second exercises `performIncrementalSync` against a script representing
/// what changed server-side in between.
@Suite("MailboxSyncer incremental sync")
struct MailboxSyncerTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
    }

    private func makeEnvelope(uid: UInt32, subject: String, flags: MessageFlags = []) -> FetchedEnvelope {
        FetchedEnvelope(
            uid: uid,
            messageId: "<seed-\(uid)@otegami.test>",
            inReplyTo: nil,
            references: [],
            subject: subject,
            from: [EmailAddress(name: "Aiko", address: "aiko@otegami.test")],
            to: [EmailAddress(address: "test1@otegami.test")],
            cc: [], bcc: [], replyTo: [],
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            internalDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            flags: flags,
            size: 512
        )
    }

    /// Seeds the database via `performInitialSync` against `initialScript`
    /// and returns the account, ready for a second `AccountSyncer` (built
    /// against a different script) to run `performIncrementalSync`.
    private func performInitialSync(
        database: AppDatabase,
        initialScript: FakeIMAPSession.Script
    ) async throws -> AccountRecord {
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: initialScript)
        }
        _ = try await syncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))
        return account
    }

    // MARK: (a) new mail

    @Test("incremental sync fetches only the mail that arrived since the last sync")
    func fetchesNewMailOnly() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": [
                    makeEnvelope(uid: 1, subject: "1通目"),
                    makeEnvelope(uid: 2, subject: "2通目"),
                    makeEnvelope(uid: 3, subject: "3通目"),
                ]],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 4, highestModSeq: 0, messageCount: 3)]
            )
        )

        // CONDSTORE reported with an unchanged highestModSeq: the flag-sync
        // step (2) short-circuits to a no-op, isolating this test to just
        // the new-mail step (1) — a script that omits uid 1–3 from its
        // `envelopesByPath` would otherwise also be a valid *non*-CONDSTORE
        // "everything except uid 1–3 is gone" server response, which isn't
        // what this test means to exercise.
        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 4, subject: "新着4通目")]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 5, highestModSeq: 0, messageCount: 4)],
            capabilitiesToReport: [.condstore]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        let progress = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        #expect(progress.newMessages == 1)
        #expect(progress.didFullResync == false)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.count == 4)
        #expect(messages.contains { $0.subject == "新着4通目" })
    }

    // MARK: (b) flag sync — CONDSTORE and non-CONDSTORE

    @Test("CONDSTORE flag sync applies a changedSince flag change without re-fetching everything")
    func condstoreFlagSync() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": [makeEnvelope(uid: 1, subject: "既読フラグ変更前")]],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 5, messageCount: 1)]
            )
        )

        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            // No new mail (uidNext unchanged); the fetchEnvelopes(uids:)
            // path shouldn't be consulted at all for this test's flag
            // change, only fetchEnvelopes(changedSince:).
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 9, messageCount: 1)],
            capabilitiesToReport: [.condstore],
            changedSinceEnvelopesByPath: ["INBOX": [makeEnvelope(uid: 1, subject: "既読フラグ変更前", flags: .seen)]]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        let progress = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        #expect(progress.flagChanges == 1)
        #expect(progress.newMessages == 0)

        let message = try #require(try await database.dbWriter.read { db in try MessageRecord.fetchOne(db) })
        #expect(message.flags.contains(.seen))

        let mailbox = try #require(try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db) })
        #expect(mailbox.highestModSeq == 9)
    }

    @Test("non-CONDSTORE flag sync re-fetches the synced window, applies flag changes, and deletes vanished UIDs")
    func nonCondstoreFlagSyncAndDeletion() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": [
                    makeEnvelope(uid: 1, subject: "1通目"),
                    makeEnvelope(uid: 2, subject: "2通目（後で消える）"),
                    makeEnvelope(uid: 3, subject: "3通目"),
                ]],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 4, highestModSeq: 0, messageCount: 3)]
            )
        )

        // uid 2 no longer comes back from the server (expunged elsewhere);
        // uid 1 now has \Seen. No CONDSTORE capability reported, so
        // MailboxSyncer must fall back to the full-window refetch-and-diff.
        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": [
                makeEnvelope(uid: 1, subject: "1通目", flags: .seen),
                makeEnvelope(uid: 3, subject: "3通目"),
            ]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 4, highestModSeq: 0, messageCount: 2)],
            capabilitiesToReport: []
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        let progress = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        #expect(progress.deletedMessages == 1)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db).sorted { $0.uid < $1.uid } }
        #expect(messages.map(\.uid) == [1, 3])
        #expect(messages[0].flags.contains(.seen))
    }

    @Test("non-CONDSTORE flag sync does not mass-delete when the refetch comes back empty but the mailbox still reports messages")
    func nonCondstoreFlagSyncDoesNotMassDeleteOnEmptyRefetch() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": [
                    makeEnvelope(uid: 1, subject: "1通目"),
                    makeEnvelope(uid: 2, subject: "2通目"),
                    makeEnvelope(uid: 3, subject: "3通目"),
                ]],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 4, highestModSeq: 0, messageCount: 3)]
            )
        )

        // Real-device follow-up (docs/verify.md's "実機バグ: メッセージ一覧が
        // 起動ごとに出たり出なかったりする"): a degraded/partial round trip on
        // a flaky connection can come back with zero envelopes without
        // throwing, even though the mailbox is plainly not empty (STATUS
        // still reports 3 messages) — this must not be read as "every
        // locally-known UID was expunged".
        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": []],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 4, highestModSeq: 0, messageCount: 3)],
            capabilitiesToReport: []
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        let progress = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        #expect(progress.deletedMessages == 0)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db).sorted { $0.uid < $1.uid } }
        #expect(messages.map(\.uid) == [1, 2, 3])

        // The still-threaded messages must still be reachable via
        // `ThreadQuery` too, not just present as orphaned `message` rows —
        // this is exactly the "data is in the DB but the list renders
        // empty" symptom the bug report describes.
        let threadedCount = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("threadId") != nil).fetchCount(db)
        }
        #expect(threadedCount == 3)
    }

    // MARK: (c) uidValidity change

    @Test("a uidValidity change discards local messages and re-syncs the recent window from scratch")
    func uidValidityChangeTriggersFullResync() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": [
                    makeEnvelope(uid: 1, subject: "旧世代1"),
                    makeEnvelope(uid: 2, subject: "旧世代2"),
                ]],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 3, highestModSeq: 0, messageCount: 2)]
            )
        )

        // The mailbox was recreated server-side: uidValidity bumped, and
        // UID 1 under the new epoch is an unrelated message.
        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 1, subject: "新世代1")]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 2, uidNext: 2, highestModSeq: 0, messageCount: 1)]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        let progress = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        #expect(progress.didFullResync == true)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.count == 1)
        #expect(messages.first?.subject == "新世代1")

        let mailbox = try #require(try await database.dbWriter.read { db in
            try MailboxRecord.filter(Column("accountId") == account.id).fetchOne(db)
        })
        #expect(mailbox.uidValidity == 2)
    }
}
