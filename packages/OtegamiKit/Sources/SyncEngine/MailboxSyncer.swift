import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore
import os

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

    /// Task #83 diagnostics: real-device reports of "アーカイブ済みのメールが
    /// 受信箱に残り続ける" (残骸) needed a way to confirm, from a Console pull,
    /// that the vanished-UID reconciliation this file does actually *ran* on
    /// the device and what it found — subsystem matches every other OSLog
    /// call site in this app (`MessageTranslator.logger`).
    private static let logger = Logger(subsystem: "com.mtkg.otegami", category: "MailboxReconcile")

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

    /// Task #194 (「Pull to refresh が長すぎて終わらない。どのくらい進んでいるのか
    /// のバーを出せるなら出したい」): a live progress update `incrementalSync`
    /// hands to its optional `onProgress` callback as it works through one
    /// mailbox's sync pass — driving a UI progress indicator without that UI
    /// needing to poll or guess. Not every phase can report a meaningful
    /// `total` (see `total`'s doc comment); the UI is expected to render a
    /// determinate bar when it can and an indeterminate one otherwise, per
    /// the task's own instruction ("総量が事前に分かる段階は割合表示、分からない
    /// 段階は不定形の表示").
    public struct SyncProgressUpdate: Sendable, Equatable {
        /// Which step of `incrementalSync` this update is for. Mirrors this
        /// file's own step numbering/doc comments (1. new mail, 2. flag
        /// sync, or the uidValidity-changed full resync) plus a `.reconcile`
        /// phase for `forceReconcileVanishedUIDs`'s extra `UID SEARCH` pass.
        public enum Phase: Sendable, Equatable {
            case newMail
            case flagSync
            case reconcile
            case fullResync
        }

        public var mailboxPath: String
        public var phase: Phase
        /// Units completed so far in this phase (a chunk-count for
        /// `.flagSync`'s per-batch reporting, 0/1 for phases that only
        /// report start/finish).
        public var completed: Int
        /// Total units expected this phase, when known ahead of time (e.g.
        /// `.flagSync`'s locally-stored UID count — the exact total
        /// `refetchAndDiffFlags` must walk through). `nil` means
        /// indeterminate: the phase either can't know its total in advance
        /// (a single unbatched network call) or genuinely has none.
        public var total: Int?

        public init(mailboxPath: String, phase: Phase, completed: Int, total: Int?) {
            self.mailboxPath = mailboxPath
            self.phase = phase
            self.completed = completed
            self.total = total
        }
    }

    /// Runs one incremental sync pass for `mailboxRecord`, returning the
    /// updated record (new `uidValidity`/`uidNext`/`highestModSeq`/
    /// `messageCount`/`lastSyncedAt`) and a summary of what changed. Safe
    /// to call repeatedly (e.g. every IDLE wake or pull-to-refresh) —
    /// every step is idempotent the same way `AccountSyncer.upsert` is.
    ///
    /// - Parameter forceReconcileVanishedUIDs: Task #83 (実機バグ: Spark/
    ///   Gmail Web でアーカイブ済みのメールが Otegami の受信箱に残り続ける).
    ///   `false` (the default, every high-frequency caller e.g. the
    ///   foreground `IDLE` wake) keeps the CONDSTORE path's existing
    ///   behavior: the vanished-UID check below only runs when `status
    ///   .highestModSeq` actually advanced past what was last stored.
    ///   That guard turned out to be exactly the real-device bug — Gmail
    ///   advertises CONDSTORE but doesn't necessarily bump a mailbox's
    ///   `HIGHESTMODSEQ` for another client's `EXPUNGE`, so an
    ///   archived-elsewhere message could leave `highestModSeq` completely
    ///   unchanged and this whole block, including Task #79's own
    ///   `detectAndRemoveVanishedByUIDSearch` fallback, was skipped
    ///   entirely. `true` (pull-to-refresh and `MessageListView`'s
    ///   5-minute mailbox-display auto-resync, both low-frequency,
    ///   user-visible-mailbox-scoped passes — see their call sites) runs
    ///   that same cheap `UID SEARCH` reconciliation unconditionally,
    ///   regardless of whether `highestModSeq` moved. Left at `false` for
    ///   the `IDLE` wake path deliberately: that one fires far more often,
    ///   and INBOX's own foreground `IDLE` loop plus the periodic passes
    ///   above already give a stuck-residual message a bounded time to
    ///   self-heal without paying for a `UID SEARCH` on every single wake.
    @discardableResult
    public func incrementalSync(
        mailboxRecord: MailboxRecord,
        mailboxPath: String,
        accountId: String,
        session: any IMAPSessionProtocol,
        capabilities: Set<IMAPCapability>,
        forceReconcileVanishedUIDs: Bool = false,
        onProgress: (@Sendable (SyncProgressUpdate) -> Void)? = nil
    ) async throws -> (mailbox: MailboxRecord, progress: Progress) {
        guard let mailboxId = mailboxRecord.id else {
            return (mailboxRecord, Progress())
        }

        // Task #194: checked at the top of every step below (not just here)
        // — each step already commits its own transaction (this file's own
        // doc comment: "does its own per-step transactions so a mid-sync
        // crash/disconnect leaves the local database in a consistent…
        // state"), so a cancellation caught between steps is exactly as
        // safe as one caught between separate `incrementalSync` calls
        // always already was. `Task.checkCancellation()` over checking
        // `Task.isCancelled` and returning early: the caller (`AccountSyncer
        // .performIncrementalSync`'s per-mailbox loop) needs to actually see
        // `CancellationError` propagate out, to stop syncing *other*
        // mailboxes too rather than plowing ahead once the user has asked
        // to cancel.
        try Task.checkCancellation()

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
            onProgress?(SyncProgressUpdate(mailboxPath: mailboxPath, phase: .fullResync, completed: 0, total: nil))
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
        try Task.checkCancellation()
        let maxUID = try await database.dbWriter.read { db in try MessageQuery.maxUID(mailboxId: mailboxId, db: db) }
        let newMailLowerBound = (maxUID ?? 0) + 1
        if newMailLowerBound < status.uidNext {
            // The total (`status.uidNext - newMailLowerBound`) is known
            // ahead of time here, but `fetchEnvelopes(uids:batchSize:)`
            // batches internally (`MailCoreIMAPSession.chunk`) without
            // surfacing per-batch progress — unlike `.flagSync` below, this
            // phase can only report "started"/"finished", not a running
            // count, without a larger protocol change than Task #194's
            // actual bottleneck (the non-CONDSTORE flag-sync path) warrants.
            onProgress?(SyncProgressUpdate(
                mailboxPath: mailboxPath,
                phase: .newMail,
                completed: 0,
                total: Int(status.uidNext - newMailLowerBound)
            ))
            // Bounded to `status.uidNext - 1` (this pass's own just-fetched
            // upper limit), never open-ended — see docs/architecture.md's
            // Known pitfalls (d): an open-ended `UIDRange` (`upperBound ==
            // nil`, IMAP's `lowerBound:*`) is never chunked by
            // `MailCoreIMAPSession.chunk`, so `batchSize` above would be
            // silently ignored and this would issue one unbounded `FETCH`
            // for every message that ever arrived since the last sync — no
            // incremental progress, no cancellation checkpoint, on a mailbox
            // that received a very large amount of new mail (a long-dormant
            // account resuming sync, a mailing list, ...). The guard just
            // above (`newMailLowerBound < status.uidNext`) already
            // guarantees `newMailLowerBound <= status.uidNext - 1`, so this
            // subtraction never underflows and the range is never degenerate
            // here.
            let newEnvelopes = try await session.fetchEnvelopes(
                mailboxPath: mailboxPath,
                uids: UIDRange(lowerBound: newMailLowerBound, upperBound: status.uidNext - 1),
                batchSize: AccountSyncer.fetchBatchSize
            )
            if !newEnvelopes.isEmpty {
                try await database.dbWriter.write { db in
                    // 未送信のローカル変更がある UID は取り込まない
                    // (`PendingOpTargets`の doc comment) — この`write`
                    // ブロックにつき1回だけ組み立てて、エンベロープ数ぶん
                    // `opQueue`を読み直さないようにする。
                    let pendingTargets = try PendingOpTargets.forMailbox(mailboxId: mailboxId, accountId: accountId, db: db)
                    for envelope in newEnvelopes {
                        try EnvelopePersister.upsert(envelope: envelope, mailboxId: mailboxId, accountId: accountId, pendingTargets: pendingTargets, db: db)
                    }
                }
                progress.newMessages = newEnvelopes.count
            }
        }

        // 2. Flag sync: CONDSTORE when the server supports it and
        // something has actually changed since our last-seen modSeq;
        // otherwise fall back to re-fetching FLAGS for the whole synced
        // window and diffing (which also catches server-side deletions —
        // see its doc comment).
        //
        // CONDSTORE alone can't distinguish "unchanged" from "expunged"
        // without QRESYNC's vanished-UID reporting (RFC 7162 §3.2.10) —
        // Task #79 (実機バグ: Web でアーカイブ済みのメールが受信トレイに残り続ける)
        // was exactly this gap: a message another client (Gmail's own web
        // UI) EXPUNGEd from this mailbox was never noticed here, since this
        // branch used to only ever call `fetchEnvelopes(changedSince:)` and
        // upsert whatever came back — never checking for anything *missing*.
        // `ChangedSinceResult.vanishedUIDs` reports vanished UIDs directly
        // when the server also supports QRESYNC; when it doesn't (`nil` —
        // confirmed the case for Gmail, which advertises CONDSTORE but never
        // QRESYNC), `detectAndRemoveVanishedByUIDSearch` below is the
        // fallback: a cheap `UID SEARCH` over the locally-synced window
        // (fetches no envelope data at all) rather than the non-CONDSTORE
        // path's full re-fetch-and-diff, which would defeat the point of
        // having CONDSTORE in the first place.
        try Task.checkCancellation()
        // Task #194: which path this pass actually takes is exactly what a
        // real-device Console pull needs to confirm — this can't be
        // answered from the dev mailstack alone (Dovecot there advertises
        // CONDSTORE).
        Self.logger.notice(
            "flagSync: \(mailboxPath, privacy: .public) condstore=\(capabilities.contains(.condstore), privacy: .public)"
        )
        if capabilities.contains(.condstore), mailboxRecord.highestModSeq > 0, status.highestModSeq > 0 {
            var vanishedAlreadyHandled = false
            if status.highestModSeq > UInt64(mailboxRecord.highestModSeq) {
                let (flagChanges, deletedMessages) = try await condstoreFlagChangeSync(
                    mailboxId: mailboxId,
                    mailboxPath: mailboxPath,
                    accountId: accountId,
                    session: session,
                    status: status,
                    sinceModSeq: UInt64(mailboxRecord.highestModSeq),
                    onProgress: onProgress
                )
                progress.flagChanges = flagChanges
                progress.deletedMessages = deletedMessages
                vanishedAlreadyHandled = true
            }
            // Task #83: see `forceReconcileVanishedUIDs`'s doc comment —
            // `highestModSeq` staying put is not proof nothing was expunged
            // by another client, so a low-frequency caller asks for this
            // reconciliation unconditionally rather than trusting that guard.
            if forceReconcileVanishedUIDs, !vanishedAlreadyHandled {
                Self.logger.notice(
                    "reconcile: forcing UID SEARCH for \(mailboxPath, privacy: .public) despite unchanged highestModSeq=\(mailboxRecord.highestModSeq, privacy: .public)"
                )
                onProgress?(SyncProgressUpdate(mailboxPath: mailboxPath, phase: .reconcile, completed: 0, total: nil))
                progress.deletedMessages = try await detectAndRemoveVanishedByUIDSearch(
                    mailboxId: mailboxId,
                    mailboxPath: mailboxPath,
                    session: session,
                    status: status
                )
            }
        } else if capabilities.contains(.condstore) {
            // Baseline pass: either this mailbox has never actually
            // received a CHANGEDSINCE-based sync before (`mailboxRecord
            // .highestModSeq == 0` — every mailbox's stored modSeq starts at
            // 0 straight out of `performWindowedResync`/initial sync), or
            // this particular `SELECT` came back NOMODSEQ (`status
            // .highestModSeq == 0` — a server can advertise CONDSTORE
            // generally yet still report this for a specific mailbox, RFC
            // 7162 §3.1.2). Either way, `sinceModSeq` would be `0`, and
            // mailcore2's `MCIMAPSession::syncMessages` (the pinned
            // mailcore2 revision's `MCIMAPSession.cpp`) omits `CHANGEDSINCE`
            // from the wire command entirely whenever `modseq == 0` — the
            // resulting `UID FETCH 1:* (FLAGS)` is a single unchunked
            // request covering the whole mailbox, with no batching, no
            // progress, and no cancellation checkpoint, which is exactly
            // the multi-minute pull-to-refresh stall this guard exists to
            // avoid. Falling back to the same chunked, progress-reporting
            // `refetchAndDiffFlags` the non-CONDSTORE path already uses
            // sidesteps that mailcore2 behavior entirely — it also already
            // does its own vanished-UID detection by diffing the UIDs each
            // chunk actually returns, so no separate `UID SEARCH` pass is
            // needed here the way the modSeq-advanced branch above needs
            // one.
            Self.logger.notice(
                "flagSync: baseline pass for \(mailboxPath, privacy: .public) (stored highestModSeq=\(mailboxRecord.highestModSeq, privacy: .public), server highestModSeq=\(status.highestModSeq, privacy: .public))"
            )
            progress.deletedMessages = try await refetchAndDiffFlags(
                mailboxId: mailboxId,
                mailboxPath: mailboxPath,
                accountId: accountId,
                session: session,
                status: status,
                onProgress: onProgress
            )
        } else {
            progress.deletedMessages = try await refetchAndDiffFlags(
                mailboxId: mailboxId,
                mailboxPath: mailboxPath,
                accountId: accountId,
                session: session,
                status: status,
                onProgress: onProgress
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
            // Task #167 / F13: `status.highestModSeq` is a server-
            // controlled `UInt64` (the `SELECT` response's
            // `HIGHESTMODSEQ` resp-text-code, RFC 7162 §3.1.1) —
            // `Int64(_:)` traps for any value past `Int64.max`.
            // `Int64(clamping:)` never traps; this field is only ever
            // compared for "did it advance since last sync", so clamping
            // an unrealistic value to `Int64.max` is indistinguishable in
            // practice from storing it exactly.
            record.highestModSeq = Int64(clamping: status.highestModSeq)
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
        try Task.checkCancellation()
        if status.messageCount > 0 {
            let envelopes = try await session.fetchRecentEnvelopes(
                mailboxPath: mailboxPath,
                count: Int(AccountSyncer.initialSyncWindow),
                batchSize: AccountSyncer.fetchBatchSize,
                status: status
            )
            try await database.dbWriter.write { db in
                let pendingTargets = try PendingOpTargets.forMailbox(mailboxId: mailboxId, accountId: accountId, db: db)
                for envelope in envelopes {
                    try EnvelopePersister.upsert(envelope: envelope, mailboxId: mailboxId, accountId: accountId, pendingTargets: pendingTargets, db: db)
                }
            }
        }

        return try await database.dbWriter.write { db -> MailboxRecord in
            var record = mailboxRecord
            record.uidValidity = Int64(status.uidValidity)
            record.uidNext = Int64(status.uidNext)
            // Task #167 / F13: `status.highestModSeq` is a server-
            // controlled `UInt64` (the `SELECT` response's
            // `HIGHESTMODSEQ` resp-text-code, RFC 7162 §3.1.1) —
            // `Int64(_:)` traps for any value past `Int64.max`.
            // `Int64(clamping:)` never traps; this field is only ever
            // compared for "did it advance since last sync", so clamping
            // an unrealistic value to `Int64.max` is indistinguishable in
            // practice from storing it exactly.
            record.highestModSeq = Int64(clamping: status.highestModSeq)
            record.messageCount = status.messageCount
            record.lastSyncedAt = Date()
            try record.update(db)
            // 古いメールのバックフィル同期: a uidValidity-changed/never-synced
            // resync just re-established this mailbox's "most recent
            // window" from scratch (the caller already deleted every
            // previously-stored message for a real uidValidity change) —
            // see `BackfillSyncer.resetCursor`'s doc comment.
            try BackfillSyncer.resetCursor(mailboxId: mailboxId, db: db)
            return record
        }
    }

    /// CONDSTORE flag-change sync — `incrementalSync`'s step 2, called only
    /// when `status.highestModSeq` actually advanced past `sinceModSeq`.
    /// Flags-only by default (`IMAPSessionProtocol.fetchFlags(mailboxPath:
    /// changedSince:)`, not the full `ENVELOPE`/`BODYSTRUCTURE`/size
    /// `fetchEnvelopes(mailboxPath:changedSince:)` this used to call
    /// unconditionally): splits the result via
    /// `applyFlagsDiffAndReconcileUnknown` into "known locally, flags
    /// differ" (a targeted flags-only update) vs. "unknown to this pass's
    /// local snapshot" (a real, scoped envelope re-fetch — Task #120's
    /// pending-relocation reconciliation needs `messageId`, which a
    /// flags-only fetch never has) — the same split
    /// `refetchAndDiffFlags` already does for the non-CONDSTORE path.
    ///
    /// Falls back to the full-envelope overload (unconditionally upserting
    /// every returned envelope — this method's entire pre-flags-only-
    /// optimization behavior) whenever this mailbox has *any*
    /// pending-relocation row at all, exactly mirroring
    /// `refetchAndDiffFlags`'s own `hasPendingRelocations` guard: a pending
    /// row's real UID can coincide with a UID *already* known locally as a
    /// genuine, independently-synced duplicate (this file's own
    /// `MessageRelocationReconciliationTests` scenario), in which case the
    /// flags-only fast path's "known locally, flags unchanged" branch would
    /// never call `upsert` at all and the pending row would never
    /// reconcile — silently leaving it orphaned. Pending rows are transient
    /// and rare in practice (only exist in the narrow window between a
    /// local move and the server confirming it), so trading this one pass's
    /// payload size for guaranteed correctness costs little.
    ///
    /// Vanished-UID resolution (QRESYNC directly, else the `UID SEARCH`
    /// fallback) is identical in both branches and unchanged from before
    /// this method existed — see `incrementalSync`'s doc comment for the
    /// full picture. Returns `(flagChanges, deletedMessages)`;
    /// `vanishedAlreadyHandled` is always `true` on return (both branches
    /// always resolve it one way or another).
    private func condstoreFlagChangeSync(
        mailboxId: Int64,
        mailboxPath: String,
        accountId: String,
        session: any IMAPSessionProtocol,
        status: MailboxStatus,
        sinceModSeq: UInt64,
        onProgress: (@Sendable (SyncProgressUpdate) -> Void)? = nil
    ) async throws -> (flagChanges: Int, deletedMessages: Int) {
        // Task #120: same reasoning as `refetchAndDiffFlags`'s identical
        // check — see that method's `hasPendingRelocations` doc comment.
        let hasPendingRelocations = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == mailboxId).filter(Column("uid") <= 0).fetchCount(db) > 0
        }

        var flagChanges = 0
        let vanishedUIDs: Set<UInt32>?

        if hasPendingRelocations {
            Self.logger.notice(
                "flagSync: \(mailboxPath, privacy: .public) has pending-relocation row(s) — using a full envelope changedSince fetch for this pass"
            )
            let result = try await session.fetchEnvelopes(mailboxPath: mailboxPath, changedSince: sinceModSeq)
            if !result.envelopes.isEmpty {
                try await database.dbWriter.write { db in
                    let pendingTargets = try PendingOpTargets.forMailbox(mailboxId: mailboxId, accountId: accountId, db: db)
                    for envelope in result.envelopes {
                        try EnvelopePersister.upsert(envelope: envelope, mailboxId: mailboxId, accountId: accountId, pendingTargets: pendingTargets, db: db)
                    }
                }
                flagChanges = result.envelopes.count
            }
            vanishedUIDs = result.vanishedUIDs
        } else {
            let result = try await session.fetchFlags(mailboxPath: mailboxPath, changedSince: sinceModSeq)
            if !result.flagsByUID.isEmpty {
                // `AND uid > 0` isn't strictly needed here (this branch only
                // runs when there are no pending-relocation rows at all),
                // but matches `refetchAndDiffFlags`'s identical query
                // verbatim for consistency.
                let localFlagsByUID = try await database.dbWriter.read { db -> [Int64: Int] in
                    var localResult: [Int64: Int] = [:]
                    let rows = try Row.fetchAll(db, sql: "SELECT uid, flagsRaw FROM message WHERE mailboxId = ? AND uid > 0", arguments: [mailboxId])
                    for row in rows {
                        localResult[row["uid"]] = row["flagsRaw"]
                    }
                    return localResult
                }
                flagChanges = try await applyFlagsDiffAndReconcileUnknown(
                    mailboxId: mailboxId,
                    mailboxPath: mailboxPath,
                    accountId: accountId,
                    session: session,
                    fetchedFlags: result.flagsByUID,
                    localFlagsByUID: localFlagsByUID,
                    logContext: "flagSync"
                )
            }
            vanishedUIDs = result.vanishedUIDs
        }

        let deletedMessages: Int
        if let vanishedUIDs {
            deletedMessages = try await deleteMessages(mailboxId: mailboxId, uids: Set(vanishedUIDs.map(Int64.init)))
        } else {
            onProgress?(SyncProgressUpdate(mailboxPath: mailboxPath, phase: .reconcile, completed: 0, total: nil))
            deletedMessages = try await detectAndRemoveVanishedByUIDSearch(
                mailboxId: mailboxId,
                mailboxPath: mailboxPath,
                session: session,
                status: status
            )
        }
        return (flagChanges, deletedMessages)
    }

    /// Non-CONDSTORE flag sync (Task #194 rewrite — 「Pull to refresh が
    /// 長すぎて終わらない」): walks the locally-stored UID window in
    /// `AccountSyncer.fetchBatchSize`-sized chunks, fetching only `FLAGS`
    /// per chunk (`IMAPSessionProtocol.fetchFlags`, not the full
    /// `ENVELOPE`/`BODYSTRUCTURE`/size `fetchEnvelopes` this used before)
    /// and writing a row only when its flags actually changed — skipping
    /// `AccountSyncer.upsert`'s full envelope rewrite (and the `FTSIndexer
    /// .reindex`/thread-aggregate-recompute pass that goes with it) for
    /// every message whose flags *didn't* change, which is the overwhelming
    /// majority on a typical resync. Then treats any locally-stored UID
    /// that never showed up in any chunk's response as server-side expunged
    /// and deletes it — same outcome as before, just derived from a much
    /// smaller `FLAGS`-only fetch. Returns the number of messages deleted.
    ///
    /// Chunking here (rather than delegating to `fetchEnvelopes`'s own
    /// internal `batchSize` chunking, the way this method used to) is
    /// deliberate on two counts:
    /// - The old call passed an open-ended `UIDRange` (`upperBound: nil`,
    ///   IMAP's `N:*`) — `MailCoreIMAPSession.chunk` leaves an open-ended
    ///   range entirely *un*-chunked (nothing correct to chunk against
    ///   without knowing the mailbox's actual highest UID), so `batchSize`
    ///   was silently ignored and the whole locally-synced window was
    ///   fetched in one unbounded `FETCH` command. For an account with a
    ///   large mailbox, that single command is almost certainly the actual
    ///   "終わらない" (never finishes) — no incremental data arrives, so
    ///   nothing can be shown or cancelled until the entire thing returns.
    ///   `fullRange` below is bounded (`status.uidNext`, the server's own
    ///   just-fetched upper limit), so the same chunking logic other
    ///   batched fetches rely on actually applies.
    /// - Chunking at this level (not inside the session) lets each chunk
    ///   report `.flagSync` progress (`onProgress`) and get checked against
    ///   `Task.checkCancellation()` — real, user-visible progress and a
    ///   safe cancellation granularity for exactly the pass that used to
    ///   have neither.
    ///
    /// Cancellation safety: each chunk's flag updates commit in their own
    /// transaction (same "per-step transaction" shape this whole file
    /// documents at the top), so a cancellation between chunks leaves
    /// whatever was already written intact. Deletion inference needs the
    /// *complete* picture across every chunk — a UID this pass never got to
    /// is not evidence it's gone — so `deleteMessages` only ever runs after
    /// the loop below finishes without throwing; a `CancellationError`
    /// thrown out of the loop skips it entirely (same non-destructive shape
    /// the empty-response guard below already has).
    ///
    /// Real-device follow-up investigation (docs/verify.md, "実機バグ:
    /// メッセージ一覧が起動ごとに出たり出なかったりする"): this diff is only as
    /// trustworthy as what actually came back — a single dropped-mid-chunk
    /// network error already throws (propagating out of this whole function,
    /// and this function's caller-side `do`/`catch` in `AccountSyncer
    /// .performIncrementalSync` skips the mailbox without deleting
    /// anything), but every chunk coming back empty without throwing —
    /// plausible on a flaky real-world connection where the underlying
    /// transport surfaces "no error, no data" instead of a clean failure —
    /// would otherwise read as "every locally-known UID was expunged" and
    /// mass-delete a mailbox's entire synced window (cascading to `thread`
    /// rows too) even though nothing was actually deleted server-side.
    /// `status` (this pass's own fresh `SELECT`) is the guard: if it reports
    /// the mailbox still has messages but nothing came back across every
    /// chunk, that combination is far more likely a degraded/partial round
    /// trip than a real "expunge everything" event, so this bails out (no
    /// deletion) the same non-destructive way an outright thrown error
    /// already would — the next incremental sync gets another chance once
    /// the connection recovers.
    private func refetchAndDiffFlags(
        mailboxId: Int64,
        mailboxPath: String,
        accountId: String,
        session: any IMAPSessionProtocol,
        status: MailboxStatus,
        onProgress: (@Sendable (SyncProgressUpdate) -> Void)? = nil
    ) async throws -> Int {
        // `AND uid > 0` (Task #120): a `MessageRecord.isPendingRelocation`
        // row's synthetic negative placeholder UID must never enter this
        // diff — it isn't a real server UID at all (so it can't legitimately
        // be "vanished"), and `UInt32(minUID)` below would trap outright if
        // one ever became the minimum (the common case, since a placeholder
        // is always negative and therefore always smaller than every real
        // UID in the same mailbox).
        let localFlagsByUID = try await database.dbWriter.read { db -> [Int64: Int] in
            var result: [Int64: Int] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT uid, flagsRaw FROM message WHERE mailboxId = ? AND uid > 0", arguments: [mailboxId])
            for row in rows {
                result[row["uid"]] = row["flagsRaw"]
            }
            return result
        }
        guard let minUID = localFlagsByUID.keys.min() else { return 0 }

        let localMaxUID = UInt32(clamping: localFlagsByUID.keys.max() ?? minUID)
        let serverUpperBound = status.uidNext > 0 ? UInt32(clamping: status.uidNext - 1) : localMaxUID
        let fullRange = UIDRange(lowerBound: UInt32(clamping: minUID), upperBound: max(localMaxUID, serverUpperBound))

        // Task #120 (実機バグ「iCloud の Archive メールボックスの同期が毎回
        // UNIQUE constraint failed で失敗する」): `reconcilePendingRelocation`
        // (inside `AccountSyncer.upsert`, called for every envelope this
        // mailbox refetches) matches a pending placeholder row against the
        // server's confirmed envelope by *messageId* — data a flags-only
        // fetch never has. The fast path below only reaches `upsert` for a
        // UID it doesn't already recognize locally (see `unknownUIDs`
        // further down), which is exactly wrong here: a pending row's real
        // UID can easily coincide with a UID *already* present locally as a
        // genuine, independently-synced duplicate (this file's own
        // `MessageRelocationReconciliationTests` scenario) — in that case
        // the confirmed UID is "known" (it's the real row), its flags
        // already match, and the fast path would never call `upsert` at
        // all, silently leaving the pending row orphaned forever instead of
        // merging it. Checked once, cheaply, before doing anything else:
        // pending rows are transient (only exist in the narrow window
        // between a local move and the server confirming it), so this
        // should be rare in practice — when it does happen, correctness
        // (no orphaned/duplicate row) matters far more than this one pass's
        // payload size, so this falls back to a full, `AccountSyncer.upsert`
        // -driven re-fetch-and-diff for the whole window instead of the
        // flags-only fast path.
        let hasPendingRelocations = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == mailboxId).filter(Column("uid") <= 0).fetchCount(db) > 0
        }
        if hasPendingRelocations {
            Self.logger.notice(
                "refetchAndDiffFlags: \(mailboxPath, privacy: .public) has pending-relocation row(s) — falling back to a full envelope re-fetch for this pass"
            )
            return try await legacyFullRefetchAndDiffFlags(
                mailboxId: mailboxId,
                mailboxPath: mailboxPath,
                accountId: accountId,
                session: session,
                status: status,
                localUIDs: Array(localFlagsByUID.keys),
                fullRange: fullRange
            )
        }

        // Chunked by *count* of locally-known UIDs, not by numeric UID span
        // (`fullRange`, still computed above purely for
        // `legacyFullRefetchAndDiffFlags`'s bounded fallback fetch) — a
        // sparse UID space (Gmail-shaped accounts especially, where
        // archived/expunged messages leave large numeric gaps) can turn a
        // few hundred locally-known messages spread across a huge UID range
        // into many mostly-empty range-based chunks, each still a full round
        // trip for a handful of UIDs. Chunking the actual known UIDs
        // directly instead means every chunk (except possibly the last)
        // always carries exactly `AccountSyncer.fetchBatchSize` UIDs
        // worth of work regardless of how the UID space is laid out —
        // `fetchFlags(mailboxPath:uids: UIDSet)` lets this address the
        // scattered set directly, and `MCOIndexSet`
        // still coalesces whatever contiguous runs a chunk happens to
        // contain into IMAP range syntax on the wire, so a chunk that turns
        // out dense costs no more than the old range-based chunk did.
        let sortedLocalUIDs = localFlagsByUID.keys.sorted().map { UInt32(clamping: $0) }
        let chunks = Self.chunkUIDs(sortedLocalUIDs, size: AccountSyncer.fetchBatchSize)

        // Task #194: real-device diagnostics for "Pull to refresh が長すぎて
        // 終わらない" — this is the path that used to make a single
        // unbounded FETCH, so knowing *how many UIDs*/*how long* it actually
        // takes on a real account is exactly what a Console pull needs to
        // confirm the fix helped (or, on an account this large, whether it
        // still doesn't finish fast enough and needs a further change).
        // notice-level (not debug): matches `Self.logger`'s existing
        // call sites in this file. No message content/credentials — only
        // counts, the mailbox path, and elapsed time.
        let startedAt = Date()
        Self.logger.notice(
            "refetchAndDiffFlags: starting \(mailboxPath, privacy: .public) localUIDs=\(localFlagsByUID.count, privacy: .public) chunks=\(chunks.count, privacy: .public)"
        )
        defer {
            let elapsed = Date().timeIntervalSince(startedAt)
            Self.logger.notice(
                "refetchAndDiffFlags: finished \(mailboxPath, privacy: .public) elapsed=\(elapsed, format: .fixed(precision: 2), privacy: .public)s"
            )
        }

        var serverUIDs = Set<Int64>()
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let fetchedFlags = try await session.fetchFlags(mailboxPath: mailboxPath, uids: UIDSet(chunk))

            if !fetchedFlags.isEmpty {
                serverUIDs.formUnion(fetchedFlags.keys.map(Int64.init))
                // See `applyFlagsDiffAndReconcileUnknown`'s doc comment for
                // the "known locally, flags differ" vs. "unknown to this
                // pass's local snapshot" split this delegates to — shared
                // with `MailboxSyncer.incrementalSync`'s CONDSTORE
                // flags-only fast path, which needs the exact same Task
                // #120 pending-relocation handling.
                _ = try await applyFlagsDiffAndReconcileUnknown(
                    mailboxId: mailboxId,
                    mailboxPath: mailboxPath,
                    accountId: accountId,
                    session: session,
                    fetchedFlags: fetchedFlags,
                    localFlagsByUID: localFlagsByUID,
                    logContext: "refetchAndDiffFlags"
                )
            }
            // Reported only after this chunk's write has actually committed
            // — `completed: N` means "N chunks' worth of flag changes are
            // durably applied", not merely fetched, so a caller watching
            // this progress and then cancelling sees a state that's exactly
            // as far along as it looks.
            onProgress?(SyncProgressUpdate(mailboxPath: mailboxPath, phase: .flagSync, completed: index + 1, total: chunks.count))
            try Task.checkCancellation()
        }

        guard !(serverUIDs.isEmpty && status.messageCount > 0) else { return 0 }

        let deletedUIDs = Set(localFlagsByUID.keys).subtracting(serverUIDs)
        return try await deleteMessages(mailboxId: mailboxId, uids: deletedUIDs)
    }

    /// Shared by `refetchAndDiffFlags` (non-CONDSTORE) and
    /// `condstoreFlagChangeSync` (CONDSTORE's own flags-only fast path):
    /// given one batch of freshly-fetched `(uid → flags)` pairs and the
    /// caller's already-loaded local flags snapshot, splits it into "known
    /// locally, flags actually differ" (cheap — a targeted `applyFlagsOnly`
    /// update) vs. "unknown to this pass's local snapshot at all". The
    /// latter should be rare — almost always Task #120's case: a
    /// `MessageRecord.isPendingRelocation` placeholder's real UID finally
    /// confirmed by the server. Reconciling that requires
    /// `EnvelopePersister.upsert`'s `reconcilePendingRelocation` step, which
    /// matches by `messageId` — not available from a flags-only fetch — so
    /// this subset gets a real (small, scoped-to-just-these-UIDs) envelope
    /// re-fetch instead. Losing this would silently break Task #120: the
    /// placeholder would never reconcile, and `applyFlagsOnly` finding no
    /// local row to update would look like nothing happened at all rather
    /// than throwing.
    ///
    /// Returns how many UIDs were touched (changed + reconciled), for a
    /// caller that tracks a `flagChanges` count (`condstoreFlagChangeSync`
    /// does; `refetchAndDiffFlags` doesn't and discards it, matching its
    /// pre-existing behavior).
    private func applyFlagsDiffAndReconcileUnknown(
        mailboxId: Int64,
        mailboxPath: String,
        accountId: String,
        session: any IMAPSessionProtocol,
        fetchedFlags: [UInt32: MessageFlags],
        localFlagsByUID: [Int64: Int],
        logContext: String
    ) async throws -> Int {
        // 実機報告「一括アーカイブ後、再読み込みすると復活する」/「既読に
        // したのに未読へ戻る」: 未送信のローカル変更がある UID は、サーバー
        // 側の状態がまだ古いと分かっているので、フラグ上書き
        // (`changedUIDs`) にも取りこぼし再取得 (`unknownUIDs` — 復活の
        // 直接の経路だった) にも入れない。判断理由は`PendingOpTargets`の
        // doc comment 参照。
        let pendingTargets = try await database.dbWriter.read { db in
            try PendingOpTargets.forMailbox(mailboxId: mailboxId, accountId: accountId, db: db)
        }
        var changedUIDs: [(uid: Int64, flags: MessageFlags)] = []
        var unknownUIDs: [UInt32] = []
        var skippedPendingCount = 0
        for (uid, flags) in fetchedFlags {
            let uid64 = Int64(uid)
            if pendingTargets.blocks(uid: uid64) {
                skippedPendingCount += 1
                continue
            }
            if let existingFlags = localFlagsByUID[uid64] {
                if existingFlags != flags.rawValue {
                    changedUIDs.append((uid64, flags))
                }
            } else {
                unknownUIDs.append(uid)
            }
        }
        if skippedPendingCount > 0 {
            Self.logger.notice(
                "\(logContext, privacy: .public): \(mailboxPath, privacy: .public) skipped \(skippedPendingCount, privacy: .public) UID(s) with unsent local changes still in opQueue"
            )
        }

        if !changedUIDs.isEmpty {
            // `let` snapshot: `DatabaseWriter.write`'s closure is
            // `@Sendable`, and capturing the `var` built by the loop above
            // directly is rejected under Swift 6 strict concurrency (same
            // reasoning as this file's other `database.dbWriter.write` call
            // sites' identical doc comments).
            let changedUIDsSnapshot = changedUIDs
            try await database.dbWriter.write { db in
                for (uid64, flags) in changedUIDsSnapshot {
                    try Self.applyFlagsOnly(mailboxId: mailboxId, uid: uid64, flags: flags, db: db)
                }
            }
        }

        if !unknownUIDs.isEmpty {
            Self.logger.notice(
                "\(logContext, privacy: .public): \(mailboxPath, privacy: .public) reconciling \(unknownUIDs.count, privacy: .public) UID(s) unknown to this pass's local snapshot (pending-relocation confirmation or a gap in an earlier step)"
            )
            if unknownUIDs.count > 1000 {
                Self.logger.notice(
                    "\(logContext, privacy: .public): \(mailboxPath, privacy: .public) unusually large unknown-UID reconciliation (\(unknownUIDs.count, privacy: .public) UIDs) — possible local/server drift"
                )
            }
            // Chunked `UIDSet` fetches, not a single `min...max` `UIDRange`
            // (this used to build one): a sparse, scattered handful of
            // unknown UIDs (Gmail-shaped mailboxes especially, where
            // archived/expunged messages leave large numeric gaps between
            // surviving UIDs) could turn `unknownUIDs.min()!...max()!` into
            // a range spanning nearly the entire mailbox, fetching
            // thousands of already-known envelopes just to reconcile a
            // handful of genuinely unknown ones — the same unbounded-fetch
            // shape Task #194 already fixed for `refetchAndDiffFlags`'s own
            // flags-only window. `fetchEnvelopes(mailboxPath:uids: UIDSet)`
            // addresses exactly `unknownUIDs`; `Self.chunkUIDs` (shared with
            // `refetchAndDiffFlags`) keeps each chunk's cost bounded and
            // gives a very large reconciliation the same per-chunk
            // cancellation checkpoint `refetchAndDiffFlags` already has.
            let chunks = Self.chunkUIDs(unknownUIDs.sorted(), size: AccountSyncer.fetchBatchSize)
            var unknownEnvelopes: [FetchedEnvelope] = []
            for chunk in chunks {
                try Task.checkCancellation()
                let batch = try await session.fetchEnvelopes(mailboxPath: mailboxPath, uids: UIDSet(chunk))
                unknownEnvelopes.append(contentsOf: batch)
            }
            let unknownSet = Set(unknownUIDs)
            // `let` snapshot for the same reason `changedUIDsSnapshot` above
            // needs one: `DatabaseWriter.write`'s closure is `@Sendable`,
            // and capturing the `var` this loop built directly is rejected
            // under Swift 6 strict concurrency.
            let unknownEnvelopesSnapshot = unknownEnvelopes
            // `unknownUIDs`は上で`pendingTargets`済みのものを除いてある
            // が、フェッチ往復の間に新しい op が積まれている可能性がある
            // ので、書き込み時点の`opQueue`でもう一度見る (この`write`
            // ブロック内で1回だけ組み立てる)。
            try await database.dbWriter.write { db in
                let writeTimeTargets = try PendingOpTargets.forMailbox(mailboxId: mailboxId, accountId: accountId, db: db)
                for envelope in unknownEnvelopesSnapshot where unknownSet.contains(envelope.uid) {
                    try EnvelopePersister.upsert(envelope: envelope, mailboxId: mailboxId, accountId: accountId, pendingTargets: writeTimeTargets, db: db)
                }
            }
        }

        return changedUIDs.count + unknownUIDs.count
    }

    /// Task #120 fallback path — see `refetchAndDiffFlags`'s
    /// `hasPendingRelocations` doc comment for why this exists at all.
    /// Verbatim the pre-Task-#194 behavior: a full `ENVELOPE`/`FLAGS`
    /// re-fetch of `fullRange` (still bounded, so `fetchEnvelopes`'s own
    /// internal `batchSize` chunking actually applies — unlike the original
    /// bug's open-ended range), unconditionally `AccountSyncer.upsert`ing
    /// every result (which runs `reconcilePendingRelocation` first, the
    /// whole reason this path exists), then diffing UIDs the same way
    /// `refetchAndDiffFlags` does to find server-side deletions.
    private func legacyFullRefetchAndDiffFlags(
        mailboxId: Int64,
        mailboxPath: String,
        accountId: String,
        session: any IMAPSessionProtocol,
        status: MailboxStatus,
        localUIDs: [Int64],
        fullRange: UIDRange
    ) async throws -> Int {
        let refetched = try await session.fetchEnvelopes(
            mailboxPath: mailboxPath,
            uids: fullRange,
            batchSize: AccountSyncer.fetchBatchSize
        )
        guard !(refetched.isEmpty && status.messageCount > 0) else { return 0 }

        try await database.dbWriter.write { db in
            let pendingTargets = try PendingOpTargets.forMailbox(mailboxId: mailboxId, accountId: accountId, db: db)
            for envelope in refetched {
                try EnvelopePersister.upsert(envelope: envelope, mailboxId: mailboxId, accountId: accountId, pendingTargets: pendingTargets, db: db)
            }
        }

        let serverUIDs = Set(refetched.map { Int64($0.uid) })
        let deletedUIDs = Set(localUIDs).subtracting(serverUIDs)
        return try await deleteMessages(mailboxId: mailboxId, uids: deletedUIDs)
    }

    /// Splits `uids` (expected sorted, though this doesn't require it) into
    /// consecutive sub-arrays of at most `size` elements — the count-based
    /// counterpart of the numeric-range chunking `MailTransportMailCore`'s
    /// private `MailCoreIMAPSession.chunk` does for a dense `UIDRange`.
    /// `refetchAndDiffFlags` uses this (rather than delegating to an opaque
    /// batched call the way every other `fetchEnvelopes` call site does) so
    /// it can drive its own per-chunk progress/cancellation checkpoints, and
    /// so a sparse UID space doesn't inflate the chunk count the way
    /// chunking by numeric span would (see that method's doc comment).
    private static func chunkUIDs(_ uids: [UInt32], size: Int) -> [[UInt32]] {
        guard !uids.isEmpty else { return [] }
        let step = max(1, size)
        var chunks: [[UInt32]] = []
        var index = 0
        while index < uids.count {
            let end = min(index + step, uids.count)
            chunks.append(Array(uids[index..<end]))
            index = end
        }
        return chunks
    }

    /// Applies a `refetchAndDiffFlags`-diffed flag change without
    /// `AccountSyncer.upsert`'s full envelope rewrite — a flag-only change
    /// touches none of the subject/from/body-adjacent columns `FTSIndexer
    /// .reindex` cares about, so skipping it here (unlike `upsert`, which
    /// always reindexes) is safe as long as this only ever runs for a
    /// genuinely flags-only diff. Mirrors `AccountSyncer.upsert`'s pin-sync
    /// (E9, Task #212 で常時オン化) handling verbatim: `isPinnedLocal`
    /// always follows the server's `\Flagged` bit.
    /// A no-op if the row isn't found locally — possible only for a UID
    /// that arrived between step 1's new-mail fetch and this step's own
    /// snapshot of `localFlagsByUID` (a narrow race); that message simply
    /// gets picked up as "new mail" on the *next* incremental sync pass
    /// instead, no data lost.
    private static func applyFlagsOnly(mailboxId: Int64, uid: Int64, flags: MessageFlags, db: Database) throws {
        guard var record = try MessageRecord
            .filter(Column("mailboxId") == mailboxId)
            .filter(Column("uid") == uid)
            .fetchOne(db)
        else { return }

        record.flagsRaw = flags.rawValue
        record.isPinnedLocal = flags.contains(.flagged)
        record.updatedAt = Date()

        try record.update(db, columns: [Column("flagsRaw"), Column("updatedAt"), Column("isPinnedLocal")])

        if let threadId = record.threadId {
            try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
        }
    }

    /// Task #79's CONDSTORE-path fallback: a cheap `UID SEARCH` over the
    /// synced window (from the lowest locally-stored UID onward — same
    /// `UIDRange.from`-open-ended shape `refetchAndDiffFlags` uses, so it
    /// also covers step 1's just-added new mail) to learn which
    /// locally-stored UIDs the server no longer has, without paying for a
    /// full envelope re-fetch of that whole window the way the
    /// non-CONDSTORE path must. Used whenever `fetchEnvelopes(changedSince:)`
    /// couldn't report vanished UIDs itself via QRESYNC
    /// (`ChangedSinceResult.vanishedUIDs == nil`) — Gmail's case, confirmed
    /// CONDSTORE-only.
    ///
    /// Same non-destructive guard as `refetchAndDiffFlags`, and for the same
    /// reason: only deletes when the `UID SEARCH` actually completes (a
    /// thrown error already propagates out of `incrementalSync` entirely,
    /// deleting nothing), and treats a search that comes back with *no*
    /// UIDs at all while `status` still reports the mailbox as non-empty as
    /// a suspicious/degraded response rather than "every locally-known UID
    /// was expunged".
    private func detectAndRemoveVanishedByUIDSearch(
        mailboxId: Int64,
        mailboxPath: String,
        session: any IMAPSessionProtocol,
        status: MailboxStatus
    ) async throws -> Int {
        try Task.checkCancellation()
        // `AND uid > 0` — same Task #120 reasoning as `refetchAndDiffFlags`'s
        // identical guard just above.
        let localUIDs = try await database.dbWriter.read { db in
            try Int64.fetchAll(db, sql: "SELECT uid FROM message WHERE mailboxId = ? AND uid > 0", arguments: [mailboxId])
        }
        guard let minUID = localUIDs.min() else { return 0 }

        let serverUIDs = try await session.searchExistingUIDs(
            mailboxPath: mailboxPath,
            uids: UIDRange(lowerBound: UInt32(minUID), upperBound: nil)
        )
        guard !(serverUIDs.isEmpty && status.messageCount > 0) else {
            Self.logger.notice(
                "reconcile: suspicious empty UID SEARCH for \(mailboxPath, privacy: .public) (server reports messageCount=\(status.messageCount, privacy: .public)) — skipping deletion this pass"
            )
            return 0
        }

        let deletedUIDs = Set(localUIDs).subtracting(serverUIDs.map(Int64.init))
        let deletedCount = try await deleteMessages(mailboxId: mailboxId, uids: deletedUIDs)
        Self.logger.notice(
            "reconcile: \(mailboxPath, privacy: .public) serverUIDs=\(serverUIDs.count, privacy: .public) localUIDs=\(localUIDs.count, privacy: .public) deleted=\(deletedCount, privacy: .public)"
        )
        return deletedCount
    }

    /// Deletes every `message` row in `mailboxId` whose `uid` is in `uids`
    /// (a no-op, safely, for any `uid` not actually stored locally — both
    /// `refetchAndDiffFlags` and `detectAndRemoveVanishedByUIDSearch`
    /// diff against server state that may not perfectly overlap what's
    /// stored, e.g. QRESYNC's vanished set can include UIDs outside this
    /// mailbox's currently-synced window), cleaning up the FTS index (M7:
    /// no foreign key to `message`, since it's a virtual table) and
    /// recomputing thread aggregates the same way the uidValidity-change
    /// full resync above does. Returns how many rows were actually deleted.
    private func deleteMessages(mailboxId: Int64, uids: Set<Int64>) async throws -> Int {
        guard !uids.isEmpty else { return 0 }
        return try await database.dbWriter.write { db in
            let doomed = try MessageRecord
                .filter(Column("mailboxId") == mailboxId)
                .filter(uids.contains(Column("uid")))
                .fetchAll(db)
            guard !doomed.isEmpty else { return 0 }
            try FTSIndexer.deleteAll(messageIds: doomed.compactMap(\.id), db: db)
            try MessageRecord
                .filter(Column("mailboxId") == mailboxId)
                .filter(uids.contains(Column("uid")))
                .deleteAll(db)
            try ThreadAssigner.recomputeAggregates(forThreadsAmong: doomed, db: db)
            return doomed.count
        }
    }
}
