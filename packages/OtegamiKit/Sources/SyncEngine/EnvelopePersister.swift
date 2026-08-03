import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore

/// A fetched IMAP envelope's persistence step, pulled out of `AccountSyncer`
/// (which originally hosted this as `AccountSyncer.upsert`/
/// `AccountSyncer.reconcilePendingRelocation`) purely to keep that file's
/// size down — no behavior change from the move itself. Called from
/// `AccountSyncer.performInitialSync` and `MailboxSyncer`'s several
/// differential-sync paths (new mail, full-window resync, self-heal).
enum EnvelopePersister {
    /// Upserts one envelope's `message` row (keyed by `(mailboxId, uid)`)
    /// and replaces its `messageReference` rows wholesale (cheaper than
    /// diffing, and references rarely change for an already-seen message),
    /// then threads it (M4): a never-before-threaded message (`threadId ==
    /// nil`, whether brand new or a resync of a message inserted before
    /// M4's backfill ran) gets `ThreadAssigner.assignThread`; an
    /// already-threaded message (a flag-only resync) just gets its
    /// thread's aggregates recomputed, since the resync could have changed
    /// its `\Seen` flag.
    static func upsert(envelope: FetchedEnvelope, mailboxId: Int64, accountId: String, db: Database) throws {
        // Task #120: before the normal upsert-by-`(mailboxId, uid)` below,
        // check whether this envelope is the real, server-confirmed arrival
        // of a message `MessageRemoval` already relocated to this mailbox
        // ahead of the server (`MessageRecord.isPendingRelocation`) —
        // reconcile it onto the real UID *in place* rather than letting the
        // upsert insert a brand-new row alongside it (a visible duplicate:
        // the same message would show up twice in this mailbox's list).
        try reconcilePendingRelocation(envelope: envelope, mailboxId: mailboxId, db: db)

        // Task #221 (本文キャッシュ不当無効化バグ群): a resync (CONDSTORE's
        // own \Seen mirror included) must never make an already-detected
        // attachment disappear again — `BodyFetcher.performFetch` upgrades
        // `hasAttachments` from `false` to `true` once the body's
        // BODYSTRUCTURE parts are actually seen (envelope-time BODYSTRUCTURE
        // is not always reliable/present depending on server/fetch mode).
        // OR the existing row's value in *before* the upsert below runs
        // (rather than a SQL-level `MAX(...)` in the `doUpdate` closure) —
        // one extra indexed `(mailboxId, uid)` lookup, but keeps the
        // decision in plain Swift and easy to unit test.
        let existingHasAttachments = try MessageRecord
            .filter(Column("mailboxId") == mailboxId)
            .filter(Column("uid") == Int64(envelope.uid))
            .select(Column("hasAttachments"), as: Bool.self)
            .fetchOne(db) ?? false

        // ピン留め (E9, Task #212 で常時オン化): every resync mirrors the
        // server's current `\Flagged` bit into `MessageRecord.isPinnedLocal`
        // — see that column's doc comment for the full design. This used to
        // be opt-in via a `PinSettingsStore.syncWithFlaggedKey` toggle
        // (default off); that toggle (and the Settings-UI row exposing it)
        // was removed, so this path is now unconditional.
        var record = MessageRecord(
            mailboxId: mailboxId,
            uid: Int64(envelope.uid),
            messageId: envelope.messageId,
            inReplyTo: envelope.inReplyTo,
            subject: envelope.subject,
            normalizedSubject: envelope.subject.map(SubjectNormalizer.normalize),
            fromAddresses: envelope.from,
            toAddresses: envelope.to,
            ccAddresses: envelope.cc,
            bccAddresses: envelope.bcc,
            replyToAddresses: envelope.replyTo,
            // M7: plain-text mirror of `fromAddresses` for
            // `FTSIndexer`/`SearchQuery` — see `MessageRecord.fromText`'s
            // doc comment for why `fromAddresses` itself (JSON in a `.blob`
            // column) can't serve that purpose directly.
            fromText: FTSIndexer.composeFromText(envelope.from),
            // 新画面構成: `to:`/`cc:` 検索演算子用 — see `MessageRecord.toText`/
            // `.ccText`'s doc comment.
            toText: FTSIndexer.composeFromText(envelope.to),
            ccText: FTSIndexer.composeFromText(envelope.cc),
            date: envelope.date,
            internalDate: envelope.internalDate,
            flagsRaw: envelope.flags.rawValue,
            size: envelope.size,
            gmailThreadId: envelope.gmailThreadId.map { Int64(bitPattern: $0) },
            gmailMessageId: envelope.gmailMessageId.map { Int64(bitPattern: $0) },
            hasAttachments: envelope.hasAttachments || existingHasAttachments,
            isPinnedLocal: envelope.flags.contains(.flagged),
            updatedAt: Date()
        )
        // `createdAt` is excluded from the update side of the upsert so a
        // resync doesn't overwrite the original insert timestamp.
        // `threadId` is also excluded: an already-threaded message's
        // thread assignment must survive a resync (only the code below,
        // via `ThreadAssigner`, is allowed to change it).
        //
        // Task #221: `bodyState`/`snippet`/`detectedLanguage` are also
        // excluded — these three only ever move forward via
        // `BodyFetcher.performFetch` (the actual body fetch) or the
        // `.fetching`-reset self-heal (`BodyCacheStateReconciler
        // .resetStuckFetchingStates`), never via an envelope-only resync.
        // Before this fix, *any* envelope upsert of an already-`.fetched`
        // row — most commonly CONDSTORE mirroring this device's own
        // `\Seen` flip back down after reading a message — reset
        // `bodyState` to `MessageRecord.init`'s default (`.notFetched`),
        // silently discarding a perfectly good cached body: the next open
        // (or the up-to-200-message prefetch pass) would then re-download
        // it from scratch for no reason. `MailboxSyncer.applyFlagsOnly`'s
        // column-limited `update(db, columns:)` never had this problem —
        // this brings the CONDSTORE/full-envelope path up to the same
        // "flags-only resync never touches body state" contract.
        record = try record.upsertAndFetch(db, onConflict: ["mailboxId", "uid"]) { _ in
            [
                Column("createdAt").noOverwrite,
                Column("threadId").noOverwrite,
                Column("bodyState").noOverwrite,
                Column("snippet").noOverwrite,
                Column("detectedLanguage").noOverwrite,
            ]
        }
        guard let messageId = record.id else { return }

        try MessageReferenceRecord
            .filter(Column("messageId") == messageId)
            .deleteAll(db)
        for (index, reference) in envelope.references.enumerated() {
            var referenceRecord = MessageReferenceRecord(messageId: messageId, referenceValue: reference, position: index)
            try referenceRecord.insert(db)
        }

        if record.threadId == nil {
            _ = try ThreadAssigner.assignThread(messageId: messageId, accountId: accountId, db: db)
        } else if let threadId = record.threadId {
            try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
        }

        // M7: keeps `messageSearchIndex` current with the just-upserted
        // subject/fromText (and, on a resync of an already-body-fetched
        // message, whatever `messageBody.plainText` already has —
        // `FTSIndexer.reindex` reads it back rather than this call site
        // threading it through, so a flag-only resync can't accidentally
        // blow away a previously-indexed body).
        try FTSIndexer.reindex(messageId: messageId, db: db)
    }

    /// Task #120: the reconciliation half of `MessageRemoval`'s "relocate
    /// immediately, ahead of the server" local moves. Looks for a
    /// `MessageRecord.isPendingRelocation` row already sitting in
    /// `mailboxId` whose `messageId` matches this envelope's — i.e. the
    /// exact message a prior archive/unarchive/junk/delete already moved
    /// here locally, now genuinely confirmed by the server — and, if found,
    /// repoints *that same row* onto the real UID `envelope.uid` before
    /// `upsert`'s own `(mailboxId, uid)`-keyed upsert runs.
    ///
    /// This matters because that follow-up upsert can only ever match an
    /// existing row by the exact `(mailboxId, uid)` pair its `onConflict`
    /// targets — a placeholder's synthetic negative UID never equals a real
    /// one, so without this step the upsert would simply insert a *second*,
    /// duplicate row for the same message (the placeholder would then sit
    /// there forever, orphaned, since nothing else ever revisits it). Doing
    /// the repoint here first means that same upsert call, immediately
    /// after, finds a genuine `(mailboxId, uid)` conflict against the
    /// now-real-UID row and updates it in place instead — the message's
    /// `id` (and everything keyed by it: thread assignment, cached body/
    /// attachments, translation state, FTS index) never changes.
    ///
    /// A no-op when `envelope.messageId` is `nil`/empty (can't reliably
    /// match) — a message without a `Message-ID` header is rare, and this
    /// app has no other cross-mailbox identity to match on. That pending
    /// row is left as-is: still visible to the user (it was never lost),
    /// just permanently a placeholder UID (see `MessageRecord
    /// .isPendingRelocation`'s doc comment for the accepted-limitation call
    /// sites that already treat a placeholder gracefully rather than
    /// crashing on it).
    ///
    /// Task #183 (実機報告「iCloud の Archive メールボックスの同期が毎回
    /// `UNIQUE constraint failed: message.mailboxId, message.uid` で失敗する」):
    /// this used to blindly rewrite the single matching pending row's `uid`
    /// onto `envelope.uid` without first checking whether that exact
    /// `(mailboxId, uid)` slot was already occupied by a genuine, already-
    /// reconciled (or independently-synced) row for the same message —
    /// tripping the uniqueness constraint every single sync pass once that
    /// happened, with no way for the device to self-heal (the pending row
    /// was never cleaned up, so the very next sync hit the exact same
    /// conflict again). Now handled two ways, both delegating the actual
    /// merge/discard policy to `MessageRelocationConflict` (the same policy
    /// `AccountDuplicateMerger.mergeCollidingMailbox` already established):
    /// - A genuine row already sits at `(mailboxId, envelope.uid)`: every
    ///   matching pending row is a redundant leftover placeholder (self-
    ///   heals a device that already hit this bug before this fix shipped
    ///   and so already has one or more orphaned pending rows) — merged
    ///   forward into that row and discarded, no `uid` rewrite attempted.
    /// - No genuine row there yet (the common, non-broken case): among the
    ///   (usually exactly one, but possibly more on an already-broken
    ///   device) matching pending rows, the most recently updated one wins
    ///   the real `uid`; any others are merged into it and discarded first.
    private static func reconcilePendingRelocation(envelope: FetchedEnvelope, mailboxId: Int64, db: Database) throws {
        guard let messageId = envelope.messageId, !messageId.isEmpty else { return }
        let pendingRows = try MessageRecord
            .filter(Column("mailboxId") == mailboxId)
            .filter(Column("uid") <= 0)
            .filter(Column("messageId") == messageId)
            .fetchAll(db)
        guard !pendingRows.isEmpty else { return }

        let realUID = Int64(envelope.uid)
        var affectedThreadIds: Set<Int64> = []

        if var existing = try MessageRecord
            .filter(Column("mailboxId") == mailboxId)
            .filter(Column("uid") == realUID)
            .fetchOne(db) {
            for pending in pendingRows {
                affectedThreadIds.formUnion(try MessageRelocationConflict.mergeAndDiscard(mover: pending, into: &existing, db: db))
            }
        } else {
            // `pendingRows` is non-empty (checked above), so `max` never
            // returns `nil` here.
            var winner = pendingRows.max { $0.updatedAt < $1.updatedAt }!
            for pending in pendingRows where pending.id != winner.id {
                affectedThreadIds.formUnion(try MessageRelocationConflict.mergeAndDiscard(mover: pending, into: &winner, db: db))
            }
            winner.uid = realUID
            try winner.update(db, columns: [Column("uid"), Column("isPinnedLocal"), Column("flagsRaw"), Column("detectedLanguage")])
        }

        for threadId in affectedThreadIds {
            try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
        }
    }
}
