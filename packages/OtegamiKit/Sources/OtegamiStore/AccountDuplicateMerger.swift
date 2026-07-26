import Foundation
import GRDB

/// One-time (but idempotent — safe to run on every launch) consolidation of
/// **already-local** duplicate `account` rows for the same real mailbox.
///
/// `AccountCloudSyncEngine.reconcile()`'s phase 4 (`CloudAccountSnapshot
/// .identityKey`) now refuses to *insert* a new duplicate going forward, but
/// that fix does nothing for a device that already has two `AccountRecord`
/// rows for "the same" mailbox from before the fix shipped — the real-device
/// bug report this whole fix responds to (`docs/icloud-sync.md`'s "重複挿入
/// バグ"): two devices each added the same iCloud account independently
/// (different `accountId` UUIDs, same email/IMAP host/username), and the
/// old id-only reconcile logic happily inserted both, so this device ended
/// up with two account rows — one with a working local Keychain credential,
/// one perpetually `needsReauth` because its UUID never had a matching
/// Keychain item on *this* device. `AppEnvironment.init()` runs this once at
/// every launch (mirroring `FTSIndexer.backfillIfNeeded`'s "cheap once
/// caught up" self-heal pattern, rather than a one-shot `UserDefaults` flag
/// — running it again after the first successful merge just finds no
/// duplicate groups and does nothing, so there's no real cost to leaving it
/// unconditional, and it also keeps working if some future bug ever
/// reintroduces a duplicate).
///
/// # Which side survives?
///
/// Per group of accounts sharing an `identityKey`, the **survivor** is
/// chosen by, in order: (1) not `needsReauth` (a working credential beats a
/// dangling one — an account this device can't even authenticate is the
/// definition of the "loser" in the bug report), (2) more locally-synced
/// mail (`mailbox`/`message` row count — the copy that's actually been
/// living and syncing), (3) earliest `createdAt` (deterministic tie-break).
/// Every other account in the group is a **loser**, merged into the
/// survivor and then deleted.
///
/// # No data loss
///
/// This is the load-bearing constraint (`docs/icloud-sync.md`'s migration
/// section) — every table that references `account.id` gets handled
/// explicitly, never just cascade-deleted away wholesale:
///
/// - `outboxMessage`/`draftMessage`/`mailTemplate`/`opQueue`: simply
///   repointed (`accountId = survivor`) — none of these have a uniqueness
///   constraint that a repoint could violate.
/// - `thread`: repointed wholesale too (no uniqueness constraint on
///   `thread` at all), so thread grouping/badges for merged messages stay
///   intact instead of the message set going instant-orphan-`threadId`
///   until the next `ThreadAssigner.assignAllUnthreaded` pass, which is a
///   real behavior difference the codebase already treats as "unthreaded
///   messages get picked up as an idempotent self-heal", not as data loss.
/// - `mailbox`: a loser mailbox whose `path` the survivor doesn't already
///   have is repointed wholesale (its messages, threads, flags, pins — all
///   of it — carry over untouched, since nothing about them changed except
///   which `account` row owns the mailbox). A loser mailbox whose `path`
///   the survivor *does* already have is the genuine "both copies happened
///   to sync the same physical IMAP mailbox" case (the actual source of the
///   "duplicate mail in the inbox" half of the bug report) — see
///   `mergeCollidingMailbox` for how those get merged message-by-message
///   instead of either side just being dropped.
public enum AccountDuplicateMerger {
    /// One identity group that had more than one local `account` row —
    /// returned so callers (`AppEnvironment`) can do the non-database
    /// cleanup (`Keychain`/`TokenStore`/push-watch teardown) for each
    /// `mergedAccountIds` entry, which this type has no access to (`OtegamiStore`
    /// has no Keychain/push dependency by design).
    public struct MergeResult: Equatable, Sendable {
        public let survivorAccountId: String
        public let mergedAccountIds: [String]
    }

    /// Runs the full consolidation inside `db`'s current write transaction.
    /// Callers are expected to invoke this from inside `dbWriter.write { }`
    /// (matching every other batch operation in this package —
    /// `FTSIndexer.backfillIfNeeded`, `ThreadAssigner.assignAllUnthreaded`).
    @discardableResult
    public static func mergeDuplicateAccounts(db: Database) throws -> [MergeResult] {
        let accounts = try AccountRecord.fetchAll(db)
        guard accounts.count > 1 else { return [] }

        var groups: [String: [AccountRecord]] = [:]
        for account in accounts {
            groups[account.identityKey, default: []].append(account)
        }

        var results: [MergeResult] = []
        for (_, group) in groups.sorted(by: { $0.key < $1.key }) where group.count > 1 {
            let ordered = try order(group, db: db)
            guard let survivor = ordered.first else { continue }
            var mergedIds: [String] = []
            for loser in ordered.dropFirst() {
                try merge(loserAccountId: loser.id, intoSurvivorAccountId: survivor.id, db: db)
                mergedIds.append(loser.id)
            }
            results.append(MergeResult(survivorAccountId: survivor.id, mergedAccountIds: mergedIds))
        }
        return results
    }

    /// Survivor-first ordering — see the type's doc comment for the
    /// three-step tie-break.
    private static func order(_ group: [AccountRecord], db: Database) throws -> [AccountRecord] {
        var messageCounts: [String: Int] = [:]
        for account in group {
            let count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM message
                    JOIN mailbox ON mailbox.id = message.mailboxId
                    WHERE mailbox.accountId = ?
                    """,
                arguments: [account.id]
            ) ?? 0
            messageCounts[account.id] = count
        }
        return group.sorted { lhs, rhs in
            if lhs.needsReauth != rhs.needsReauth { return !lhs.needsReauth }
            let lhsCount = messageCounts[lhs.id] ?? 0
            let rhsCount = messageCounts[rhs.id] ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    private static func merge(loserAccountId: String, intoSurvivorAccountId survivorAccountId: String, db: Database) throws {
        // Simple repoints first — none of these tables have a uniqueness
        // constraint a repoint could violate.
        try db.execute(sql: "UPDATE outboxMessage SET accountId = ? WHERE accountId = ?", arguments: [survivorAccountId, loserAccountId])
        try db.execute(sql: "UPDATE draftMessage SET accountId = ? WHERE accountId = ?", arguments: [survivorAccountId, loserAccountId])
        try db.execute(sql: "UPDATE mailTemplate SET accountId = ? WHERE accountId = ?", arguments: [survivorAccountId, loserAccountId])
        try db.execute(sql: "UPDATE opQueue SET accountId = ? WHERE accountId = ?", arguments: [survivorAccountId, loserAccountId])
        // `thread` has no uniqueness constraint either — repoint every one
        // of the loser's threads up front so mailbox/message repointing
        // below never has to touch `threadId` at all.
        try db.execute(sql: "UPDATE thread SET accountId = ? WHERE accountId = ?", arguments: [survivorAccountId, loserAccountId])

        let survivorMailboxesByPath = Dictionary(
            uniqueKeysWithValues: try MailboxRecord.filter(Column("accountId") == survivorAccountId).fetchAll(db).map { ($0.path, $0) }
        )
        let loserMailboxes = try MailboxRecord.filter(Column("accountId") == loserAccountId).fetchAll(db)

        var affectedThreadIds: Set<Int64> = []
        for loserMailbox in loserMailboxes {
            guard let loserMailboxId = loserMailbox.id else { continue }
            if let survivorMailbox = survivorMailboxesByPath[loserMailbox.path], let survivorMailboxId = survivorMailbox.id {
                let threadIds = try mergeCollidingMailbox(
                    loserMailbox: loserMailbox, loserMailboxId: loserMailboxId,
                    survivorMailbox: survivorMailbox, survivorMailboxId: survivorMailboxId,
                    db: db
                )
                affectedThreadIds.formUnion(threadIds)
            } else {
                // No path collision — the survivor simply didn't have this
                // mailbox yet. Repoint it wholesale; every message/thread
                // underneath carries over untouched.
                try db.execute(sql: "UPDATE mailbox SET accountId = ? WHERE id = ?", arguments: [survivorAccountId, loserMailboxId])
            }
        }

        for threadId in affectedThreadIds {
            try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
        }

        // Everything left under the loser account (an emptied-out mailbox
        // row from the colliding-path branch above, plus the account row
        // itself) is genuinely redundant now — cascades (`account`→
        // `mailbox`→`message`→...) clean up the rest. `messageSearchIndex`
        // is a virtual table with no FK support, so any message actually
        // deleted along the way already had its index row removed
        // explicitly by `mergeCollidingMailbox` before this point.
        _ = try AccountRecord.deleteOne(db, key: loserAccountId)
    }

    /// The literal "both copies independently synced the same physical IMAP
    /// mailbox" case — the source of visibly duplicated mail in the unified
    /// inbox, not just a duplicated account row. Matches each loser message
    /// against its survivor counterpart (by `messageId` when both sides
    /// have one, else by `uid` when both mailboxes share a `uidValidity`),
    /// merges local-only state forward (`isPinnedLocal`, flags — union, so
    /// a flag either copy already believes true is never lost) into the
    /// survivor's row, then deletes the now-redundant loser row. A loser
    /// message with no survivor counterpart at all (a real, if rare,
    /// partial-sync difference between the two copies) is repointed rather
    /// than merged, so nothing the survivor never actually had gets
    /// dropped. Returns every thread id touched, so the caller can refresh
    /// `unreadCount`/`messageCount` aggregates once at the end.
    private static func mergeCollidingMailbox(
        loserMailbox: MailboxRecord, loserMailboxId: Int64,
        survivorMailbox: MailboxRecord, survivorMailboxId: Int64,
        db: Database
    ) throws -> Set<Int64> {
        let survivorMessages = try MessageRecord.filter(Column("mailboxId") == survivorMailboxId).fetchAll(db)
        var survivorByMessageId: [String: MessageRecord] = [:]
        var survivorByUID: [Int64: MessageRecord] = [:]
        for message in survivorMessages {
            if let messageId = message.messageId { survivorByMessageId[messageId] = message }
            survivorByUID[message.uid] = message
        }
        let sameUIDValidity = loserMailbox.uidValidity == survivorMailbox.uidValidity

        var affectedThreadIds: Set<Int64> = []
        let loserMessages = try MessageRecord.filter(Column("mailboxId") == loserMailboxId).fetchAll(db)
        for loserMessage in loserMessages {
            guard let loserMessageId = loserMessage.id else { continue }
            let match = loserMessage.messageId.flatMap { survivorByMessageId[$0] }
                ?? (sameUIDValidity ? survivorByUID[loserMessage.uid] : nil)

            if var survivorMatch = match {
                survivorMatch.isPinnedLocal = survivorMatch.isPinnedLocal || loserMessage.isPinnedLocal
                survivorMatch.flagsRaw |= loserMessage.flagsRaw
                if survivorMatch.detectedLanguage == nil { survivorMatch.detectedLanguage = loserMessage.detectedLanguage }
                try survivorMatch.update(db)
                try FTSIndexer.reindex(messageId: survivorMatch.id ?? 0, db: db)
                if let threadId = survivorMatch.threadId { affectedThreadIds.insert(threadId) }
                if let loserThreadId = loserMessage.threadId { affectedThreadIds.insert(loserThreadId) }
                try FTSIndexer.delete(messageId: loserMessageId, db: db)
                try MessageBodyRecord.deleteOne(db, key: loserMessageId)
                _ = try MessageRecord.deleteOne(db, key: loserMessageId)
            } else {
                // No survivor counterpart — a genuinely unique message.
                // Guard the `(mailboxId, uid)` uniqueness constraint before
                // repointing: if some *other* survivor message already
                // happens to have this exact uid (a coincidence only
                // possible when uidValidity actually differs between the
                // two copies), fall back to just dropping the loser's copy
                // rather than crashing — the survivor's own message at that
                // uid is what every future sync will keep reconciling
                // against anyway.
                if survivorByUID[loserMessage.uid] != nil {
                    if let threadId = loserMessage.threadId { affectedThreadIds.insert(threadId) }
                    try FTSIndexer.delete(messageId: loserMessageId, db: db)
                    try MessageBodyRecord.deleteOne(db, key: loserMessageId)
                    _ = try MessageRecord.deleteOne(db, key: loserMessageId)
                } else {
                    try db.execute(sql: "UPDATE message SET mailboxId = ? WHERE id = ?", arguments: [survivorMailboxId, loserMessageId])
                    if let threadId = loserMessage.threadId { affectedThreadIds.insert(threadId) }
                }
            }
        }
        _ = try MailboxRecord.deleteOne(db, key: loserMailboxId)
        return affectedThreadIds
    }
}
