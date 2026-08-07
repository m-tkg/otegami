import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore

/// 古いメールのバックフィル同期: fetches mail *older* than whatever window
/// `AccountSyncer.performInitialSync`/`MailboxSyncer.performWindowedResync`
/// last established as a mailbox's "most recent N messages" — the gap that
/// leaves local search unable to find anything older than that window,
/// since search is entirely local (`docs/architecture.md`).
///
/// Stateless and connection-agnostic like `MailboxSyncer`/`BodyFetcher`:
/// a caller (`SyncCoordinator`) hands this an already-connected,
/// already-`select`ed-appropriate session and this does its own per-batch
/// transaction, so a mid-pass disconnect/cancel leaves the local database
/// consistent (if incomplete) — the next call just picks up wherever
/// `mailbox.backfillLowerBound` says it left off.
///
/// One batch = one bounded `UID FETCH` range, fetched with the exact same
/// envelope-only content (`ENVELOPE`/`FLAGS`/a `BODYSTRUCTURE` summary — no
/// body) `AccountSyncer.performInitialSync`'s own window fetch uses, and
/// persisted through the same `EnvelopePersister.upsert` every other sync
/// path in this file uses — which means a backfilled message gets threaded
/// (`ThreadAssigner`) and FTS-indexed (`FTSIndexer.reindex`, inside
/// `EnvelopePersister.upsert`) exactly like any other envelope, for free.
public actor BackfillSyncer {
    private let database: AppDatabase

    /// How many UIDs one backfill batch spans — same size as
    /// `AccountSyncer.initialSyncWindow` (the "直近500件" plan), applied
    /// here to the *next* older 500-UID slice instead of the most recent
    /// one. A ceiling, not a guarantee: a sparse UID range (archived/
    /// expunged messages leaving gaps) can yield far fewer than 500
    /// envelopes for the same UID span — `mailboxSyncer`'s callers don't
    /// need this to be dense, only bounded.
    public static let batchWindowSize: UInt32 = 500

    public struct BatchResult: Sendable, Equatable {
        /// How many envelopes this batch actually fetched (can be `0` even
        /// when `isComplete` is `false` — a UID range with nothing left in
        /// it server-side, e.g. every message in that slice was long since
        /// expunged, still counts as "scanned" and advances the cursor;
        /// see this type's own doc comment on `AccountSyncer` — the plan's
        /// "UID 範囲に該当メッセージが無くても走査済みとしてカーソルを進める").
        public var messagesFetched: Int
        /// `mailbox.backfillLowerBound`'s new value after this batch.
        public var newLowerBound: Int64
        /// `true` once `newLowerBound` has reached `1` — nothing older left
        /// to scan for this mailbox.
        public var isComplete: Bool

        public init(messagesFetched: Int, newLowerBound: Int64, isComplete: Bool) {
            self.messagesFetched = messagesFetched
            self.newLowerBound = newLowerBound
            self.isComplete = isComplete
        }
    }

    public init(database: AppDatabase) {
        self.database = database
    }

    /// (Re)derives `mailbox.backfillLowerBound` from this mailbox's current
    /// local minimum UID (`MessageQuery.minUID`) — `1` (complete) when the
    /// mailbox has no locally-synced mail at all. Called from within the
    /// same write transaction `AccountSyncer.performInitialSync`'s
    /// per-mailbox window fetch and `MailboxSyncer.performWindowedResync`
    /// already use to persist `uidValidity`/`uidNext`/etc., *after* that
    /// pass's envelopes are committed — both of those are exactly the
    /// moments a mailbox's "most recent window" boundary is established or
    /// re-established (a uidValidity change discards every previously
    /// stored UID first, so the old cursor is meaningless afterward too),
    /// so this always reflects the *current* window's lower edge rather
    /// than wherever an earlier backfill pass had walked down to. An
    /// ordinary incremental sync (`MailboxSyncer.incrementalSync`'s
    /// new-mail/flag-sync steps) never calls this — it only ever adds
    /// messages *above* the existing window or changes flags, so the
    /// backfill boundary underneath is unaffected.
    public static func resetCursor(mailboxId: Int64, db: Database) throws {
        let minUID = try MessageQuery.minUID(mailboxId: mailboxId, db: db)
        let newLowerBound = Int64(minUID ?? 1)
        try db.execute(
            sql: "UPDATE mailbox SET backfillLowerBound = ? WHERE id = ?",
            arguments: [max(newLowerBound, 1), mailboxId]
        )
    }

    /// Runs exactly one backfill batch for `mailboxRecord` (already
    /// `select`ed on `session` by the caller): fetches the `[max(1, cursor
    /// - batchWindowSize), cursor - 1]` UID range, upserts whatever comes
    /// back, and advances `mailbox.backfillLowerBound` to the batch's lower
    /// bound — even when the batch found nothing (see `BatchResult
    /// .messagesFetched`'s doc comment). Returns `nil` if `mailboxRecord`
    /// has no `id` (shouldn't happen for a record read back out of the
    /// database) or the mailbox is already complete
    /// (`mailboxRecord.backfillLowerBound <= 1`) — the caller
    /// (`SyncCoordinator`) is expected to check completion itself before
    /// scheduling more batches for this mailbox, but this guard makes the
    /// method safe to call unconditionally too.
    @discardableResult
    public func backfillOneBatch(
        mailboxRecord: MailboxRecord,
        mailboxPath: String,
        accountId: String,
        session: any IMAPSessionProtocol
    ) async throws -> BatchResult? {
        guard let mailboxId = mailboxRecord.id else { return nil }
        let cursor = mailboxRecord.backfillLowerBound
        guard cursor > 1 else {
            return BatchResult(messagesFetched: 0, newLowerBound: cursor, isComplete: true)
        }

        try Task.checkCancellation()

        let upperBound = UInt32(clamping: cursor - 1)
        let lowerBound = UInt32(clamping: max(1, cursor - Int64(Self.batchWindowSize)))

        let envelopes = try await session.fetchEnvelopes(
            mailboxPath: mailboxPath,
            uids: UIDRange(lowerBound: lowerBound, upperBound: upperBound),
            batchSize: AccountSyncer.fetchBatchSize
        )

        let newLowerBound = Int64(lowerBound)
        try await database.dbWriter.write { db in
            // 未送信のローカル変更がある UID は取り込まない
            // (`PendingOpTargets`の doc comment) — バックフィルは古い UID
            // 範囲を扱うので普段この集合とは重ならないが、アーカイブした
            // メールがたまたまその範囲に入る (古いメールを操作した直後に
            // バックフィルが走る) ことはありうる。
            let pendingTargets = try PendingOpTargets.forMailbox(mailboxId: mailboxId, accountId: accountId, db: db)
            for envelope in envelopes {
                try EnvelopePersister.upsert(envelope: envelope, mailboxId: mailboxId, accountId: accountId, pendingTargets: pendingTargets, db: db)
            }
            guard var mailbox = try MailboxRecord.fetchOne(db, key: mailboxId) else { return }
            mailbox.backfillLowerBound = newLowerBound
            try mailbox.update(db, columns: [Column("backfillLowerBound")])
        }

        return BatchResult(messagesFetched: envelopes.count, newLowerBound: newLowerBound, isComplete: newLowerBound <= 1)
    }
}
