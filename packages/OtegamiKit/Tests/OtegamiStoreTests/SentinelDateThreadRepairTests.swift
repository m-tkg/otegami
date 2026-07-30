import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// Task #193 (実機バグ「10年以上前に送った送信済みメールが、6時間前くらいの
/// 日付で受信箱に表示される」): reproduces the causal chain the task's root-
/// cause investigation proposed — a Sent-mailbox message whose stored `date`
/// looks like "just now" (the MailCore2 sentinel; see `EnvelopeDateSentinel`'s
/// doc comment) merges into a recent, unrelated INBOX thread via `Threader`'s
/// subject-fallback pass (same normalized subject, overlapping participants,
/// within 7 days) purely because `Threader.MessageFacts.date` prefers
/// `message.date` over the (correct) `message.internalDate` whenever `date`
/// is non-`nil` — and confirms `ThreadAssigner.repairSentinelDates` (the v38
/// migration's repair pass) undoes exactly that merge.
///
/// This exercises `ThreadAssigner`/`AppDatabase` directly (in-memory GRDB, no
/// MailCore2/real IMAP needed) rather than going through
/// `MailCoreIMAPSession+Mapping.envelope(from:fetchedAt:)` — that fix
/// prevents a *newly fetched* envelope's `date` from ever reaching the
/// database in this corrupted shape at all (covered separately by
/// `EnvelopeDateSentinelTests`); this file's job is the other half the task
/// explicitly called out: proving the already-stored-corruption repair path
/// actually reverses the real damage (the bad thread merge), not just the
/// `date` column.
@Suite("Sentinel date thread repair (Task #193)")
struct SentinelDateThreadRepairTests {
    private func makeDatabaseWithMailboxes() throws -> (database: AppDatabase, accountId: String, inboxId: Int64, sentId: Int64) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
        let (inboxId, sentId) = try database.dbWriter.write { db -> (Int64, Int64) in
            try account.insert(db)
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            try inbox.insert(db)
            var sent = MailboxRecord(accountId: account.id, path: "Sent", displayPath: "Sent", role: .sent)
            try sent.insert(db)
            return (inbox.id!, sent.id!)
        }
        return (database, account.id, inboxId, sentId)
    }

    @discardableResult
    private func insertMessage(
        mailboxId: Int64,
        uid: Int64,
        messageId: String?,
        subject: String,
        from: [EmailAddress],
        to: [EmailAddress],
        date: Date?,
        internalDate: Date,
        updatedAt: Date,
        db: Database
    ) throws -> Int64 {
        var message = MessageRecord(
            mailboxId: mailboxId,
            uid: uid,
            messageId: messageId,
            subject: subject,
            normalizedSubject: SubjectNormalizer.normalize(subject),
            fromAddresses: from,
            toAddresses: to,
            date: date,
            internalDate: internalDate,
            updatedAt: updatedAt
        )
        try message.insert(db)
        return message.id!
    }

    @Test("repro: a Sent message with a sentinel date merges into a recent INBOX thread, and repair undoes it")
    func sentinelDateMergeIsReproducedAndRepaired() throws {
        let (database, accountId, inboxId, sentId) = try makeDatabaseWithMailboxes()
        let aiko = EmailAddress(name: "Sato Aiko", address: "aiko@otegami.test")
        let test1 = EmailAddress(address: "test1@otegami.test")

        // "Now" for this test — the moment the recent INBOX message arrived,
        // and (via the bug) the moment the old Sent message was fetched.
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let tenYearsAgo = now.addingTimeInterval(-10 * 365 * 24 * 60 * 60)

        let (recentThreadId, sentMessageId) = try database.dbWriter.write { db -> (Int64, Int64) in
            // A genuinely recent INBOX message — unrelated to the old Sent
            // reply below except for sharing its normalized subject and
            // Aiko as a participant (an ordinary, unremarkable coincidence:
            // e.g. an annual "忘年会について" thread that recurs every year).
            let inboxMessageId = try insertMessage(
                mailboxId: inboxId, uid: 1, messageId: "<recent-1@otegami.test>",
                subject: "忘年会について", from: [aiko], to: [test1],
                date: now, internalDate: now, updatedAt: now, db: db
            )
            let recentThreadId = try ThreadAssigner.assignThread(messageId: inboxMessageId, accountId: accountId, db: db)!

            // The old Sent message: really sent/appended ~10 years ago
            // (`internalDate`, IMAP's server-assigned INTERNALDATE — the
            // trustworthy value), but its `date` got stamped with the fetch
            // moment (`now`) by the MailCore2 bug because its `Date:` header
            // was missing/malformed — exactly the shape
            // `MailCoreIMAPSession+Mapping.envelope(from:fetchedAt:)` used
            // to hand to `AccountSyncer.upsert` unfiltered before Task
            // #193's fix, and exactly the shape any row synced before that
            // fix shipped is still sitting on. No References/In-Reply-To
            // (an old message like this often predates such headers, or
            // they were stripped) — so `Threader.decide` can only fall back
            // to step 3, subject-fallback.
            let sentMessageId = try insertMessage(
                mailboxId: sentId, uid: 1, messageId: "<old-sent-1@otegami.test>",
                subject: "Re: 忘年会について", from: [test1], to: [aiko],
                date: now, internalDate: tenYearsAgo, updatedAt: now, db: db
            )
            _ = try ThreadAssigner.assignThread(messageId: sentMessageId, accountId: accountId, db: db)

            return (recentThreadId, sentMessageId)
        }

        // Repro confirmed: the old Sent message actually merged into the
        // recent INBOX thread, via subject fallback, exactly as the task's
        // root-cause investigation hypothesized.
        let beforeRepair = try database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: sentMessageId) }
        #expect(beforeRepair?.threadId == recentThreadId)
        let recentThreadBeforeRepair = try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: recentThreadId) }
        #expect(recentThreadBeforeRepair?.messageCount == 2)

        // Run the repair pass (what the v38 migration does for every
        // existing install).
        let repairedCount = try database.dbWriter.write { db in try ThreadAssigner.repairSentinelDates(db: db) }
        #expect(repairedCount == 1)

        // The merge is undone: the old message's sentinel `date` is
        // cleared (falling back to the trustworthy `internalDate`), it no
        // longer shares a thread with the recent INBOX message, and the
        // recent thread's aggregates reflect it leaving.
        let afterRepair = try database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: sentMessageId) }
        #expect(afterRepair?.date == nil)
        #expect(afterRepair?.internalDate == tenYearsAgo)
        #expect(afterRepair?.threadId != recentThreadId)

        let recentThreadAfterRepair = try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: recentThreadId) }
        #expect(recentThreadAfterRepair?.messageCount == 1)

        // Repair is idempotent: running it again finds nothing left to fix.
        let secondPassCount = try database.dbWriter.write { db in try ThreadAssigner.repairSentinelDates(db: db) }
        #expect(secondPassCount == 0)
    }

    @Test("repair leaves a legitimately-dated message's thread membership alone")
    func repairDoesNotDisturbLegitimateDates() throws {
        let (database, accountId, inboxId, sentId) = try makeDatabaseWithMailboxes()
        let aiko = EmailAddress(name: "Sato Aiko", address: "aiko@otegami.test")
        let test1 = EmailAddress(address: "test1@otegami.test")
        let now = Date(timeIntervalSince1970: 1_770_000_000)

        let (threadId, replyId) = try database.dbWriter.write { db -> (Int64, Int64) in
            let originalId = try insertMessage(
                mailboxId: inboxId, uid: 1, messageId: "<orig-1@otegami.test>",
                subject: "来月の懇親会について", from: [aiko], to: [test1],
                date: now, internalDate: now, updatedAt: now, db: db
            )
            let threadId = try ThreadAssigner.assignThread(messageId: originalId, accountId: accountId, db: db)!

            // A genuine same-day reply: `date` legitimately close to
            // `internalDate` (both "now"), and `updatedAt` also "now" —
            // this must NOT be mistaken for the sentinel pattern.
            let replyId = try insertMessage(
                mailboxId: sentId, uid: 1, messageId: "<reply-1@otegami.test>",
                subject: "Re: 来月の懇親会について", from: [test1], to: [aiko],
                date: now.addingTimeInterval(3600), internalDate: now.addingTimeInterval(3600), updatedAt: now, db: db
            )
            _ = try ThreadAssigner.assignThread(messageId: replyId, accountId: accountId, db: db)
            return (threadId, replyId)
        }

        let repairedCount = try database.dbWriter.write { db in try ThreadAssigner.repairSentinelDates(db: db) }
        #expect(repairedCount == 0)

        let reply = try database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: replyId) }
        #expect(reply?.threadId == threadId)
        #expect(reply?.date == now.addingTimeInterval(3600))
    }
}
