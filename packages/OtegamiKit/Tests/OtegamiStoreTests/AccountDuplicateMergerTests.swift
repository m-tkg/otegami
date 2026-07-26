import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// Regression coverage for `docs/icloud-sync.md`'s "重複挿入バグ" migration:
/// `AccountDuplicateMerger` consolidates already-local duplicate `account`
/// rows for the same real mailbox (the state a device ends up in after the
/// pre-fix `AccountCloudSyncEngine.reconcile()` inserted a cloud-synced
/// duplicate of an account this device already had) without losing any
/// local-only data.
@Suite("AccountDuplicateMerger")
struct AccountDuplicateMergerTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeAccount(
        id: String, needsReauth: Bool = false, createdAt: Date? = nil,
        email: String = "test1@otegami.test", imapHost: String = "imap.otegami.test"
    ) -> AccountRecord {
        AccountRecord(
            id: id,
            displayName: "Test1 (\(id))",
            email: email,
            authType: .password,
            needsReauth: needsReauth,
            imapHost: imapHost,
            imapPort: 993,
            imapSecurity: .tls,
            imapUsername: email,
            createdAt: createdAt ?? epoch
        )
    }

    @Test("no-op when there are no duplicate identities")
    func noDuplicatesIsANoOp() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.write { db in
            try makeAccount(id: "a", email: "a@otegami.test").insert(db)
            try makeAccount(id: "b", email: "b@otegami.test").insert(db)
        }

        let results = try database.dbWriter.write { db in try AccountDuplicateMerger.mergeDuplicateAccounts(db: db) }

        #expect(results.isEmpty)
        let remaining = try database.dbWriter.read { db in try AccountRecord.fetchAll(db) }
        #expect(remaining.count == 2)
    }

    /// The core repro: a real local account (working credential, already has
    /// mail synced) plus the exact duplicate the pre-fix reconcile bug
    /// inserted (`needsReauth == true`, no credential ever found on this
    /// device). The `needsReauth` one must lose, the real one must survive
    /// with all its mail intact, and the loser row must be gone afterward.
    @Test("keeps the account that has a working credential (needsReauth == false) as survivor")
    func survivorIsTheAccountWithoutNeedsReauth() throws {
        let database = try AppDatabase.makeInMemory()
        let real = makeAccount(id: "real-uuid", needsReauth: false)
        let duplicate = makeAccount(id: "duplicate-uuid", needsReauth: true)
        var mailboxId: Int64 = 0
        try database.dbWriter.write { db in
            try real.insert(db)
            try duplicate.insert(db)
            var mailbox = MailboxRecord(accountId: real.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            mailboxId = mailbox.id!
            var message = MessageRecord(mailboxId: mailboxId, uid: 1, subject: "Hello", internalDate: epoch)
            try message.insert(db)
        }

        let results = try database.dbWriter.write { db in try AccountDuplicateMerger.mergeDuplicateAccounts(db: db) }

        #expect(results == [.init(survivorAccountId: "real-uuid", mergedAccountIds: ["duplicate-uuid"])])
        let remaining = try database.dbWriter.read { db in try AccountRecord.fetchAll(db) }
        #expect(remaining.map(\.id) == ["real-uuid"])
        let messages = try database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.count == 1)
        #expect(messages.first?.subject == "Hello")
    }

    /// A loser mailbox whose `path` the survivor doesn't already have
    /// (e.g. the duplicate account happened to sync a Sent folder the
    /// survivor's own initial sync hadn't reached yet) must be adopted
    /// wholesale — its messages are not duplicates of anything, so nothing
    /// about them should be touched beyond re-parenting to the survivor.
    @Test("repoints a non-colliding loser mailbox wholesale, preserving its messages")
    func repointsNonCollidingMailboxWholesale() throws {
        let database = try AppDatabase.makeInMemory()
        let survivor = makeAccount(id: "survivor", needsReauth: false)
        let loser = makeAccount(id: "loser", needsReauth: true)
        var loserMessageId: Int64 = 0
        try database.dbWriter.write { db in
            try survivor.insert(db)
            try loser.insert(db)
            var survivorInbox = MailboxRecord(accountId: survivor.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            survivorInbox = try survivorInbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var survivorMessage = MessageRecord(mailboxId: survivorInbox.id!, uid: 1, subject: "Survivor inbox mail", internalDate: epoch)
            try survivorMessage.insert(db)

            var loserSent = MailboxRecord(accountId: loser.id, path: "Sent", displayPath: "Sent", role: .sent)
            loserSent = try loserSent.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var loserMessage = MessageRecord(mailboxId: loserSent.id!, uid: 1, subject: "Loser-only sent mail", internalDate: epoch)
            try loserMessage.insert(db)
            loserMessageId = loserMessage.id!
        }

        _ = try database.dbWriter.write { db in try AccountDuplicateMerger.mergeDuplicateAccounts(db: db) }

        let mailboxes = try database.dbWriter.read { db in try MailboxRecord.filter(Column("accountId") == "survivor").fetchAll(db) }
        #expect(Set(mailboxes.map(\.path)) == ["INBOX", "Sent"])
        let carriedOverMessage = try database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: loserMessageId) }
        #expect(carriedOverMessage?.subject == "Loser-only sent mail", "the loser's unique Sent-mailbox message must survive the merge")
    }

    /// The literal "both copies independently synced the same physical IMAP
    /// mailbox" case — both accounts have their own "INBOX" with one
    /// message in common (matched by `messageId`) and the loser also has
    /// one message the survivor never fetched. After merging: exactly one
    /// INBOX, the shared message survives once (not duplicated), its
    /// loser-side pin/flag state is carried forward onto the survivor's
    /// copy, and the unique loser message is preserved too — nothing about
    /// this mailbox is silently dropped.
    @Test("merges a colliding mailbox message-by-message without duplicating or losing mail")
    func mergesCollidingMailboxWithoutDuplicatingOrLosingMail() throws {
        let database = try AppDatabase.makeInMemory()
        let survivor = makeAccount(id: "survivor", needsReauth: false)
        let loser = makeAccount(id: "loser", needsReauth: true)
        var survivorSharedMessageId: Int64 = 0
        var loserUniqueMessageId: Int64 = 0
        try database.dbWriter.write { db in
            try survivor.insert(db)
            try loser.insert(db)

            var survivorInbox = MailboxRecord(accountId: survivor.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1)
            survivorInbox = try survivorInbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var sharedOnSurvivor = MessageRecord(
                mailboxId: survivorInbox.id!, uid: 1, messageId: "<shared@otegami.test>",
                subject: "Shared", internalDate: epoch, isPinnedLocal: false
            )
            try sharedOnSurvivor.insert(db)
            survivorSharedMessageId = sharedOnSurvivor.id!

            var loserInbox = MailboxRecord(accountId: loser.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1)
            loserInbox = try loserInbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            // Same message (matched by messageId), but pinned on the
            // loser's copy — that pin must survive onto the survivor's row.
            var sharedOnLoser = MessageRecord(
                mailboxId: loserInbox.id!, uid: 1, messageId: "<shared@otegami.test>",
                subject: "Shared", internalDate: epoch, isPinnedLocal: true
            )
            try sharedOnLoser.insert(db)
            // A message the loser has that the survivor never fetched.
            var uniqueOnLoser = MessageRecord(
                mailboxId: loserInbox.id!, uid: 2, messageId: "<unique@otegami.test>",
                subject: "Unique to loser", internalDate: epoch
            )
            try uniqueOnLoser.insert(db)
            loserUniqueMessageId = uniqueOnLoser.id!
        }

        _ = try database.dbWriter.write { db in try AccountDuplicateMerger.mergeDuplicateAccounts(db: db) }

        let mailboxes = try database.dbWriter.read { db in try MailboxRecord.filter(Column("accountId") == "survivor").fetchAll(db) }
        #expect(mailboxes.count == 1, "exactly one INBOX must remain, not two")

        let allMessages = try database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(allMessages.count == 2, "the shared message must not be duplicated, and the unique one must not be dropped")

        let survivingShared = try database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: survivorSharedMessageId) }
        #expect(survivingShared?.isPinnedLocal == true, "the loser's pin on the shared message must carry forward onto the survivor's copy")

        let survivingUnique = try database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: loserUniqueMessageId) }
        #expect(survivingUnique?.subject == "Unique to loser")
        #expect(survivingUnique?.mailboxId == mailboxes.first?.id, "the unique message must be repointed onto the surviving mailbox")
    }

    /// Local-only rows that aren't mail at all — drafts, queued sends,
    /// account-scoped templates, and pending offline operations — must
    /// follow the loser account over to the survivor rather than vanishing
    /// with the deleted `account` row.
    @Test("repoints drafts, outbox, templates, and the op queue instead of losing them")
    func repointsNonMailLocalOnlyData() throws {
        let database = try AppDatabase.makeInMemory()
        let survivor = makeAccount(id: "survivor", needsReauth: false)
        let loser = makeAccount(id: "loser", needsReauth: true)
        try database.dbWriter.write { db in
            try survivor.insert(db)
            try loser.insert(db)
            var draft = DraftMessageRecord(
                accountId: loser.id, toAddresses: [], subject: "Draft", plainTextBody: "body",
                references: [], createdAt: epoch, updatedAt: epoch
            )
            try draft.insert(db)
            var outbox = OutboxMessageRecord(
                accountId: loser.id, toAddresses: [], ccAddresses: [], bccAddresses: [],
                subject: "Outbox", plainTextBody: "body", references: [], createdAt: epoch
            )
            try outbox.insert(db)
            var template = MailTemplateRecord(
                name: "Signature", body: "body", accountId: loser.id, createdAt: epoch, updatedAt: epoch
            )
            try template.insert(db)
            try db.execute(
                sql: "INSERT INTO opQueue (accountId, kind, payload, createdAt, attempts) VALUES (?, ?, ?, ?, 0)",
                arguments: [loser.id, "setFlags", Data(), epoch]
            )
        }

        _ = try database.dbWriter.write { db in try AccountDuplicateMerger.mergeDuplicateAccounts(db: db) }

        let (draftCount, outboxCount, templateCount, opQueueCount) = try database.dbWriter.read { db in
            (
                try DraftMessageRecord.filter(Column("accountId") == "survivor").fetchCount(db),
                try OutboxMessageRecord.filter(Column("accountId") == "survivor").fetchCount(db),
                try MailTemplateRecord.filter(Column("accountId") == "survivor").fetchCount(db),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM opQueue WHERE accountId = ?", arguments: ["survivor"]) ?? 0
            )
        }
        #expect(draftCount == 1)
        #expect(outboxCount == 1)
        #expect(templateCount == 1)
        #expect(opQueueCount == 1)
    }

    @Test("running the merge twice is idempotent")
    func idempotentAcrossRepeatedRuns() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.write { db in
            try makeAccount(id: "real", needsReauth: false).insert(db)
            try makeAccount(id: "duplicate", needsReauth: true).insert(db)
        }

        let first = try database.dbWriter.write { db in try AccountDuplicateMerger.mergeDuplicateAccounts(db: db) }
        #expect(first.count == 1)

        let second = try database.dbWriter.write { db in try AccountDuplicateMerger.mergeDuplicateAccounts(db: db) }
        #expect(second.isEmpty, "re-running after the group is already resolved must find nothing left to merge")

        let remaining = try database.dbWriter.read { db in try AccountRecord.fetchAll(db) }
        #expect(remaining.map(\.id) == ["real"])
    }
}
