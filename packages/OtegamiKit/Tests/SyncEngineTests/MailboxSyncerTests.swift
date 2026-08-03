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

    /// docs/architecture.md's Known pitfalls (d): an open-ended `UIDRange`
    /// (`upperBound == nil`) is never chunked by `MailCoreIMAPSession
    /// .chunk`, so a naive "new mail since `newMailLowerBound`" fetch that
    /// leaves the upper bound open issues one unbounded `FETCH` regardless
    /// of `batchSize`. This asserts the new-mail step instead bounds the
    /// request to `status.uidNext - 1` (this pass's own just-fetched
    /// server-reported upper limit) — `FakeIMAPSession.fetchedRanges`
    /// records the exact range `MailboxSyncer` asked for.
    @Test("incremental sync bounds the new-mail fetch to status.uidNext - 1 rather than leaving it open-ended")
    func newMailFetchIsBounded() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": [makeEnvelope(uid: 1, subject: "1通目")]],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1)]
            )
        )

        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": [
                makeEnvelope(uid: 1, subject: "1通目"),
                makeEnvelope(uid: 2, subject: "新着2通目"),
            ]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 3, highestModSeq: 0, messageCount: 2)],
            capabilitiesToReport: [.condstore]
        )
        let sessionBox = SessionBox()
        let syncer = AccountSyncer(account: account, database: database) { config in
            let session = FakeIMAPSession(config: config, script: incrementalScript)
            sessionBox.session = session
            return session
        }
        let progress = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        #expect(progress.newMessages == 1)

        let fetchedRanges = await sessionBox.session?.fetchedRanges ?? []
        #expect(fetchedRanges.count == 1)
        #expect(fetchedRanges[0].lowerBound == 2)
        #expect(fetchedRanges[0].upperBound == 2, "must be bounded to status.uidNext - 1, never open-ended")
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

    // MARK: (b') Task #79 — CONDSTORE-path vanished-message detection
    // (実機バグ: Web でアーカイブ済みのメールが受信トレイに残り続ける)

    @Test("CONDSTORE flag sync deletes messages QRESYNC reports as vanished, without a fallback UID SEARCH")
    func condstoreQresyncVanishedDeletesMessages() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": [
                    makeEnvelope(uid: 1, subject: "1通目"),
                    makeEnvelope(uid: 2, subject: "2通目（他クライアントでアーカイブされる）"),
                    makeEnvelope(uid: 3, subject: "3通目"),
                ]],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 4, highestModSeq: 5, messageCount: 3)]
            )
        )

        // A QRESYNC-capable server reports uid 2 as vanished directly in
        // its `changedSince` response — `existingUIDsByPath` is
        // deliberately left unscripted (and would report "everything
        // vanished" if consulted) to prove the fallback UID SEARCH is never
        // reached when QRESYNC already answered the question.
        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 4, highestModSeq: 9, messageCount: 2)],
            capabilitiesToReport: [.condstore, .qresync],
            qresyncVanishedUIDsByPath: ["INBOX": [2]]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        let progress = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        #expect(progress.deletedMessages == 1)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db).sorted { $0.uid < $1.uid } }
        #expect(messages.map(\.uid) == [1, 3])
    }

    @Test("CONDSTORE flag sync falls back to a UID SEARCH to detect vanished messages when the server doesn't support QRESYNC (Gmail's case)")
    func condstoreFallbackUIDSearchDetectsVanishedMessages() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": [
                    makeEnvelope(uid: 1, subject: "1通目"),
                    makeEnvelope(uid: 2, subject: "2通目（Web でアーカイブされる）"),
                    makeEnvelope(uid: 3, subject: "3通目"),
                ]],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 4, highestModSeq: 5, messageCount: 3)]
            )
        )

        // Gmail-shaped server: CONDSTORE only, no QRESYNC. Another client
        // (the Gmail web UI) archived uid 2 — INBOX's own EXPUNGE removes
        // it from this mailbox entirely. `changedSinceEnvelopesByPath` is
        // left unscripted (uid 1/3's flags didn't change), so this test
        // isolates the vanished-detection fallback from the flag-sync half
        // of step 2.
        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 4, highestModSeq: 9, messageCount: 2)],
            capabilitiesToReport: [.condstore],
            existingUIDsByPath: ["INBOX": [1, 3]]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        let progress = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        #expect(progress.deletedMessages == 1)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db).sorted { $0.uid < $1.uid } }
        #expect(messages.map(\.uid) == [1, 3])

        // Reachable via ThreadQuery too, not just gone from `message` — the
        // surviving messages' thread aggregates must have settled, not just
        // uid 2's own row disappearing.
        let threadedCount = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("threadId") != nil).fetchCount(db)
        }
        #expect(threadedCount == 2)
    }

    @Test("CONDSTORE fallback UID SEARCH does not mass-delete when the search comes back empty but the mailbox still reports messages")
    func condstoreFallbackDoesNotMassDeleteOnEmptySearch() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": [
                    makeEnvelope(uid: 1, subject: "1通目"),
                    makeEnvelope(uid: 2, subject: "2通目"),
                ]],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 3, highestModSeq: 5, messageCount: 2)]
            )
        )

        // A degraded/partial UID SEARCH round trip can come back with no
        // matches at all without throwing, even though STATUS still reports
        // 2 messages — same non-destructive guard as
        // `nonCondstoreFlagSyncDoesNotMassDeleteOnEmptyRefetch`, just for
        // the CONDSTORE-path fallback.
        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 3, highestModSeq: 9, messageCount: 2)],
            capabilitiesToReport: [.condstore],
            existingUIDsByPath: ["INBOX": []]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        let progress = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        #expect(progress.deletedMessages == 0)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db).sorted { $0.uid < $1.uid } }
        #expect(messages.map(\.uid) == [1, 2])
    }

    @Test("CONDSTORE fallback UID SEARCH failing deletes nothing for that mailbox (AccountSyncer's per-mailbox catch skips it)")
    func condstoreFallbackSearchFailureDeletesNothing() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": [makeEnvelope(uid: 1, subject: "1通目")]],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 5, messageCount: 1)]
            )
        )

        // `searchExistingUIDs` throwing (a dropped/timed-out UID SEARCH)
        // must be exactly as non-destructive as a thrown
        // `fetchEnvelopes(uids:)` already is on the non-CONDSTORE path
        // (`refetchAndDiffFlags`'s doc comment): `AccountSyncer
        // .performIncrementalSync`'s per-mailbox `do`/`catch` swallows it
        // and moves on, so the whole call doesn't throw — but crucially,
        // nothing gets deleted either.
        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 9, messageCount: 1)],
            capabilitiesToReport: [.condstore],
            failSearchExistingUIDs: .connectionFailed(underlyingDescription: "simulated dropped connection")
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        let progress = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        #expect(progress.deletedMessages == 0)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.count == 1)
    }

    // MARK: (b'') Task #83 — real-device follow-up: `highestModSeq` staying
    // put is not proof nothing was expunged (実機バグ: Spark/Gmail Web で
    // アーカイブ済みのメールが Otegami の受信箱に残り続ける、
    // pull-to-refresh でも消えない)

    @Test("STATUS completely unchanged (uidNext/highestModSeq/messageCount all identical) still detects a server-side vanished message when forceReconcileVanishedUIDs is true")
    func forceReconcileDetectsVanishedMessageDespiteUnchangedStatus() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": [
                    makeEnvelope(uid: 1, subject: "1通目"),
                    makeEnvelope(uid: 2, subject: "2通目（Spark でアーカイブ、Gmail 側の modSeq は進まない）"),
                    makeEnvelope(uid: 3, subject: "3通目"),
                ]],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 4, highestModSeq: 5, messageCount: 3)]
            )
        )

        // The real-device gap this reproduces: a Gmail-shaped server
        // (CONDSTORE, no QRESYNC) that reports the *exact same*
        // uidValidity/uidNext/highestModSeq/messageCount as last time even
        // though another client expunged uid 2 in between — before this
        // fix, `incrementalSync`'s `if status.highestModSeq >
        // mailboxRecord.highestModSeq` guard kept this scenario from ever
        // reaching `detectAndRemoveVanishedByUIDSearch` at all (Task #79's
        // own fallback), so the message never got noticed as gone no matter
        // how many times pull-to-refresh ran.
        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 4, highestModSeq: 5, messageCount: 3)],
            capabilitiesToReport: [.condstore],
            existingUIDsByPath: ["INBOX": [1, 3]]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }

        // Without the fix's opt-in, this is exactly the bug: the modSeq-gated
        // guard never runs the vanished-UID check, so nothing is deleted.
        let unforcedProgress = try await syncer.performIncrementalSync(
            auth: .password(username: "test1@otegami.test", password: "test1234")
        )
        #expect(unforcedProgress.deletedMessages == 0)
        let stillPresent = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db).sorted { $0.uid < $1.uid } }
        #expect(stillPresent.map(\.uid) == [1, 2, 3])

        // `forceReconcileVanishedUIDs: true` — what `MessageListView`'s
        // pull-to-refresh and its 5-minute mailbox-display auto-resync both
        // now pass — runs the UID SEARCH reconciliation unconditionally and
        // finally notices uid 2 is gone.
        let forcedProgress = try await syncer.performIncrementalSync(
            auth: .password(username: "test1@otegami.test", password: "test1234"),
            forceReconcileVanishedUIDs: true
        )
        #expect(forcedProgress.deletedMessages == 1)
        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db).sorted { $0.uid < $1.uid } }
        #expect(messages.map(\.uid) == [1, 3])
    }

    // MARK: (c) uidValidity change

    /// Task #167 / F13 (`CLAUDE-SECURITY-20260729-134850/CLAUDE-SECURITY-RESULTS.md`):
    /// a hostile/compromised IMAP server's `SELECT` response can report a
    /// `HIGHESTMODSEQ` above `Int64.max` — `Int64(status.highestModSeq)`
    /// used to trap-crash the process on every incremental sync of that
    /// mailbox. `Int64(clamping:)` must instead store `Int64.max` and let
    /// the sync pass complete normally (step 3, the mailbox-metadata write
    /// this exercises).
    @Test("incremental sync clamps a server-reported HIGHESTMODSEQ above Int64.max instead of crashing")
    func incrementalSyncClampsOversizedHighestModSeq() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": [makeEnvelope(uid: 1, subject: "1通目")]],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1)]
            )
        )

        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: UInt64.max, messageCount: 1)],
            capabilitiesToReport: [.condstore],
            changedSinceEnvelopesByPath: ["INBOX": []]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        _ = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        let mailbox = try #require(try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db) })
        #expect(mailbox.highestModSeq == Int64.max)
    }

    /// Same as `incrementalSyncClampsOversizedHighestModSeq` above, but for
    /// `performWindowedResync` (the uidValidity-changed/never-synced path),
    /// which has its own separate `Int64(status.highestModSeq)` call site.
    @Test("a uidValidity-changed resync clamps a server-reported HIGHESTMODSEQ above Int64.max instead of crashing")
    func windowedResyncClampsOversizedHighestModSeq() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": [makeEnvelope(uid: 1, subject: "旧世代1")]],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1)]
            )
        )

        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 1, subject: "新世代1")]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 2, uidNext: 2, highestModSeq: UInt64.max, messageCount: 1)]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        let progress = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))
        #expect(progress.didFullResync == true)

        let mailbox = try #require(try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db) })
        #expect(mailbox.highestModSeq == Int64.max)
    }

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

    /// Same shape as `AccountSyncerTests.fetchesSparseOldUIDBand`, but for
    /// `performWindowedResync` — the uidValidity-changed/never-synced path
    /// this method also drives, and which shares the exact "most recent
    /// window" fetch this bug affected (docs/verify.md, "実機バグ調査: 疎な
    /// UID 帯を持つメールボックスで初期同期が0通になる").
    @Test("a uidValidity-changed resync still finds a mailbox's current messages in a sparse, far-from-uidNext UID band")
    func uidValidityChangeResyncFindsSparseOldUIDBand() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": [makeEnvelope(uid: 1, subject: "旧世代1")]],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1)]
            )
        )

        // uidValidity bumped (recreated mailbox), and under the new epoch
        // the server has processed thousands of messages historically but
        // currently holds only 3, at old UIDs far from both `1` and
        // `uidNext`.
        let survivingUIDs: [UInt32] = [1990, 1991, 1992]
        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": survivingUIDs.map { makeEnvelope(uid: $0, subject: "新世代-\($0)") }],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 2, uidNext: 4000, highestModSeq: 0, messageCount: survivingUIDs.count)]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        let progress = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        #expect(progress.didFullResync == true)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.count == survivingUIDs.count)
    }

    // MARK: Drafts IMAP sync — SyncScope.inboxOnly also covers Drafts

    @Test("the default .inboxOnly scope also differentially syncs the account's Drafts mailbox")
    func inboxOnlyScopeAlsoSyncsDrafts() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let drafts = MailboxInfo(path: "Drafts", displayPath: "Drafts", role: .drafts, attributes: [])

        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox, drafts],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "Drafts": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                ]
            )
        )

        // A draft appears in Drafts server-side (another client saved one)
        // between the initial sync above and this incremental pass — no
        // explicit `scope:` argument, exercising `performIncrementalSync`'s
        // default (`.inboxOnly`).
        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox, drafts],
            envelopesByPath: ["Drafts": [makeEnvelope(uid: 1, subject: "他クライアントの下書き")]],
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                "Drafts": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1),
            ]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        _ = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.contains { $0.subject == "他クライアントの下書き" })
    }

    // MARK: (c) Task #194 — chunked flags-only refetch, progress, cancellation

    /// Thread-safe recorder for `onProgress` updates — mirrors
    /// `FakeIMAPSession.CallRecorder`'s `NSLock`-based shape (an `actor`
    /// would need every recording call to become `async`, which `onProgress`
    /// — a plain `@Sendable (SyncProgressUpdate) -> Void` closure, called
    /// synchronously from inside `MailboxSyncer`'s actor-isolated work —
    /// can't do without an awkward fire-and-forget `Task` per update).
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _updates: [MailboxSyncer.SyncProgressUpdate] = []
        func record(_ update: MailboxSyncer.SyncProgressUpdate) {
            lock.lock()
            _updates.append(update)
            lock.unlock()
        }
        var updates: [MailboxSyncer.SyncProgressUpdate] {
            lock.lock()
            defer { lock.unlock() }
            return _updates
        }
    }

    /// Same `SessionBox` shape `MessageBodiesPrefetchTests` uses to inspect
    /// the `FakeIMAPSession` a session-factory closure actually built, after
    /// the sync call that used it has already returned.
    private final class SessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _session: FakeIMAPSession?
        var session: FakeIMAPSession? {
            get { lock.withLock { _session } }
            set { lock.withLock { _session = newValue } }
        }
    }

    @Test("non-CONDSTORE flag sync chunks a window larger than fetchBatchSize instead of one unbounded fetch, and still applies changes/deletions correctly across the chunk boundary")
    func nonCondstoreFlagSyncChunksLargeWindow() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        // 150 locally-known UIDs: more than `AccountSyncer.fetchBatchSize`
        // (100), so a correct chunking implementation issues 2 `fetchFlags`
        // calls (1...100, 101...150) rather than the old un-chunked
        // implementation's single open-ended fetch.
        let seedEnvelopes = (1...150).map { makeEnvelope(uid: UInt32($0), subject: "msg \($0)") }
        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": seedEnvelopes],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 151, highestModSeq: 0, messageCount: 150)]
            )
        )

        // uid 75 (first chunk) gains \Seen; uid 150 (second chunk) vanishes
        // server-side — exercises both the flag-change and deletion paths
        // on either side of the chunk boundary in one pass.
        var serverEnvelopes = seedEnvelopes.filter { $0.uid != 150 }
        let changedIndex = serverEnvelopes.firstIndex { $0.uid == 75 }!
        serverEnvelopes[changedIndex].flags = .seen
        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": serverEnvelopes],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 151, highestModSeq: 0, messageCount: 149)],
            capabilitiesToReport: []
        )

        let sessionBox = SessionBox()
        let syncer = AccountSyncer(account: account, database: database) { config in
            let session = FakeIMAPSession(config: config, script: incrementalScript)
            sessionBox.session = session
            return session
        }
        let progress = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        #expect(progress.deletedMessages == 1)

        let fetchFlagsCalls = await sessionBox.session?.fetchFlagsCalls ?? []
        #expect(fetchFlagsCalls.count == 2)
        #expect(fetchFlagsCalls[0].lowerBound == 1)
        #expect(fetchFlagsCalls[0].upperBound == 100)
        #expect(fetchFlagsCalls[1].lowerBound == 101)
        #expect(fetchFlagsCalls[1].upperBound == 150)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.count == 149)
        #expect(!messages.contains { $0.uid == 150 })
        #expect(messages.first { $0.uid == 75 }?.flags.contains(.seen) == true)
    }

    @Test("non-CONDSTORE flag sync chunks a sparse UID space by count of locally-known UIDs, not by numeric span")
    func nonCondstoreFlagSyncChunksSparseUIDSpaceByCount() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        // 150 locally-known UIDs spaced 1000 apart (a Gmail-shaped mailbox
        // with a huge numeric UID span but few surviving messages, e.g.
        // after heavy archiving/expunging elsewhere) — spans ~150,000 UIDs.
        // Chunking by *numeric range* at `fetchBatchSize` (100) would slice
        // this into ~1,500 mostly-empty range chunks; chunking by *count* of
        // the actual known UIDs must still produce exactly 2 chunks (100 +
        // 50), the same as a dense window this size would.
        let sparseUIDs: [UInt32] = (1...150).map { UInt32($0) * 1000 }
        let seedEnvelopes = sparseUIDs.map { makeEnvelope(uid: $0, subject: "msg \($0)") }
        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": seedEnvelopes],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 150_001, highestModSeq: 0, messageCount: 150)]
            )
        )

        // Nothing changed server-side — isolates this test to just the
        // chunking shape, not flag-change/deletion handling (already
        // covered by `nonCondstoreFlagSyncChunksLargeWindow`).
        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": seedEnvelopes],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 150_001, highestModSeq: 0, messageCount: 150)],
            capabilitiesToReport: []
        )
        let sessionBox = SessionBox()
        let syncer = AccountSyncer(account: account, database: database) { config in
            let session = FakeIMAPSession(config: config, script: incrementalScript)
            sessionBox.session = session
            return session
        }
        let progress = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        #expect(progress.deletedMessages == 0)

        let setCalls = await sessionBox.session?.fetchFlagsSetCalls ?? []
        #expect(setCalls.count == 2, "must chunk by count of known UIDs, not by numeric span")
        #expect(setCalls[0].uids.count == 100)
        #expect(setCalls[1].uids.count == 50)
        #expect(Set(setCalls[0].uids + setCalls[1].uids) == Set(sparseUIDs))
    }

    @Test("non-CONDSTORE flag sync reports .flagSync progress once per chunk, with an accurate total")
    func nonCondstoreFlagSyncReportsProgress() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        let seedEnvelopes = (1...150).map { makeEnvelope(uid: UInt32($0), subject: "msg \($0)") }
        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": seedEnvelopes],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 151, highestModSeq: 0, messageCount: 150)]
            )
        )

        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": seedEnvelopes],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 151, highestModSeq: 0, messageCount: 150)],
            capabilitiesToReport: []
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        let recorder = ProgressRecorder()
        _ = try await syncer.performIncrementalSync(
            auth: .password(username: "test1@otegami.test", password: "test1234"),
            onProgress: { recorder.record($0) }
        )

        let flagSyncUpdates = recorder.updates.filter { $0.phase == .flagSync }
        #expect(flagSyncUpdates.map(\.completed) == [1, 2])
        #expect(flagSyncUpdates.allSatisfy { $0.total == 2 })
        #expect(flagSyncUpdates.allSatisfy { $0.mailboxPath == "INBOX" })
    }

    @Test("cancelling mid-flag-sync leaves already-applied chunks committed but skips vanished-UID deletion entirely")
    func nonCondstoreFlagSyncCancellationIsSafe() async throws {
        let database = try AppDatabase.makeInMemory()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

        let seedEnvelopes = (1...150).map { makeEnvelope(uid: UInt32($0), subject: "msg \($0)") }
        let account = try await performInitialSync(
            database: database,
            initialScript: FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": seedEnvelopes],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 151, highestModSeq: 0, messageCount: 150)]
            )
        )

        // uid 25 (first chunk) gains \Seen; uid 150 (second chunk) vanishes
        // server-side. The test cancels right after the *first* chunk's
        // progress update — before the second chunk (and thus the vanished-
        // UID inference, which needs every chunk) ever runs.
        var serverEnvelopes = seedEnvelopes.filter { $0.uid != 150 }
        let changedIndex = serverEnvelopes.firstIndex { $0.uid == 25 }!
        serverEnvelopes[changedIndex].flags = .seen
        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": serverEnvelopes],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 151, highestModSeq: 0, messageCount: 149)],
            capabilitiesToReport: []
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }

        final class CancelTrigger: @unchecked Sendable {
            private let lock = NSLock()
            private var _cancel: (() -> Void)?
            func arm(_ cancel: @escaping () -> Void) { lock.withLock { _cancel = cancel } }
            func fire() { lock.withLock { _cancel }?() }
        }
        let trigger = CancelTrigger()

        let task = Task {
            try await syncer.performIncrementalSync(
                auth: .password(username: "test1@otegami.test", password: "test1234"),
                onProgress: { update in
                    if update.phase == .flagSync, update.completed == 1 {
                        trigger.fire()
                    }
                }
            )
        }
        trigger.arm { task.cancel() }

        do {
            _ = try await task.value
            Issue.record("expected the cancelled sync to throw")
        } catch is CancellationError {
            // Expected — Task #194's cooperative cancellation.
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }

        // The first chunk's flag change committed before cancellation was
        // even observed (progress is only reported after a chunk's write
        // lands — see `MailboxSyncer.refetchAndDiffFlags`'s doc comment).
        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.count == 150, "cancellation must not delete anything — the full window was never confirmed")
        #expect(messages.first { $0.uid == 25 }?.flags.contains(.seen) == true)
        // uid 150 is still present: the second chunk (which would have
        // discovered it missing) never ran, and a partial result must never
        // be trusted as "confirmed vanished".
        #expect(messages.contains { $0.uid == 150 })
    }
}
