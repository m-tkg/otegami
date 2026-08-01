import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

@Suite("AccountSyncer initial sync — incremental sync behaviors")
struct AccountSyncerIncrementalTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Test",
            email: "test1@otegami.test",
            authType: .password,
            imapHost: "localhost",
            imapPort: 1143,
            imapSecurity: .plain,
            imapUsername: "test1@otegami.test"
        )
    }

    private func makeInbox(uid: UInt32, subject: String, references: [String] = []) -> FetchedEnvelope {
        FetchedEnvelope(
            uid: uid,
            messageId: "<seed-\(uid)@otegami.test>",
            inReplyTo: references.last,
            references: references,
            subject: subject,
            from: [EmailAddress(name: "Aiko", address: "aiko@otegami.test")],
            to: [EmailAddress(address: "test1@otegami.test")],
            cc: [],
            bcc: [],
            replyTo: [],
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            internalDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            flags: [],
            size: 512
        )
    }

    // MARK: - Account-level connect failure (account edit UI)

    /// `AccountRecord.lastSyncError`'s doc comment: a wrong password (the
    /// account-edit "save a bad password, see it fail visibly" flow) fails
    /// at `connect()`, before any mailbox is even selected — this must
    /// surface on the `account` row itself, not just (as
    /// `MailboxRecord.lastSyncError` alone would give) silently nowhere.
    @Test("a connect failure records itself on the account row")
    func connectFailureRecordsAccountLevelSyncError() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let script = FakeIMAPSession.Script(failConnection: .authenticationFailed(underlyingDescription: "bad password"))
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: script)
        }

        await #expect(throws: (any Error).self) {
            try await syncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "wrong"))
        }

        let row = try #require(
            try await database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) }
        )
        #expect(row.lastSyncError != nil)
        #expect(row.lastSyncErrorAt != nil)
    }

    @Test("an account-level connect failure clears itself once a later sync connects successfully")
    func connectFailureClearsOnNextSuccess() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let failingScript = FakeIMAPSession.Script(failConnection: .authenticationFailed(underlyingDescription: "bad password"))
        let firstSyncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: failingScript)
        }
        await #expect(throws: (any Error).self) {
            try await firstSyncer.performInitialSync(auth: auth)
        }
        let afterFailure = try #require(
            try await database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) }
        )
        #expect(afterFailure.lastSyncError != nil)

        // A fresh `AccountSyncer` isn't required for the fix to take
        // effect (in the real app it wouldn't be reused either — see
        // `SyncCoordinator.invalidateSyncer(for:)`'s doc comment — but this
        // test only cares about `AccountSyncer`'s own recover-on-success
        // behavior, independent of that).
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let succeedingScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0)]
        )
        let secondSyncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: succeedingScript)
        }
        _ = try await secondSyncer.performInitialSync(auth: auth)

        let afterRecovery = try #require(
            try await database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) }
        )
        #expect(afterRecovery.lastSyncError == nil)
        #expect(afterRecovery.lastSyncErrorAt == nil)
    }

    // MARK: - メールボックス単位の非表示

    /// A full manual refresh (`.all`) must skip a hidden mailbox — see
    /// `MailboxRecord.isHidden`'s doc comment ("同期も止める", battery/
    /// network cost). `.inboxOnly` isn't covered here since it only ever
    /// targets INBOX/Drafts regardless of any mailbox's `isHidden`.
    @Test(".all scope skips a hidden mailbox but still syncs a visible one")
    func allScopeSkipsHiddenMailbox() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let archive = MailboxInfo(path: "Archive", displayPath: "Archive", role: .archive, attributes: [])

        let initialSyncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inbox, archive],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "Archive": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                ]
            ))
        }
        _ = try await initialSyncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        let archiveMailboxId = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "Archive").fetchOne(db)?.id
            }
        )
        try await database.dbWriter.write { db in
            try MailboxQuery.setHidden(mailboxId: archiveMailboxId, hidden: true, db: db)
        }

        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox, archive],
            envelopesByPath: [
                "INBOX": [makeInbox(uid: 1, subject: "INBOX新着")],
                "Archive": [makeInbox(uid: 1, subject: "Archive新着")],
            ],
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1),
                "Archive": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1),
            ]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        _ = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"), scope: .all)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.contains { $0.subject == "INBOX新着" }, "Visible mailbox should still be synced by .all")
        #expect(!messages.contains { $0.subject == "Archive新着" }, "Hidden mailbox must be skipped by .all")

        // The hidden mailbox's own row still got re-listed/upserted (it's
        // not simply absent from `mailbox`) — just excluded from the sync
        // *targets*. `isHidden` itself must have survived that re-upsert.
        let archiveAfter = try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: archiveMailboxId) }
        #expect(archiveAfter?.isHidden == true)
    }

    /// `AccountSyncer.upsertMailboxes` runs on *every* sync pass (initial,
    /// incremental, IDLE-triggered), re-listing and re-upserting every
    /// mailbox `IMAP LIST` reports — without `Column("isHidden")
    /// .noOverwrite`, the freshly-constructed `MailboxRecord` (always
    /// `isHidden: false`, since it has no way to know the user's choice)
    /// would silently un-hide a mailbox on its very next sync.
    @Test("a hidden mailbox stays hidden across a later .inboxOnly sync that re-lists it")
    func hiddenMailboxSurvivesResync() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let archive = MailboxInfo(path: "Archive", displayPath: "Archive", role: .archive, attributes: [])

        let initialSyncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inbox, archive],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "Archive": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                ]
            ))
        }
        _ = try await initialSyncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))
        let archiveMailboxId = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "Archive").fetchOne(db)?.id
            }
        )
        try await database.dbWriter.write { db in
            try MailboxQuery.setHidden(mailboxId: archiveMailboxId, hidden: true, db: db)
        }

        // `.inboxOnly` — the frequent/IDLE-wake path — still re-lists every
        // mailbox via `listMailboxes()`/`upsertMailboxes` before narrowing
        // down to its actual sync targets.
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inbox, archive],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "Archive": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                ]
            ))
        }
        _ = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        let archiveAfter = try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: archiveMailboxId) }
        #expect(archiveAfter?.isHidden == true, "A resync must not silently un-hide a mailbox")
    }

    // MARK: - Task #119 (実機報告「その他 → Trash」)

    /// The other half of Task #119's fix: `MailboxRole.inferred(fromDisplayPath:)`
    /// (`packages/OtegamiKit/Sources/MailTransport/MailboxRoleNameInference.swift`)
    /// only fixes mailboxes discovered *after* the fix ships — a mailbox
    /// that was already stored locally with `role == .none` (from before
    /// this app version existed, back when a SPECIAL-USE-less Trash always
    /// fell through to "その他") also needs to self-heal on its own, without
    /// requiring `uidValidity` to change or the user to do anything special.
    /// `upsertMailboxes` (unlike `Column("isHidden").noOverwrite` right
    /// above) deliberately does *not* protect `role` from being overwritten
    /// on every sync pass — this test locks that in: a mailbox stored with
    /// the pre-fix `role: .none` gets corrected to `.trash` the very next
    /// time `performIncrementalSync` re-lists mailboxes, same `uidValidity`
    /// throughout.
    @Test("a locally-stored role is re-evaluated (not frozen) on every later mailbox re-sync")
    func mailboxRoleIsReevaluatedOnResync() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        // Simulates a mailbox this app previously discovered before Task
        // #119's name-based fallback existed: no SPECIAL-USE attribute the
        // old `role(for:path:)` recognized, so it was stored as `.none`.
        let trash = MailboxInfo(path: "Trash", displayPath: "Trash", role: .none, attributes: [])

        let initialSyncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inbox, trash],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "Trash": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                ]
            ))
        }
        _ = try await initialSyncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))
        let trashMailboxId = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "Trash").fetchOne(db)?.id
            }
        )
        let trashBefore = try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: trashMailboxId) }
        // `MailboxRoleRecord.none` explicitly, not bare `.none` — the latter
        // resolves to `Optional<MailboxRoleRecord>.none` (nil) instead of
        // `.some(.none)` in this `T?`-typed comparison, the classic Swift
        // "wrapped type also has a case named `none`" footgun.
        #expect(trashBefore?.role == MailboxRoleRecord.none, "precondition: this test simulates a mailbox stored before the name-based fallback existed")

        // A later sync pass re-lists the same mailbox, this time with the
        // fixed role-inference logic reporting `.trash` — same `uidValidity`
        // (1), so this doesn't take the uidValidity-changed full-resync path
        // at all; it's the ordinary `upsertMailboxes` re-upsert every
        // incremental sync already does.
        let fixedTrash = MailboxInfo(path: "Trash", displayPath: "Trash", role: .trash, attributes: [])
        let resyncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inbox, fixedTrash],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "Trash": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                ]
            ))
        }
        _ = try await resyncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        let trashAfter = try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: trashMailboxId) }
        #expect(trashAfter?.role == .trash, "a stale locally-stored role must be corrected by the next mailbox re-sync, not frozen at its first-ever value")
    }

    // MARK: - Task #154 (実機報告: ハンバーガーメニューのゴミ箱カテゴリに Gmail が2行出る)

    /// Locks in the #154 root fix: a server that already advertises
    /// SPECIAL-USE `\Trash` for one mailbox (`roleIsAuthoritative: true`)
    /// must not also let a *different*, literally "Trash"-named mailbox in
    /// the same account keep `role == .trash` from #119's name-guess
    /// fallback (`roleIsAuthoritative: false`) — `AccountSyncer
    /// .upsertMailboxes` downgrades the non-authoritative duplicate to
    /// `.none` before either ever reaches the `mailbox` table, so the
    /// hamburger menu's role-based category section only ever shows one row
    /// for this account's ゴミ箱.
    @Test("a name-guessed role duplicate is downgraded to .none when this account already has an authoritative mailbox with the same role")
    func duplicateNameGuessedRoleIsDowngraded() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [], roleIsAuthoritative: true)
        // SPECIAL-USE `\Trash` — the account's real, server-designated Trash.
        let specialUseTrash = MailboxInfo(
            path: "[Gmail]/Trash", displayPath: "[Gmail]/ゴミ箱", role: .trash, attributes: [], roleIsAuthoritative: true
        )
        // A separate, plain user-visible mailbox that just happens to be
        // named "Trash" — no SPECIAL-USE attribute of its own, resolved to
        // `.trash` only by #119's name-guess fallback.
        let nameGuessedTrash = MailboxInfo(
            path: "Trash", displayPath: "Trash", role: .trash, attributes: [], roleIsAuthoritative: false
        )

        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inbox, specialUseTrash, nameGuessedTrash],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "[Gmail]/Trash": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "Trash": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                ]
            ))
        }
        _ = try await syncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        let mailboxes = try await database.dbWriter.read { db in
            try MailboxRecord.filter(Column("accountId") == account.id).fetchAll(db)
        }
        let specialUseRecord = try #require(mailboxes.first { $0.path == "[Gmail]/Trash" })
        let nameGuessedRecord = try #require(mailboxes.first { $0.path == "Trash" })

        #expect(specialUseRecord.role == .trash)
        #expect(specialUseRecord.roleIsAuthoritative == true)
        #expect(nameGuessedRecord.role == .none, "the name-guessed duplicate must be downgraded, not left duplicating the SPECIAL-USE mailbox's role")
        #expect(nameGuessedRecord.roleIsAuthoritative == false)

        let trashRoleCount = mailboxes.filter { $0.role == .trash }.count
        #expect(trashRoleCount == 1, "exactly one mailbox in this account may carry role == .trash")
    }

    /// Two mailboxes with a SPECIAL-USE-derived (`roleIsAuthoritative: true`)
    /// role for the *same* account are left alone even though it's the same
    /// duplicate-role shape — this shouldn't normally happen (a well-behaved
    /// server never advertises the same SPECIAL-USE attribute twice), but
    /// the downgrade rule only ever targets non-authoritative name guesses,
    /// never another authoritative mailbox, so this locks in that the fix
    /// doesn't overreach.
    @Test("two authoritative mailboxes with the same role are both left untouched")
    func twoAuthoritativeMailboxesWithSameRoleAreNotDowngraded() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [], roleIsAuthoritative: true)
        let trashA = MailboxInfo(path: "TrashA", displayPath: "TrashA", role: .trash, attributes: [], roleIsAuthoritative: true)
        let trashB = MailboxInfo(path: "TrashB", displayPath: "TrashB", role: .trash, attributes: [], roleIsAuthoritative: true)

        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inbox, trashA, trashB],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "TrashA": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "TrashB": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                ]
            ))
        }
        _ = try await syncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        let mailboxes = try await database.dbWriter.read { db in
            try MailboxRecord.filter(Column("accountId") == account.id).fetchAll(db)
        }
        let trashRecords = mailboxes.filter { $0.path == "TrashA" || $0.path == "TrashB" }
        #expect(trashRecords.count == 2)
        #expect(trashRecords.allSatisfy { $0.role == .trash && $0.roleIsAuthoritative })
    }

    // MARK: - Task #44 (実機バグ: Gmail の「すべてのメール」に新着が反映されない)

    /// Locks in the exact scenario from the real-device bug report at the
    /// `FakeIMAPSession` level: a `role: .all` mailbox (what this app maps
    /// Gmail's IMAP `\All` SPECIAL-USE "すべてのメール" to —
    /// `MailCoreIMAPSession+Mapping.role(for:path:displayPath:)`), synced via
    /// `.mailbox(path:)` — exactly what `MessageListView.refresh()`'s
    /// `.mailbox` case (pull-to-refresh, and now also the "開いた時" sync
    /// `MessageListView.syncSelectedMailboxOnAppear()` added) does for a
    /// single selected non-INBOX mailbox — with a real (CONDSTORE-capable)
    /// server response shape, must pick up new mail that arrived after the
    /// last sync. The same shape is also confirmed against a real Dovecot
    /// in `SyncEngineIntegrationTests
    /// .mailboxScopedIncrementalSyncPicksUpNewMailInNonInboxMailbox` — this
    /// test is the fast, no-Docker-required counterpart that keeps running
    /// in `make test`/CI.
    @Test(".mailbox(path:) scope picks up new mail in a role-.all (Gmail \"すべてのメール\") mailbox, CONDSTORE capable")
    func mailboxScopedSyncPicksUpNewMailInAllMailRoleMailbox() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let allMail = MailboxInfo(path: "[Gmail]/All Mail", displayPath: "[Gmail]/すべてのメール", role: .all, attributes: [])

        let initialSyncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inbox, allMail],
                envelopesByPath: [
                    "INBOX": [makeInbox(uid: 1, subject: "INBOX既存")],
                    "[Gmail]/All Mail": [makeInbox(uid: 1, subject: "AllMail既存")],
                ],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 5, messageCount: 1),
                    "[Gmail]/All Mail": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 5, messageCount: 1),
                ],
                capabilitiesToReport: [.condstore]
            ))
        }
        _ = try await initialSyncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        let allMailMailboxId = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "[Gmail]/All Mail").fetchOne(db)?.id
            }
        )

        // New mail lands in INBOX *and* (this app's simulation of Gmail
        // having finished indexing it into the virtual "すべてのメール"
        // view) All Mail — highestModSeq unchanged, isolating this to the
        // new-mail step exactly like `MailboxSyncerTests.fetchesNewMailOnly`.
        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox, allMail],
            envelopesByPath: [
                "INBOX": [makeInbox(uid: 2, subject: "INBOX新着")],
                "[Gmail]/All Mail": [makeInbox(uid: 2, subject: "AllMail新着")],
            ],
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: 3, highestModSeq: 5, messageCount: 2),
                "[Gmail]/All Mail": MailboxStatus(uidValidity: 1, uidNext: 3, highestModSeq: 5, messageCount: 2),
            ],
            capabilitiesToReport: [.condstore]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        // Exactly the scope a sidebar selection of "すべてのメール" (or its
        // pull-to-refresh / 開いた時 sync) uses — *not* `.all`/`.inboxOnly`.
        let progress = try await syncer.performIncrementalSync(
            auth: .password(username: "test1@otegami.test", password: "test1234"),
            scope: .mailbox(path: "[Gmail]/All Mail")
        )
        #expect(progress.newMessages == 1)
        #expect(progress.didFullResync == false)

        let allMailMessages = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == allMailMailboxId).fetchAll(db)
        }
        #expect(allMailMessages.count == 2, "the new All Mail message must be picked up even though INBOX wasn't in scope")
        #expect(allMailMessages.contains { $0.subject == "AllMail新着" })

        // `.mailbox(path:)` must not have touched INBOX at all (out of
        // scope) — confirms this test's scoping actually exercised the
        // single-mailbox path, not a broader one.
        let inboxMailboxId = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "INBOX").fetchOne(db)?.id
            }
        )
        let inboxMessages = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == inboxMailboxId).fetchAll(db)
        }
        #expect(inboxMessages.count == 1, "INBOX must be untouched by a .mailbox(path:) scope targeting a different mailbox")
    }
}
