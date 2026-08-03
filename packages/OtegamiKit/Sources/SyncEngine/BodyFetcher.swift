import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore

/// Lazy body fetch (M2): downloads and persists one message's body via an
/// already-connected `IMAPSessionProtocol` session, and prioritizes which
/// messages get fetched first (recent-first prefetch after initial sync,
/// on-open fetch when a message is actually read).
///
/// Unlike `AccountSyncer`, `BodyFetcher` owns no IMAP connection of its
/// own — callers (`AccountSyncer`'s post-initial-sync prefetch,
/// `SyncCoordinator`'s on-open fetch) hand it a session that's already
/// `connect`ed and has the right mailbox `select`ed, so a batch of fetches
/// (e.g. the 50-message prefetch) reuses one connection instead of paying
/// a fresh IMAP handshake per message.
public actor BodyFetcher {
    /// How many of a mailbox's most-recently-received not-yet-fetched
    /// messages `AccountSyncer` prefetches right after initial sync (plan:
    /// "直近50件を優先度順に先読み").
    public static let defaultPrefetchLimit = 50

    private let database: AppDatabase

    /// Tracks a fetch currently in progress for a given `MessageRecord.id`
    /// — Task #31 (launch/foreground background prefetch): once that
    /// prefetch pass and the on-open lazy fetch (`SyncCoordinator.fetchBody
    /// (for:mailboxPath:account:auth:)`) can both race to fetch the same
    /// message, actor reentrancy alone isn't enough to prevent a duplicate
    /// network fetch — `fetchBody` below can suspend at `await session
    /// .fetchBody(...)`, and a second call for the same `messageId` could
    /// otherwise enter the actor and start its own independent fetch during
    /// that suspension. A second caller for a `messageId` already in this
    /// dictionary awaits the *same* `Task` instead of starting a new one.
    private var inFlightFetches: [Int64: Task<Void, Error>] = [:]

    /// Every `MessageRecord.id` self-healing has already been *attempted*
    /// for (whatever the outcome), scoped to this `BodyFetcher` instance's
    /// lifetime — one per `SyncCoordinator`/`AccountSyncer`, i.e. effectively
    /// the whole app session. 実機報告「同じメールが何度開き直しても・再起動しても
    /// 本文取得に失敗する (MailCoreErrorDomain error 19)」turned out to be a
    /// stale local `(mailboxId, uid)`: another client archived/moved/deleted
    /// the message server-side, so every retry re-fetches a UID the server
    /// now legitimately `NO`s forever. `performFetch`'s catch below reacts to
    /// that *once* per message — confirms the staleness, repoints or cleans
    /// up, and never repeats the confirmation dance for the same id again —
    /// rather than re-running a `UID SEARCH`-equivalent round trip (and,
    /// worse, re-attempting a repoint against an already-merged-away
    /// counterpart row) on every single prefetch pass or re-open thereafter.
    private var selfHealAttempted: Set<Int64> = []

    /// What `attemptSelfHeal(message:mailboxPath:session:messageId:
    /// originalError:)` decided, for `performFetch`'s catch block to act on.
    private enum SelfHealOutcome {
        /// Repointed to the message's real location and the retried fetch
        /// there succeeded — the row is fully up to date; nothing else to
        /// do, and no error to surface.
        case healed
        /// Confirmed gone everywhere the account knows about; the row (and
        /// its thread aggregate) was cleaned up locally. Not an error the
        /// user can act on by retrying, so nothing is surfaced either.
        case cleanedUp
        /// Repointing succeeded, but the retried fetch at the corrected
        /// location itself failed (a *new*, genuinely current error) —
        /// surfaced to the caller like any other fetch failure.
        case failed(Error)
        /// Self-healing doesn't apply (not a `serverError`, already
        /// attempted for this message, the existence check itself was
        /// inconclusive, or the UID turned out to still exist after all) —
        /// the caller should fall back to the original revert-and-rethrow
        /// behavior.
        case notApplicable
    }

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Fetches and persists `message`'s body: upserts `messageBody`
    /// (`plainText`/`html`), replaces its `attachment` rows, and updates
    /// `message.bodyState`/`snippet`. Sets `bodyState` to `.fetching`
    /// before the network call so a concurrent viewer (on-open fetch
    /// racing the prefetch pass for the same message) can tell a fetch is
    /// already underway; on failure, reverts to `.notFetched` and rethrows
    /// so the caller can surface the error.
    ///
    /// Always (re-)fetches over the network, even if `message.bodyState`
    /// is already `.fetched` — `prefetchRecent`'s own re-fetch contract
    /// (a message's body/attachments get *replaced*, not skipped, on a
    /// second call) and `SyncCoordinator`'s on-open/compose-quote paths
    /// both rely on this to force a refresh on demand. Callers that want
    /// an "already fetched? skip" check (Task #31's launch/foreground
    /// prefetch — see `SyncCoordinator
    /// .prefetchUnifiedInboxBodiesIfNeeded`) do that themselves, re-reading
    /// fresh state right before calling in, rather than this shared entry
    /// point silently no-op'ing for every caller.
    public func fetchBody(
        message: MessageRecord,
        mailboxPath: String,
        session: any IMAPSessionProtocol
    ) async throws {
        guard let messageId = message.id else { return }
        // Task #120: a `MessageRecord.isPendingRelocation` row has no real
        // server UID yet — `UInt32(message.uid)` further down (both here and
        // in `attemptSelfHeal`) traps on a negative value, and even a
        // non-trapping conversion would just `UID FETCH` a number the server
        // never assigned. Nothing to fetch until this mailbox's next sync
        // reconciles the row onto its real UID (`AccountSyncer
        // .reconcilePendingRelocation`); surfacing this as a normal fetch
        // failure lets the caller's existing retry affordance apply rather
        // than hanging or crashing.
        guard !message.isPendingRelocation else {
            throw SyncEngineError.pendingRelocation(messageId: messageId)
        }

        if let existing = inFlightFetches[messageId] {
            try await existing.value
            return
        }

        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.performFetch(message: message, mailboxPath: mailboxPath, session: session, messageId: messageId)
        }
        inFlightFetches[messageId] = task
        defer { inFlightFetches[messageId] = nil }
        try await task.value
    }

    private func performFetch(
        message: MessageRecord,
        mailboxPath: String,
        session: any IMAPSessionProtocol,
        messageId: Int64
    ) async throws {
        try await database.dbWriter.write { db in
            var record = message
            record.bodyState = .fetching
            try record.update(db)
        }

        do {
            let content = try await session.fetchBody(mailboxPath: mailboxPath, uid: UInt32(message.uid))
            let plainText = Self.resolvePlainText(from: content)
            let snippet = SnippetBuilder.make(from: plainText)
            // M12 (docs/translation.md): detected once, right here, rather
            // than lazily when a list row or detail view first asks —
            // `MessageLanguageDetector` is cheap (`NLLanguageRecognizer`,
            // no LLM) so doing it inline with the body fetch that already
            // just happened doesn't meaningfully slow this down, and means
            // "is this an English message" is always already known by the
            // time any UI needs it.
            //
            // Task #203: uses `content.plainText`/`content.html` directly
            // (the raw MIME parts), not the already-resolved `plainText`
            // local above — `MessageLanguageDetector.detectWithFallback`
            // does its own plainText-then-HTML fallback (with a markup-
            // noise pre-filter), so it needs both raw candidates rather
            // than a single pre-picked one. `MessageView
            // .backfillDetectedLanguageIfNeeded` re-runs this same
            // fallback whenever a message is opened, so a wrong/missing
            // guess made here self-heals then even if it doesn't here.
            let detectedLanguage = Self.detectLanguage(plainText: content.plainText, html: content.html)

            try await database.dbWriter.write { db in
                try MessageBodyRecord.deleteOne(db, key: messageId)
                let body = MessageBodyRecord(
                    messageId: messageId,
                    plainText: plainText,
                    html: content.html,
                    fetchedAt: Date()
                )
                try body.insert(db)

                try AttachmentRecord.filter(Column("messageId") == messageId).deleteAll(db)
                for part in content.parts {
                    var attachment = AttachmentRecord(
                        messageId: messageId,
                        partId: part.partId,
                        filename: part.filename,
                        mimeType: part.mimeType,
                        mimeSubtype: part.mimeSubtype,
                        contentId: part.contentId,
                        isInline: part.contentId != nil && !part.isAttachment,
                        size: part.size
                    )
                    try attachment.insert(db)
                }

                var record = message
                record.bodyState = .fetched
                record.snippet = snippet
                record.detectedLanguage = detectedLanguage
                record.hasAttachments = record.hasAttachments || content.parts.contains { $0.isAttachment }
                record.updatedAt = Date()
                try record.update(db)

                // M7: the body just arrived, so this is exactly when
                // `messageSearchIndex.plainText` needs to catch up —
                // `AccountSyncer.upsert`'s envelope-time index write ran
                // with no body yet (subject/fromText only).
                try FTSIndexer.reindex(messageId: messageId, db: db)
            }
        } catch {
            switch await attemptSelfHeal(
                message: message, mailboxPath: mailboxPath, session: session,
                messageId: messageId, originalError: error
            ) {
            case .healed, .cleanedUp:
                return
            case .failed(let newError):
                // The row was already repointed to its real location (and,
                // on failure, `performFetch`'s own nested call already
                // reverted *that* record's `bodyState`) — reverting again
                // here with the stale `message` captured at the top of this
                // call would overwrite the just-repointed `mailboxId`/`uid`
                // straight back to the values that were just confirmed
                // gone. Just surface the new failure as-is.
                throw newError
            case .notApplicable:
                // Task #221: prefer reverting to `.fetched` over
                // `.notFetched` when this message still has a usable
                // cached body from a *previous* successful fetch — this
                // attempt's failure (offline, a transient server hiccup,
                // ...) shouldn't throw away a perfectly good cache just
                // because a refresh of it didn't go through. Only a body
                // at the current `renderVersion` counts as "usable" — a
                // stale-format one is exactly what `MessageBodyRecord
                // .currentRenderVersion`'s bump exists to force a re-fetch
                // of, so falling back to `.notFetched` there is correct,
                // not a regression. A message with no cached body at all
                // (the on-open first-ever fetch failing) still reverts to
                // `.notFetched` same as before.
                try? await database.dbWriter.write { db in
                    var record = message
                    if let cachedBody = try MessageBodyRecord.fetchOne(db, key: messageId),
                       cachedBody.renderVersion == MessageBodyRecord.currentRenderVersion {
                        record.bodyState = .fetched
                    } else {
                        record.bodyState = .notFetched
                    }
                    try record.update(db)
                }
                throw error
            }
        }
    }

    /// Reacts to a `fetchBody` failure that might be the "実機報告" UID-
    /// staleness case (see `selfHealAttempted`'s doc comment) rather than a
    /// genuine transient error: confirms the UID is actually gone from
    /// `mailboxPath` (never on the strength of a second, independent
    /// connection — the existence check reuses the exact same `session`
    /// that just got `NO`'d), then either repoints this message to where
    /// the account's other mailboxes already show the same `Message-ID`
    /// living, or — if nowhere does — quietly reconciles the local database
    /// to match reality. Only ever engages for `MailTransportError
    /// .serverError` (the shape `MailCoreErrorDomain error 19`/`MCOErrorFetch`
    /// surfaces as, per `MailCoreIMAPSession+Mapping.mapError`'s `default`
    /// branch) — every other error kind (`connectionFailed`, `cancelled`,
    /// ...) is left to the caller's existing revert-and-rethrow handling
    /// unchanged.
    private func attemptSelfHeal(
        message: MessageRecord,
        mailboxPath: String,
        session: any IMAPSessionProtocol,
        messageId: Int64,
        originalError: Error
    ) async -> SelfHealOutcome {
        guard let mailError = originalError as? MailTransportError, case .serverError = mailError else {
            return .notApplicable
        }
        guard !selfHealAttempted.contains(messageId) else { return .notApplicable }
        selfHealAttempted.insert(messageId)

        let uid = UInt32(message.uid)

        // Confirm this exact UID is actually gone from this mailbox before
        // concluding anything — a `serverError` for some *other* reason
        // (e.g. a malformed message tripping a parser bug) must not be
        // mistaken for staleness.
        let stillExists: Bool
        do {
            let envelopes = try await session.fetchEnvelopes(mailboxPath: mailboxPath, uids: .uid(uid), batchSize: 1)
            stillExists = envelopes.contains { $0.uid == uid }
        } catch {
            // The existence check itself failed (disconnect, timeout, the
            // server rejecting `UID FETCH` outright, ...) — an inconclusive
            // check is never treated as confirmation of staleness. This is
            // the safety condition docs/architecture.md's Known pitfalls
            // (an empty refetch must never be mistaken for "everything
            // vanished") makes load-bearing: only delete/repoint on a
            // *successful* existence check that came back empty, never on
            // "the check itself broke".
            return .notApplicable
        }
        guard !stillExists else {
            // Still there — whatever caused the fetch failure, it wasn't
            // this message's UID going stale. Nothing to self-heal.
            return .notApplicable
        }

        guard let mailboxAccountId = await accountId(forMailboxId: message.mailboxId) else {
            return .notApplicable
        }

        if let headerMessageId = message.messageId,
           let counterpart = await findCounterpart(
               messageId: headerMessageId, accountId: mailboxAccountId, excludingMailboxId: message.mailboxId
           ),
           let counterpartId = counterpart.id,
           let counterpartMailboxPath = await path(forMailboxId: counterpart.mailboxId) {
            return await repoint(
                messageId: messageId,
                counterpartId: counterpartId,
                counterpartMailboxPath: counterpartMailboxPath,
                originalMailboxPath: mailboxPath,
                session: session
            )
        }

        // Gone from here, and no other mailbox in this account has ever
        // seen this `Message-ID` either — genuinely vanished server-side
        // (deleted, or archived somewhere this account's `listMailboxes()`
        // never reported). An error banner the user can never resolve by
        // re-tapping "本文の取得に失敗しました" helps no one; reconcile locally
        // instead so it simply stops appearing.
        return await cleanUpVanishedMessage(messageId: messageId)
    }

    private func accountId(forMailboxId mailboxId: Int64) async -> String? {
        try? await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: mailboxId)?.accountId }
    }

    private func path(forMailboxId mailboxId: Int64) async -> String? {
        try? await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: mailboxId)?.path }
    }

    /// The same `Message-ID`, already synced into a *different* mailbox of
    /// this account — preferring the Gmail All Mail-role mailbox (`role =
    /// .all`) when there's a choice, since that's the one mailbox a Gmail
    /// account's `AccountSyncer.performInitialSync` (every selectable
    /// mailbox gets its own synced copy) is most likely to still have this
    /// message under, however it got filed/archived/labeled since. Purely a
    /// local-database lookup — no new IMAP round trip — since every
    /// selectable mailbox was already synced at least once by the time a
    /// message could go stale in the first place.
    private func findCounterpart(messageId: String, accountId: String, excludingMailboxId: Int64) async -> MessageRecord? {
        try? await database.dbWriter.read { db in
            try MessageRecord.fetchOne(
                db,
                sql: """
                    SELECT message.* FROM message
                    JOIN mailbox ON mailbox.id = message.mailboxId
                    WHERE mailbox.accountId = ?
                      AND message.messageId = ?
                      AND message.mailboxId != ?
                    ORDER BY CASE WHEN mailbox.role = ? THEN 0 ELSE 1 END, message.id ASC
                    LIMIT 1
                    """,
                arguments: [accountId, messageId, excludingMailboxId, MailboxRoleRecord.all.rawValue]
            )
        }
    }

    /// Repoints `messageId`'s row to `counterpartId`'s `(mailboxId, uid)` —
    /// the same physical message, already sitting correctly in another of
    /// this account's mailboxes — folding `counterpartId`'s local-only state
    /// (pin, flags) forward first and removing it, the same merge shape
    /// `AccountDuplicateMerger.mergeCollidingMailbox` uses for "two rows,
    /// one real message". `messageId`'s own row (and so its `id` — anything
    /// already holding a reference to it, e.g. an open detail view) is what
    /// survives, not `counterpartId`'s, matching `MessageRemoval`'s "restore
    /// the exact same `id`s" convention elsewhere in this package. Once
    /// repointed, retries the network fetch at the corrected location on the
    /// same `session` (re-`select`ing back to `originalMailboxPath`
    /// afterward regardless of outcome, so a caller looping over several
    /// messages in that mailbox — `prefetchRecent`/`SyncCoordinator
    /// .prefetchUnifiedInboxBodiesIfNeeded` — finds the connection back where
    /// it left it).
    private func repoint(
        messageId: Int64,
        counterpartId: Int64,
        counterpartMailboxPath: String,
        originalMailboxPath: String,
        session: any IMAPSessionProtocol
    ) async -> SelfHealOutcome {
        let repointed: MessageRecord
        do {
            guard let updated = try await database.dbWriter.write({ db -> MessageRecord? in
                guard var record = try MessageRecord.fetchOne(db, key: messageId),
                      let counterpart = try MessageRecord.fetchOne(db, key: counterpartId)
                else { return nil }

                let originalThreadId = record.threadId
                let counterpartThreadId = counterpart.threadId

                try FTSIndexer.delete(messageId: counterpartId, db: db)
                try MessageBodyRecord.deleteOne(db, key: counterpartId)
                try AttachmentRecord.filter(Column("messageId") == counterpartId).deleteAll(db)
                _ = try MessageRecord.deleteOne(db, key: counterpartId)

                record.mailboxId = counterpart.mailboxId
                record.uid = counterpart.uid
                record.isPinnedLocal = record.isPinnedLocal || counterpart.isPinnedLocal
                record.flagsRaw |= counterpart.flagsRaw
                record.updatedAt = Date()
                try record.update(db)
                try FTSIndexer.reindex(messageId: messageId, db: db)

                if let originalThreadId {
                    try ThreadAssigner.recomputeAggregates(threadId: originalThreadId, db: db)
                }
                if let counterpartThreadId, counterpartThreadId != originalThreadId {
                    try ThreadAssigner.recomputeAggregates(threadId: counterpartThreadId, db: db)
                }
                return record
            }) else {
                return .notApplicable
            }
            repointed = updated
        } catch {
            return .notApplicable
        }

        do {
            _ = try await session.select(counterpartMailboxPath)
            try await performFetch(message: repointed, mailboxPath: counterpartMailboxPath, session: session, messageId: messageId)
            _ = try? await session.select(originalMailboxPath)
            return .healed
        } catch {
            _ = try? await session.select(originalMailboxPath)
            return .failed(error)
        }
    }

    /// Removes `messageId`'s row (and its body/attachments/search-index
    /// entry) once its UID is confirmed gone from every mailbox this account
    /// has ever synced — the "1c" fallback: nothing left to point at, so the
    /// only honest local state is "this message no longer exists". Recomputes
    /// (and, if this was its last message, deletes) the owning thread's
    /// aggregate the same way `MessageRemoval.commit` does for a swipe
    /// delete/archive.
    private func cleanUpVanishedMessage(messageId: Int64) async -> SelfHealOutcome {
        do {
            try await database.dbWriter.write { db in
                guard let message = try MessageRecord.fetchOne(db, key: messageId) else { return }
                let threadId = message.threadId
                try FTSIndexer.delete(messageId: messageId, db: db)
                try MessageBodyRecord.deleteOne(db, key: messageId)
                try AttachmentRecord.filter(Column("messageId") == messageId).deleteAll(db)
                _ = try MessageRecord.deleteOne(db, key: messageId)
                if let threadId {
                    try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
                }
            }
            return .cleanedUp
        } catch {
            return .notApplicable
        }
    }

    /// Fetches bodies for up to `limit` of `mailboxId`'s most-recently-
    /// received messages that don't have one yet, newest first, via
    /// `session` (already connected, with `mailboxPath` selected).
    /// Best-effort: one message's fetch failing (deleted server-side,
    /// transient error, ...) doesn't stop the rest of the batch. Returns
    /// the number successfully fetched.
    @discardableResult
    public func prefetchRecent(
        mailboxId: Int64,
        mailboxPath: String,
        limit: Int = BodyFetcher.defaultPrefetchLimit,
        session: any IMAPSessionProtocol
    ) async throws -> Int {
        let candidates = try await database.dbWriter.read { db in
            try MessageRecord
                .filter(Column("mailboxId") == mailboxId)
                .filter(Column("bodyState") == MessageBodyState.notFetched.rawValue)
                .order(Column("internalDate").desc, Column("uid").desc)
                .limit(limit)
                .fetchAll(db)
        }

        var successCount = 0
        for message in candidates {
            do {
                try await fetchBody(message: message, mailboxPath: mailboxPath, session: session)
                successCount += 1
            } catch {
                continue
            }
        }
        return successCount
    }

    /// `messageBody.plainText`: the backend's own plain-text rendering
    /// when it has one, otherwise a plain-text extraction of the HTML body
    /// (plan: "html しか無い場合は HTML からテキスト抽出してplainTextに").
    static func resolvePlainText(from content: MessageBodyContent) -> String? {
        if let plainText = content.plainText, !plainText.isEmpty {
            return plainText
        }
        if let html = content.html, !html.isEmpty {
            let extracted = HTMLTextExtractor.plainText(fromHTML: html)
            return extracted.isEmpty ? nil : extracted
        }
        return nil
    }

    /// `MessageLanguageDetector.detectWithFallback`, wrapped: that type's
    /// whole API is itself `#if canImport(NaturalLanguage)`-gated (see its
    /// doc comment), so this call site needs the same guard to keep
    /// compiling on a hypothetical `NaturalLanguage`-less platform — `nil`
    /// there, same as "no candidate was usable enough to commit to a
    /// language". Only the language is kept here — `BodyFetcher` runs once
    /// per fetched message with no UI-facing diagnostics store to log to
    /// (that's `MessageView.backfillDetectedLanguageIfNeeded`'s job, see
    /// its doc comment); logging every background fetch here would also
    /// flood the diagnostics screen's fixed 5-attempt window with
    /// sync-time noise instead of the specific message a user is actually
    /// looking at when they open that screen.
    static func detectLanguage(plainText: String?, html: String?) -> String? {
        #if canImport(NaturalLanguage)
        MessageLanguageDetector.detectWithFallback(plainText: plainText, html: html)?.language
        #else
        nil
        #endif
    }
}
