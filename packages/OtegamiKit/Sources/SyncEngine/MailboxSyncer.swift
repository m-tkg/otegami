import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore

/// Differential ("incremental") sync for a single mailbox (M3): new mail
/// since the last sync, flag changes (`CONDSTORE` when available, a
/// full-window re-fetch-and-diff otherwise), and self-healing resync when
/// the server's `uidValidity` no longer matches what was last stored
/// (including the very first sync, `uidValidity == 0`, which reuses the
/// exact same windowed-resync path).
///
/// Stateless and connection-agnostic like `AccountSyncer`/`BodyFetcher`:
/// callers hand it an already-connected, already-`select`ed-appropriate
/// session (actually `incrementalSync` does its own `select`, to always
/// read a fresh `MailboxStatus`) plus the account's advertised
/// capabilities, and it does its own per-step transactions so a mid-sync
/// crash/disconnect leaves the local database in a consistent (if
/// incomplete) state rather than rolling back everything already
/// committed — resuming a later `incrementalSync` call picks up wherever
/// it left off.
public actor MailboxSyncer {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public struct Progress: Sendable, Equatable {
        public var newMessages = 0
        public var flagChanges = 0
        public var deletedMessages = 0
        /// `true` when this pass took the uidValidity-changed/never-synced
        /// full-resync path rather than the usual differential one.
        public var didFullResync = false

        public init(newMessages: Int = 0, flagChanges: Int = 0, deletedMessages: Int = 0, didFullResync: Bool = false) {
            self.newMessages = newMessages
            self.flagChanges = flagChanges
            self.deletedMessages = deletedMessages
            self.didFullResync = didFullResync
        }
    }

    /// Runs one incremental sync pass for `mailboxRecord`, returning the
    /// updated record (new `uidValidity`/`uidNext`/`highestModSeq`/
    /// `messageCount`/`lastSyncedAt`) and a summary of what changed. Safe
    /// to call repeatedly (e.g. every IDLE wake or pull-to-refresh) —
    /// every step is idempotent the same way `AccountSyncer.upsert` is.
    @discardableResult
    public func incrementalSync(
        mailboxRecord: MailboxRecord,
        mailboxPath: String,
        accountId: String,
        session: any IMAPSessionProtocol,
        capabilities: Set<IMAPCapability>
    ) async throws -> (mailbox: MailboxRecord, progress: Progress) {
        guard let mailboxId = mailboxRecord.id else {
            return (mailboxRecord, Progress())
        }

        let status = try await session.select(mailboxPath)

        // `uidValidity == 0` covers a mailbox that's never been through
        // AccountSyncer.performInitialSync (e.g. a newly-discovered
        // mailbox, or this being called before initial sync for some
        // reason) — reusing the windowed full-resync path there (rather
        // than falling through to "new mail since UID 1", which would try
        // to fetch the *entire* mailbox unwindowed) means incrementalSync
        // is safe to call unconditionally without callers needing to track
        // "has this mailbox been initial-synced yet" themselves.
        let needsFullResync = mailboxRecord.uidValidity == 0 || Int64(status.uidValidity) != mailboxRecord.uidValidity
        if needsFullResync {
            if mailboxRecord.uidValidity != 0 {
                // A real uidValidity change: every previously-stored UID in
                // this mailbox now refers to a different (or no) message,
                // so nothing about the old rows is safe to keep. Any thread
                // aggregates those messages contributed to need settling
                // too (M4) — a thread that only had messages in this
                // mailbox is now empty and should be deleted, not left
                // stale.
                _ = try await database.dbWriter.write { db in
                    let doomed = try MessageRecord.filter(Column("mailboxId") == mailboxId).fetchAll(db)
                    // M7: the FTS index has no foreign key to `message` (it's
                    // a virtual table), so a wholesale wipe like this one
                    // needs its own explicit cleanup — otherwise these rows'
                    // rowids would keep matching stale text forever.
                    try FTSIndexer.deleteAll(messageIds: doomed.compactMap(\.id), db: db)
                    try MessageRecord.filter(Column("mailboxId") == mailboxId).deleteAll(db)
                    try ThreadAssigner.recomputeAggregates(forThreadsAmong: doomed, db: db)
                }
            }
            let updated = try await performWindowedResync(
                mailboxId: mailboxId,
                mailboxPath: mailboxPath,
                accountId: accountId,
                session: session,
                status: status,
                mailboxRecord: mailboxRecord
            )
            return (updated, Progress(didFullResync: true))
        }

        var progress = Progress()

        // 1. New mail: everything since the highest UID already stored.
        let maxUID = try await database.dbWriter.read { db in try MessageQuery.maxUID(mailboxId: mailboxId, db: db) }
        let newMailLowerBound = (maxUID ?? 0) + 1
        if newMailLowerBound < status.uidNext {
            let newEnvelopes = try await session.fetchEnvelopes(
                mailboxPath: mailboxPath,
                uids: .from(newMailLowerBound),
                batchSize: AccountSyncer.fetchBatchSize
            )
            if !newEnvelopes.isEmpty {
                try await database.dbWriter.write { db in
                    for envelope in newEnvelopes {
                        try AccountSyncer.upsert(envelope: envelope, mailboxId: mailboxId, accountId: accountId, db: db)
                    }
                }
                progress.newMessages = newEnvelopes.count
            }
        }

        // 2. Flag sync: CONDSTORE when the server supports it and
        // something has actually changed since our last-seen modSeq;
        // otherwise fall back to re-fetching FLAGS for the whole synced
        // window and diffing (which also catches server-side deletions —
        // CONDSTORE alone can't distinguish "unchanged" from "expunged"
        // without QRESYNC's vanished-UID reporting, which
        // `MailCoreIMAPSession.fetchEnvelopes(changedSince:)` doesn't
        // surface; see its doc comment).
        if capabilities.contains(.condstore) {
            if status.highestModSeq > UInt64(mailboxRecord.highestModSeq) {
                let changed = try await session.fetchEnvelopes(
                    mailboxPath: mailboxPath,
                    changedSince: UInt64(mailboxRecord.highestModSeq)
                )
                if !changed.isEmpty {
                    try await database.dbWriter.write { db in
                        for envelope in changed {
                            try AccountSyncer.upsert(envelope: envelope, mailboxId: mailboxId, accountId: accountId, db: db)
                        }
                    }
                    progress.flagChanges = changed.count
                }
            }
        } else {
            progress.deletedMessages = try await refetchAndDiffFlags(
                mailboxId: mailboxId,
                mailboxPath: mailboxPath,
                accountId: accountId,
                session: session
            )
        }

        // 3. Mailbox metadata, committed last (and in its own transaction)
        // so a crash between steps 1/2 and this one just means the next
        // incrementalSync call re-does slightly more work — never loses or
        // duplicates anything, since steps 1/2 are themselves idempotent.
        let updatedRecord = try await database.dbWriter.write { db -> MailboxRecord in
            var record = mailboxRecord
            record.uidValidity = Int64(status.uidValidity)
            record.uidNext = Int64(status.uidNext)
            record.highestModSeq = Int64(status.highestModSeq)
            record.messageCount = status.messageCount
            record.lastSyncedAt = Date()
            try record.update(db)
            return record
        }

        return (updatedRecord, progress)
    }

    /// The uidValidity-changed/never-synced path: re-fetches the same
    /// "most recent `initialSyncWindow` messages" window
    /// `AccountSyncer.performInitialSync` uses for a brand new mailbox.
    /// Deliberately does *not* also prefetch bodies the way initial sync
    /// does — this runs on every IDLE-triggered or pull-to-refresh
    /// incremental sync, not just once at account setup, so paying for a
    /// 50-message body prefetch here (most of which would usually be
    /// no-ops on the *normal*, non-resync path anyway) isn't worth the
    /// extra network traffic; bodies still arrive lazily on open via
    /// `SyncCoordinator.fetchBody`.
    private func performWindowedResync(
        mailboxId: Int64,
        mailboxPath: String,
        accountId: String,
        session: any IMAPSessionProtocol,
        status: MailboxStatus,
        mailboxRecord: MailboxRecord
    ) async throws -> MailboxRecord {
        if status.messageCount > 0, status.uidNext > 1 {
            let lowerBound = AccountSyncer.initialSyncLowerBound(uidNext: status.uidNext, window: AccountSyncer.initialSyncWindow)
            let envelopes = try await session.fetchEnvelopes(
                mailboxPath: mailboxPath,
                uids: UIDRange(lowerBound: lowerBound, upperBound: nil),
                batchSize: AccountSyncer.fetchBatchSize
            )
            try await database.dbWriter.write { db in
                for envelope in envelopes {
                    try AccountSyncer.upsert(envelope: envelope, mailboxId: mailboxId, accountId: accountId, db: db)
                }
            }
        }

        return try await database.dbWriter.write { db -> MailboxRecord in
            var record = mailboxRecord
            record.uidValidity = Int64(status.uidValidity)
            record.uidNext = Int64(status.uidNext)
            record.highestModSeq = Int64(status.highestModSeq)
            record.messageCount = status.messageCount
            record.lastSyncedAt = Date()
            try record.update(db)
            return record
        }
    }

    /// Non-CONDSTORE flag sync: re-fetches `FLAGS`/envelope data for every
    /// UID currently stored for this mailbox (from the lowest synced UID
    /// onward — `UIDRange.from`, open-ended, so it also folds in step 1's
    /// just-added new mail rather than needing its own upper bound) and
    /// upserts the results, then treats any locally-stored UID that
    /// *didn't* come back as server-side expunged and deletes it. Returns
    /// the number of messages deleted this way.
    private func refetchAndDiffFlags(
        mailboxId: Int64,
        mailboxPath: String,
        accountId: String,
        session: any IMAPSessionProtocol
    ) async throws -> Int {
        let localUIDs = try await database.dbWriter.read { db in
            try Int64.fetchAll(db, sql: "SELECT uid FROM message WHERE mailboxId = ?", arguments: [mailboxId])
        }
        guard let minUID = localUIDs.min() else { return 0 }

        let refetched = try await session.fetchEnvelopes(
            mailboxPath: mailboxPath,
            uids: UIDRange(lowerBound: UInt32(minUID), upperBound: nil),
            batchSize: AccountSyncer.fetchBatchSize
        )
        try await database.dbWriter.write { db in
            for envelope in refetched {
                try AccountSyncer.upsert(envelope: envelope, mailboxId: mailboxId, accountId: accountId, db: db)
            }
        }

        let serverUIDs = Set(refetched.map { Int64($0.uid) })
        let deletedUIDs = Set(localUIDs).subtracting(serverUIDs)
        guard !deletedUIDs.isEmpty else { return 0 }

        _ = try await database.dbWriter.write { db in
            let doomed = try MessageRecord
                .filter(Column("mailboxId") == mailboxId)
                .filter(deletedUIDs.contains(Column("uid")))
                .fetchAll(db)
            // M7: see the doc comment on the equivalent call above (full
            // uidValidity-change resync) — same reasoning for this
            // server-side-expunge diff.
            try FTSIndexer.deleteAll(messageIds: doomed.compactMap(\.id), db: db)
            try MessageRecord
                .filter(Column("mailboxId") == mailboxId)
                .filter(deletedUIDs.contains(Column("uid")))
                .deleteAll(db)
            try ThreadAssigner.recomputeAggregates(forThreadsAmong: doomed, db: db)
        }
        return deletedUIDs.count
    }
}
