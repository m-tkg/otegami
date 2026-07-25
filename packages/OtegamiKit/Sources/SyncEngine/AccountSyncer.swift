import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore

/// Drives sync for a single account: initial sync today (M1); differential
/// sync, flag sync, and `opQueue` replay land in M3. One instance owns no
/// long-lived IMAP connection of its own — each sync pass opens, uses, and
/// closes its own session — so it's safe to keep around across repeated
/// manual/pull-to-refresh syncs without worrying about a stale connection.
/// Which mailboxes `AccountSyncer.performIncrementalSync`/`SyncCoordinator
/// .syncAccountIncrementally` should differentially sync this pass (M4:
/// "差分同期は INBOX を高頻度、他は同期要求時"). `.inboxOnly` is the default so
/// existing IDLE-wake/foreground-active call sites keep M3's behavior
/// without needing to pass anything.
public enum SyncScope: Sendable, Equatable {
    /// INBOX only — the frequent path (IDLE wake, app-active).
    case inboxOnly
    /// One specific mailbox, by its raw IMAP path — a sidebar selection or
    /// that mailbox's own manual-refresh button.
    case mailbox(path: String)
    /// Every selectable (non-`\Noselect`) mailbox — a full manual refresh.
    case all
}

public actor AccountSyncer {
    /// How many of a mailbox's most recent messages the initial sync
    /// fetches (plan: "直近500件"). A ceiling, not a guarantee: mailboxes
    /// with fewer messages, or gaps from expunged UIDs, yield fewer.
    public static let initialSyncWindow: UInt32 = 500

    /// How many UIDs `fetchEnvelopes` requests per underlying FETCH
    /// command (plan: "100 件ずつバッチで").
    public static let fetchBatchSize = 100

    /// Progress reported during ``performInitialSync(auth:onProgress:)``,
    /// e.g. to drive a progress indicator in `AccountSetupView`.
    public struct Progress: Sendable, Equatable {
        public var mailboxesDiscovered: Int = 0
        public var selectedMailboxPath: String?
        public var envelopesFetched: Int = 0
        /// How many of the recent-message body prefetch (M2) succeeded.
        public var bodiesFetched: Int = 0
    }

    private let account: AccountRecord
    private let database: AppDatabase
    private let sessionFactory: @Sendable (IMAPConfig) -> any IMAPSessionProtocol
    private let bodyFetcher: BodyFetcher
    private let mailboxSyncer: MailboxSyncer

    /// The long-lived foreground `IDLE` loop's `Task` (M3), started by
    /// ``startIdleLoop(auth:onWake:)`` and stopped by ``stopIdleLoop()``.
    /// One `AccountSyncer` runs at most one of these at a time — starting
    /// a new one cancels whatever was already running first.
    private var idleTask: Task<Void, Never>?

    public init(
        account: AccountRecord,
        database: AppDatabase,
        sessionFactory: @escaping @Sendable (IMAPConfig) -> any IMAPSessionProtocol
    ) {
        self.account = account
        self.database = database
        self.sessionFactory = sessionFactory
        self.bodyFetcher = BodyFetcher(database: database)
        self.mailboxSyncer = MailboxSyncer(database: database)
    }

    deinit {
        idleTask?.cancel()
    }

    /// Connects, lists mailboxes (upserting all of them), then syncs every
    /// *selectable* mailbox (plan M4: "role のある主要 mailbox + ユーザー
    /// mailbox" — in practice, every mailbox without `\Noselect`, since a
    /// server's role advertisement is best-effort and a plain user-created
    /// mailbox deserves syncing too): for each, fetches its most recent
    /// ``initialSyncWindow`` envelopes in ``fetchBatchSize``-sized batches,
    /// upserting `message`/`messageReference` rows as it goes. Idempotent:
    /// safe to call again (e.g. from a manual refresh) — re-fetched
    /// envelopes overwrite the existing row for their `(mailboxId, uid)`
    /// rather than duplicating.
    ///
    /// Body prefetch (plan: "初期同期後に直近50件を先読み") stays INBOX-only —
    /// paying for it on every mailbox would multiply the initial-sync
    /// network cost for little benefit, since every other mailbox's bodies
    /// still arrive lazily on open.
    ///
    /// Finishes with one `ThreadAssigner.assignAllUnthreaded` pass over the
    /// whole account (plan: "初期同期後の一括スレッド計算") — run once at the
    /// end, after every mailbox's messages are in, rather than per mailbox,
    /// so a reply living in one mailbox (e.g. Sent) can resolve against the
    /// original in another (e.g. Inbox) regardless of which mailbox synced
    /// first.
    @discardableResult
    public func performInitialSync(
        auth: MailAuth,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Progress {
        var progress = Progress()

        let session = sessionFactory(account.imapConfig)
        try await connect(session, auth: auth)
        defer {
            let session = session
            Task { await session.disconnect() }
        }

        let mailboxInfos = try await session.listMailboxes()
        progress.mailboxesDiscovered = mailboxInfos.count
        onProgress?(progress)

        let mailboxRecordsByPath = try await upsertMailboxes(mailboxInfos)
        let syncableInfos = mailboxInfos.filter { !$0.attributes.contains(.noSelect) }

        for info in syncableInfos {
            guard let record = mailboxRecordsByPath[info.path], let mailboxId = record.id else { continue }

            // One mailbox's `select`/`fetchEnvelopes`/write failing (a
            // transient network hiccup, a server-side quirk on a mailbox
            // this account happens to have — much more likely over a real
            // network path than the dev mailstack's loopback connection)
            // must not abort every *other* mailbox's sync, nor skip the
            // `ThreadAssigner` pass below for whatever *did* sync
            // successfully. Before this `do`/`catch`, any single mailbox
            // throwing partway through this loop propagated all the way
            // out of `performInitialSync` — silently, since callers invoke
            // this via `try?` (`AccountSetupView.saveAccount`,
            // `AppEnvironment`) — leaving every envelope already upserted
            // by an *earlier* mailbox in this same loop permanently
            // invisible: `message.threadId` stays `nil` forever (the final
            // `ThreadAssigner.assignAllUnthreaded` call was never reached),
            // and `ThreadQuery`'s `EXISTS (... message.threadId = thread.id
            // ...)` join never matches a null `threadId`, so both the
            // unified inbox and the account's own mailbox view show
            // "メッセージがありません" even though the messages are durably in
            // the database and the mailbox's own `uidNext`/`uidValidity`
            // (persisted per-mailbox, *inside* this loop, before this
            // point) already looks fully synced on every later resync.
            do {
                progress.selectedMailboxPath = info.path
                onProgress?(progress)

                let status = try await session.select(info.path)

                if status.messageCount > 0, status.uidNext > 1 {
                    let lowerBound = Self.initialSyncLowerBound(uidNext: status.uidNext, window: Self.initialSyncWindow)
                    let range = UIDRange(lowerBound: lowerBound, upperBound: nil)
                    let envelopes = try await session.fetchEnvelopes(
                        mailboxPath: info.path,
                        uids: range,
                        batchSize: Self.fetchBatchSize
                    )

                    try await database.dbWriter.write { [account] db in
                        for envelope in envelopes {
                            try Self.upsert(envelope: envelope, mailboxId: mailboxId, accountId: account.id, db: db)
                        }
                    }

                    progress.envelopesFetched += envelopes.count
                    onProgress?(progress)
                }

                // Captured as a `let` snapshot rather than mutated directly
                // inside the closure: `DatabaseWriter.write`'s closure is
                // `@Sendable`, and mutating a captured `var` across a Sendable
                // closure boundary is rejected under Swift 6 strict
                // concurrency even though `AccountSyncer` itself is
                // actor-isolated.
                let syncedRecord = record
                try await database.dbWriter.write { db in
                    var updated = syncedRecord
                    updated.uidValidity = Int64(status.uidValidity)
                    updated.uidNext = Int64(status.uidNext)
                    updated.highestModSeq = Int64(status.highestModSeq)
                    updated.messageCount = status.messageCount
                    updated.lastSyncedAt = Date()
                    try updated.update(db)
                }

                if info.role == .inbox {
                    // Best-effort: `prefetchRecent` already swallows individual
                    // message failures, and initial sync itself shouldn't fail
                    // just because prefetch couldn't run at all (e.g. a
                    // mid-sync disconnect) — the message list still renders
                    // fine with bodies fetched lazily on open instead.
                    progress.bodiesFetched = (try? await bodyFetcher.prefetchRecent(
                        mailboxId: mailboxId,
                        mailboxPath: info.path,
                        session: session
                    )) ?? 0
                    onProgress?(progress)
                }

                // This mailbox's sync just succeeded — clear any failure a
                // *previous* pass recorded (see `MailboxRecord
                // .lastSyncError`'s doc comment) so `MailboxSyncFailuresView`'s
                // banner disappears on its own rather than requiring a
                // manual dismissal for a problem that's since resolved
                // itself.
                await clearMailboxSyncFailureIfNeeded(mailboxId: mailboxId)
            } catch {
                // Move on to the next mailbox; see the doc comment above
                // this `do` for why one mailbox's failure shouldn't cost
                // every other mailbox its threading pass. Record *what*
                // failed (`docs/qa-findings.md`'s "部分同期失敗の UI可視化")
                // rather than the previous silent `continue` — this is the
                // only place that failure is ever visible to the user.
                await recordMailboxSyncFailure(mailboxId: mailboxId, error: error)
                continue
            }
        }

        try await database.dbWriter.write { [account] db in
            try ThreadAssigner.assignAllUnthreaded(accountId: account.id, db: db)
        }

        return progress
    }

    /// Upserts every mailbox `listMailboxes()` reported (keyed by
    /// `(accountId, path)`), returning the resulting records by path.
    /// Shared by ``performInitialSync(auth:onProgress:)`` and
    /// ``performIncrementalSync(auth:)`` — both need "every known mailbox,
    /// freshly upserted" before doing anything mailbox-specific.
    ///
    /// `MailboxInfo` (what `listMailboxes()` returns) has no notion of
    /// sync-progress state — `uidValidity`/`uidNext`/`highestModSeq`/
    /// `messageCount`/`lastSyncedAt` only ever come from a `select`/
    /// `incrementalSync` pass — so a re-upsert must not clobber whatever a
    /// *previous* sync already stored in those columns back to their
    /// zero/`nil` defaults; only the listing-derived columns (path
    /// metadata, role, attributes) are safe to overwrite unconditionally
    /// here. (`performInitialSync` immediately overwrites the sync-state
    /// columns with fresh values right after this call anyway, so this
    /// mattered less there; `performIncrementalSync`/`MailboxSyncer`
    /// depend on the *previous* pass's `uidValidity`/`highestModSeq`
    /// surviving through this call so they have something to diff
    /// against.)
    private func upsertMailboxes(_ mailboxInfos: [MailboxInfo]) async throws -> [String: MailboxRecord] {
        try await database.dbWriter.write { [account] db -> [String: MailboxRecord] in
            var records: [String: MailboxRecord] = [:]
            for info in mailboxInfos {
                var record = MailboxRecord(
                    accountId: account.id,
                    path: info.path,
                    displayPath: info.displayPath,
                    delimiter: info.delimiter,
                    role: MailboxRoleRecord(info.role),
                    attributesRaw: info.attributes.rawValue
                )
                record = try record.upsertAndFetch(db, onConflict: ["accountId", "path"]) { _ in
                    [
                        Column("uidValidity").noOverwrite,
                        Column("uidNext").noOverwrite,
                        Column("highestModSeq").noOverwrite,
                        Column("messageCount").noOverwrite,
                        Column("lastSyncedAt").noOverwrite,
                        Column("lastSyncError").noOverwrite,
                        Column("lastSyncErrorAt").noOverwrite,
                    ]
                }
                records[info.path] = record
            }
            return records
        }
    }

    /// Records that this mailbox's most recent sync attempt failed — see
    /// `MailboxRecord.lastSyncError`'s doc comment. `try?`: a failure to
    /// write the failure record itself must not throw out of the per-mailbox
    /// `catch` blocks that call this (which already have their own error to
    /// deal with, and a `continue` to reach regardless).
    private func recordMailboxSyncFailure(mailboxId: Int64, error: Error) async {
        try? await database.dbWriter.write { db in
            guard var mailbox = try MailboxRecord.fetchOne(db, key: mailboxId) else { return }
            mailbox.lastSyncError = String(describing: error)
            mailbox.lastSyncErrorAt = Date()
            try mailbox.update(db)
        }
    }

    /// Clears a previously-recorded sync failure once this mailbox syncs
    /// successfully again. A no-op write when there was nothing to clear
    /// (the common case — most mailboxes never fail), rather than an
    /// unconditional `UPDATE`, only to keep `mailbox`'s `ValueObservation`
    /// from firing for every successful sync of every mailbox.
    private func clearMailboxSyncFailureIfNeeded(mailboxId: Int64) async {
        try? await database.dbWriter.write { db in
            guard var mailbox = try MailboxRecord.fetchOne(db, key: mailboxId), mailbox.lastSyncError != nil else { return }
            mailbox.lastSyncError = nil
            mailbox.lastSyncErrorAt = nil
            try mailbox.update(db)
        }
    }

    /// Connects `session`, recording (account edit UI) or clearing
    /// `AccountRecord.lastSyncError` around it — see that field's doc
    /// comment for why a connect-level failure (as opposed to one scoped to
    /// a single mailbox, `recordMailboxSyncFailure` above) needs its own
    /// account-level record. Rethrows on failure so every existing caller's
    /// control flow (abort the rest of this sync pass) is unchanged; this
    /// only adds a side effect, not a new error path.
    private func connect(_ session: any IMAPSessionProtocol, auth: MailAuth) async throws {
        do {
            try await session.connect(auth: auth)
        } catch {
            await recordAccountSyncFailure(error: error)
            throw error
        }
        await clearAccountSyncFailureIfNeeded()
    }

    private func recordAccountSyncFailure(error: Error) async {
        try? await database.dbWriter.write { [account] db in
            guard var row = try AccountRecord.fetchOne(db, key: account.id) else { return }
            row.lastSyncError = String(describing: error)
            row.lastSyncErrorAt = Date()
            try row.update(db)
        }
    }

    private func clearAccountSyncFailureIfNeeded() async {
        try? await database.dbWriter.write { [account] db in
            guard var row = try AccountRecord.fetchOne(db, key: account.id), row.lastSyncError != nil else { return }
            row.lastSyncError = nil
            row.lastSyncErrorAt = nil
            try row.update(db)
        }
    }

    /// Differential sync (M3, mailbox scope extended in M4): re-lists
    /// mailboxes (so a newly-created server-side mailbox — e.g. Trash
    /// appearing for the first time — is picked up for `OpQueueProcessor`'s
    /// delete-to-Trash resolution), then runs `MailboxSyncer.incrementalSync`
    /// for whichever mailboxes `scope` selects. Defaults to `.inboxOnly`
    /// (M3's original, still the frequent/IDLE-driven path per the plan:
    /// "差分同期は INBOX を高頻度") — `.mailbox(path:)` is what a sidebar
    /// mailbox selection or its manual-refresh button asks for, `.all` a
    /// full manual refresh across every mailbox.
    @discardableResult
    public func performIncrementalSync(auth: MailAuth, scope: SyncScope = .inboxOnly) async throws -> MailboxSyncer.Progress {
        let session = sessionFactory(account.imapConfig)
        try await connect(session, auth: auth)
        defer {
            let session = session
            Task { await session.disconnect() }
        }

        let capabilities = try await session.capabilities()
        let mailboxInfos = try await session.listMailboxes()
        let mailboxRecordsByPath = try await upsertMailboxes(mailboxInfos)

        let targets: [MailboxInfo]
        switch scope {
        case .inboxOnly:
            targets = Self.inbox(among: mailboxInfos).map { [$0] } ?? []
        case .mailbox(let path):
            targets = mailboxInfos.filter { $0.path == path }
        case .all:
            targets = mailboxInfos.filter { !$0.attributes.contains(.noSelect) }
        }

        var combined = MailboxSyncer.Progress()
        for info in targets {
            guard let record = mailboxRecordsByPath[info.path] else { continue }
            // Same reasoning as `performInitialSync`'s per-mailbox `do`/
            // `catch`: one mailbox failing to differentially sync
            // shouldn't abort every other mailbox in `targets`, nor skip
            // the `ThreadAssigner` pass below — this loop is exactly the
            // self-heal path a message stuck with `threadId == nil` (e.g.
            // from a `performInitialSync` that hit this same situation)
            // relies on, so it needs to keep reaching that final call even
            // when one mailbox in `targets` errors out.
            do {
                let (_, progress) = try await mailboxSyncer.incrementalSync(
                    mailboxRecord: record,
                    mailboxPath: info.path,
                    accountId: account.id,
                    session: session,
                    capabilities: capabilities
                )
                combined.newMessages += progress.newMessages
                combined.flagChanges += progress.flagChanges
                combined.deletedMessages += progress.deletedMessages
                combined.didFullResync = combined.didFullResync || progress.didFullResync

                // See `performInitialSync`'s identical call for why: clears
                // a previously-recorded failure now that this pass
                // succeeded.
                if let mailboxId = record.id {
                    await clearMailboxSyncFailureIfNeeded(mailboxId: mailboxId)
                }
            } catch {
                // See `performInitialSync`'s identical call for why this
                // records rather than silently `continue`s.
                if let mailboxId = record.id {
                    await recordMailboxSyncFailure(mailboxId: mailboxId, error: error)
                }
                continue
            }
        }

        if !targets.isEmpty {
            try await database.dbWriter.write { [account] db in
                try ThreadAssigner.assignAllUnthreaded(accountId: account.id, db: db)
            }
        }

        return combined
    }

    // MARK: - Foreground IDLE (M3)

    /// Starts (or restarts, if already running) a long-lived `IDLE` loop
    /// against INBOX: connects, `IDLE`s continuously (see
    /// `MailCoreIMAPSession.idle`'s doc comment for the reissue/backoff
    /// details it handles internally), and calls `onWake` once per
    /// `.newData` event. On any error (dropped connection, auth failure,
    /// ...) it reconnects with its own exponential backoff rather than
    /// giving up — this is meant to run for as long as the app is in the
    /// foreground. Cancelled by ``stopIdleLoop()`` or by this
    /// `AccountSyncer` being deallocated.
    public func startIdleLoop(auth: MailAuth, onWake: @escaping @Sendable () async -> Void) {
        stopIdleLoop()
        idleTask = Task { [weak self] in
            await self?.runIdleLoop(auth: auth, onWake: onWake)
        }
    }

    public func stopIdleLoop() {
        idleTask?.cancel()
        idleTask = nil
    }

    private func runIdleLoop(auth: MailAuth, onWake: @Sendable () async -> Void) async {
        var backoffSeconds: TimeInterval = 5
        while !Task.isCancelled {
            do {
                let session = sessionFactory(account.imapConfig)
                try await connect(session, auth: auth)
                let mailboxInfos = try await session.listMailboxes()
                guard let inboxInfo = Self.inbox(among: mailboxInfos) else {
                    await session.disconnect()
                    return
                }
                _ = try await session.select(inboxInfo.path)
                backoffSeconds = 5 // a clean connect resets the backoff

                for try await event in session.idle(mailboxPath: inboxInfo.path) {
                    guard !Task.isCancelled else { break }
                    if case .newData = event {
                        await onWake()
                    }
                }
                await session.disconnect()
            } catch {
                // Connection/auth error, or the idle stream itself threw —
                // fall through to the backoff-and-retry below rather than
                // giving up on IDLE for the rest of the foreground session.
            }

            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(backoffSeconds))
            backoffSeconds = min(backoffSeconds * 2, 300)
        }
    }

    /// The lower UID bound that yields (at most) `window` messages,
    /// assuming a dense (gap-free) UID space: everything from
    /// `uidNext - window` onward. Servers with expunged messages (gaps)
    /// will simply return fewer than `window` envelopes for this range,
    /// which callers treat as fine.
    static func initialSyncLowerBound(uidNext: UInt32, window: UInt32) -> UInt32 {
        let highestPossibleUID = uidNext - 1
        return highestPossibleUID > window ? highestPossibleUID - window + 1 : 1
    }

    private static func inbox(among mailboxes: [MailboxInfo]) -> MailboxInfo? {
        mailboxes.first { $0.role == .inbox }
            ?? mailboxes.first { $0.path.caseInsensitiveCompare("INBOX") == .orderedSame }
    }

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
            date: envelope.date,
            internalDate: envelope.internalDate,
            flagsRaw: envelope.flags.rawValue,
            size: envelope.size,
            gmailThreadId: envelope.gmailThreadId.map { Int64(bitPattern: $0) },
            gmailMessageId: envelope.gmailMessageId.map { Int64(bitPattern: $0) },
            hasAttachments: envelope.hasAttachments,
            updatedAt: Date()
        )
        // `createdAt` is excluded from the update side of the upsert so a
        // resync doesn't overwrite the original insert timestamp.
        // `threadId` is also excluded: an already-threaded message's
        // thread assignment must survive a resync (only the code below,
        // via `ThreadAssigner`, is allowed to change it).
        record = try record.upsertAndFetch(db, onConflict: ["mailboxId", "uid"]) { _ in
            [Column("createdAt").noOverwrite, Column("threadId").noOverwrite]
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
}
