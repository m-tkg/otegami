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
    /// INBOX **and** the account's Drafts-role mailbox (if any) — the
    /// frequent path (IDLE wake, app-active). Drafts IMAP sync milestone:
    /// folded into the existing `.inboxOnly` case (rather than adding a new
    /// `.inboxAndDrafts` case every call site would need to opt into)
    /// because a Drafts mailbox is typically tiny and every one of
    /// `.inboxOnly`'s existing call sites (`OtegamiApp`'s foreground/IDLE
    /// handler, `MessageListView`'s manual-refresh-elsewhere fallback) is
    /// exactly where picking up another client's draft edit promptly
    /// matters too — see `AccountSyncer.performIncrementalSync`'s `targets`
    /// computation.
    case inboxOnly
    /// One specific mailbox, by its raw IMAP path — a sidebar selection or
    /// that mailbox's own manual-refresh button.
    case mailbox(path: String)
    /// Task #152 (実機報告「フラグ/アーカイブ操作後、他の受信箱一覧への反映が
    /// 遅い」): a specific *set* of mailbox paths, synced over one shared
    /// connection — `SyncCoordinator`'s post-`opQueue`-replay targeted
    /// resync uses this for "the mailbox an offline action touched plus
    /// wherever it self-healed a destination to" (e.g. an archive's source
    /// INBOX and its Archive-role destination), rather than looping
    /// `.mailbox(path:)` once per affected mailbox — each call to that case
    /// alone reconnects and re-`listMailboxes`, which is fine for a single
    /// sidebar selection but wasteful for a batch of 2+ mailboxes from one
    /// op replay.
    case mailboxes(paths: Set<String>)
    /// Every selectable (non-`\Noselect`) mailbox — a full manual refresh.
    case all
}

/// Task #69 (「メールボックス同期エラーは、5回自動でリトライして、それでも
/// ダメなときだけ表示して」): the automatic-retry policy `AccountSyncer`
/// applies to a sync pass's `connect()` and each mailbox's sync body, when
/// that call's `autoRetry` is `true` (the default for every entry point
/// except `MessageListView`'s manual pull-to-refresh — see `SyncCoordinator
/// .syncAccountIncrementally(_:auth:scope:autoRetry:)`'s doc comment).
///
/// Not every failure retries the same way — see `AccountSyncer
/// .FailureClass`/`classify(_:)` for the three-way split this type's
/// `maxAttempts`/backoff actually drives:
/// - `.authentication` never retries (§4 exception 1: リトライ無意味).
/// - `.networkUnreachable` (`MailTransportError.connectionFailed` — this
///   app has no `NWPathMonitor`, so "could not connect at all" is the
///   closest signal to "the device is offline") consumes one of
///   `maxAttempts` per *external call* to `connect`/a mailbox's sync, with
///   no in-process sleep — deliberately: sleeping `backoffBase`-scaled
///   seconds while genuinely offline just blocks the caller for no benefit,
///   when the next foreground-resume/IDLE-reconnect/pull-to-refresh is
///   already going to call this again anyway (§4 exception 3: "5連敗を
///   空費しない…既存のフォアグラウンド同期タイミングで足りる").
/// - `.other` (transient IMAP/server hiccups: `serverError`,
///   `malformedResponse`, `notConnected`, `cancelled`, `mailboxNotFound`,
///   `notImplemented`) retries in-process, sleeping `backoffBase * 2^n`
///   (capped at `backoffCap`) between attempts, up to `maxAttempts` total
///   tries within the one call — this is the "5回自動でリトライ" the
///   original request describes literally.
///
/// `sleep` is injected so `AccountSyncerTests`' `.other`-class retry
/// scenarios don't have to actually wait through real backoff delays
/// (`SyncRetryPolicy(sleep: { _ in })`), the same "injected clock/sleeper"
/// shape `OpQueueProcessor.backoffBase`/`.backoffCap` establish for op
/// replay (that one isn't injectable since its backoff lives *between*
/// separate `replay()` calls, driven by a persisted `nextRetryAt` column
/// rather than an in-process sleep — this type's `.other` case is the one
/// that actually blocks synchronously, hence needing the hook).
public struct SyncRetryPolicy: Sendable {
    /// Total tries before a failure is finally recorded as visible —
    /// matches the request's literal "5回" (attempt 1 + up to 4 retries).
    public var maxAttempts: Int
    /// `.other`-class backoff base, doubled each attempt (2s/4s/8s/16s for
    /// attempts 2–5) — mirrors `OpQueueProcessor.backoffBase`'s shape at a
    /// much shorter timescale (a stuck sync pass shouldn't block minutes
    /// the way a queued op replay can afford to).
    public var backoffBase: TimeInterval
    /// Ceiling on any single backoff delay — reachable only if `maxAttempts`
    /// were raised well past 5; present for the same "don't let this grow
    /// unbounded" reason `OpQueueProcessor.backoffCap` exists, not because
    /// 5 attempts at `backoffBase = 2` ever gets close to it.
    public var backoffCap: TimeInterval

    public var sleep: @Sendable (TimeInterval) async -> Void

    public init(
        maxAttempts: Int = 5,
        backoffBase: TimeInterval = 2,
        backoffCap: TimeInterval = 32,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.maxAttempts = maxAttempts
        self.backoffBase = backoffBase
        self.backoffCap = backoffCap
        self.sleep = sleep
    }

    public static let `default` = SyncRetryPolicy()
}

public actor AccountSyncer {
    /// How many of a mailbox's most recent messages the initial sync
    /// fetches (plan: "直近500件"), by IMAP *sequence* number via
    /// `IMAPSessionProtocol.fetchRecentEnvelopes` — see that method's doc
    /// comment for why sequence number rather than a UID range (a real
    /// mailbox's UID space is not dense; see docs/verify.md's "実機バグ調査:
    /// 疎な UID 帯を持つメールボックスで初期同期が0通になる"). A ceiling, not a
    /// guarantee: a mailbox with fewer messages yields fewer.
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
    /// Task #69: see `SyncRetryPolicy`'s doc comment.
    private let retryPolicy: SyncRetryPolicy

    /// The long-lived foreground `IDLE` loop's `Task` (M3), started by
    /// ``startIdleLoop(auth:onWake:)`` and stopped by ``stopIdleLoop()``.
    /// One `AccountSyncer` runs at most one of these at a time — starting
    /// a new one cancels whatever was already running first.
    private var idleTask: Task<Void, Never>?

    /// Task #69: consecutive `.networkUnreachable`-classified `connect()`
    /// failures, one persisted count per this `AccountSyncer` instance —
    /// which itself lives for the app's process lifetime once created
    /// (`SyncCoordinator.syncer(for:)` caches it by account id), so this
    /// naturally accumulates across separate IDLE-wake/foreground/pull-to-
    /// refresh calls the way `SyncRetryPolicy`'s doc comment describes,
    /// without needing a DB column. Reset to `0` the moment a connect
    /// succeeds (`connectWithRetry(auth:autoRetry:)`).
    private var accountNetworkFailureStreak = 0
    /// Same idea, per mailbox (keyed by `MailboxRecord.id`) — "アカウント
    /// （またはメールボックス）単位で独立" (Task #69's request): one
    /// mailbox's offline streak never affects another mailbox's, or the
    /// account-level `connect()`'s.
    private var mailboxNetworkFailureStreaks: [Int64: Int] = [:]
    /// Task #69 "リトライ中に新しい同期要求が来た場合の重複防止": set for the
    /// whole duration of an `autoRetry: true` `performInitialSync`/
    /// `performIncrementalSync` call (not just while a backoff sleep is in
    /// flight) — a second automatic call arriving while one is already
    /// running for this account is a no-op (returns an empty `Progress`)
    /// rather than opening a second concurrent connection. Manual calls
    /// (`autoRetry: false`) never consult or set this — see
    /// `SyncCoordinator.syncAccountIncrementally(_:auth:scope:autoRetry:)`'s
    /// doc comment for why a manual pull-to-refresh must always run
    /// immediately regardless of what's happening automatically.
    private var isAutoRetrying = false

    /// Test-only observation hook (not `public` — reachable only via
    /// `@testable import SyncEngine`, same pattern as `SyncCoordinator
    /// .waitForPendingPostSyncPrefetchForTesting()`): lets a dedup test
    /// wait until an in-flight automatic sync call has actually set
    /// `isAutoRetrying`, rather than racing a fixed number of
    /// `Task.yield()`s against however long that takes.
    func isAutoRetryingForTesting() -> Bool {
        isAutoRetrying
    }

    public init(
        account: AccountRecord,
        database: AppDatabase,
        retryPolicy: SyncRetryPolicy = .default,
        sessionFactory: @escaping @Sendable (IMAPConfig) -> any IMAPSessionProtocol
    ) {
        self.account = account
        self.database = database
        self.retryPolicy = retryPolicy
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
        autoRetry: Bool = true,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Progress {
        // Task #69 dedup: see `isAutoRetrying`'s doc comment.
        if autoRetry {
            guard !isAutoRetrying else { return Progress() }
            isAutoRetrying = true
        }
        defer { if autoRetry { isAutoRetrying = false } }

        var progress = Progress()

        let session = try await connectWithRetry(auth: auth, autoRetry: autoRetry)
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
            //
            // Task #69: the whole block below now runs through
            // `syncMailboxWithRetry` — retried/suppressed per
            // `SyncRetryPolicy`'s doc comment when `autoRetry`, exactly one
            // attempt with an immediate record-on-failure otherwise (manual
            // pull-to-refresh's `.all` scope). Either way, any failure that
            // ultimately propagates out of this `do` just moves on to the
            // next mailbox (`docs/qa-findings.md`'s "部分同期失敗の UI可視化"
            // — one mailbox's failure must not cost every other mailbox its
            // threading pass below).
            do {
                try await syncMailboxWithRetry(mailboxId: mailboxId, autoRetry: autoRetry) {
                    progress.selectedMailboxPath = info.path
                    onProgress?(progress)

                    let status = try await session.select(info.path)

                    if status.messageCount > 0 {
                        let envelopes = try await session.fetchRecentEnvelopes(
                            mailboxPath: info.path,
                            count: Int(Self.initialSyncWindow),
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
                }
            } catch {
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
        // Task #154 (実機報告「ゴミ箱カテゴリに Gmail が2行出る」): #119's
        // name-guess fallback (`MailboxRole.inferred(fromDisplayPath:)`)
        // resolves each mailbox independently, with no visibility into its
        // siblings — so a server that already advertises SPECIAL-USE
        // `\Trash` for one mailbox can still leave a *different*, literally
        // "Trash"-named mailbox in this same account name-guessed to
        // `.trash` too, giving the hamburger menu's role-based category
        // section two rows for one account. `roleIsAuthoritative` (see
        // `MailboxInfo`'s doc comment) is authoritative-over-name-guess
        // *within one mailbox*; this set extends that to "authoritative
        // across this whole account's mailboxes for a given role" — any
        // non-authoritative (name-guessed) mailbox whose role also has an
        // authoritative source elsewhere in this same `mailboxInfos` batch
        // gets downgraded to `.none` below, before it ever reaches the
        // `mailbox` table. `.none` is excluded: there's no "authoritative
        // .none" to defer to, and every uncategorized mailbox already
        // legitimately shares that role.
        let authoritativeRoles = Set(
            mailboxInfos.filter { $0.roleIsAuthoritative && $0.role != .none }.map(\.role)
        )

        return try await database.dbWriter.write { [account] db -> [String: MailboxRecord] in
            var records: [String: MailboxRecord] = [:]
            for info in mailboxInfos {
                let isDuplicateNameGuess = !info.roleIsAuthoritative
                    && info.role != .none
                    && authoritativeRoles.contains(info.role)
                let effectiveRole = isDuplicateNameGuess ? .none : info.role
                var record = MailboxRecord(
                    accountId: account.id,
                    path: info.path,
                    displayPath: info.displayPath,
                    delimiter: info.delimiter,
                    role: MailboxRoleRecord(effectiveRole),
                    roleIsAuthoritative: isDuplicateNameGuess ? false : info.roleIsAuthoritative,
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
                        // メールボックス単位の非表示: every sync pass re-lists
                        // and re-upserts every mailbox `IMAP LIST` reports,
                        // but the freshly-constructed `record` above always
                        // starts `isHidden: false` (it has no way to know the
                        // user's choice) — without `.noOverwrite` here, the
                        // very next sync after hiding a mailbox would quietly
                        // un-hide it again. See `MailboxRecord.isHidden`'s
                        // doc comment.
                        Column("isHidden").noOverwrite,
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

    /// Task #69: which of the three retry treatments `SyncRetryPolicy`'s
    /// doc comment describes an error gets. Any error that isn't a
    /// `MailTransportError` at all (shouldn't normally happen — every
    /// `IMAPSessionProtocol` method's documented failure mode is one of
    /// that enum's cases) falls into `.other` rather than crashing or
    /// silently never retrying.
    private enum FailureClass {
        case authentication
        case networkUnreachable
        case other
    }

    private static func classify(_ error: Error) -> FailureClass {
        guard let error = error as? MailTransportError else { return .other }
        switch error {
        case .authenticationFailed:
            return .authentication
        case .connectionFailed:
            return .networkUnreachable
        case .serverError, .malformedResponse, .mailboxNotFound, .notConnected, .cancelled, .notImplemented:
            return .other
        }
    }

    /// Task #69: connects with automatic retry — builds a *fresh* session
    /// via `sessionFactory` on every attempt (mirrors `runIdleLoop`'s own
    /// reconnect pattern) rather than retrying `connect(auth:)` on the one
    /// session built before the first attempt, so a retried attempt is a
    /// genuine new connection, not a replay against whatever broke the
    /// first one. Records (account edit UI) or clears `AccountRecord
    /// .lastSyncError` around it — see that field's doc comment for why a
    /// connect-level failure (as opposed to one scoped to a single mailbox,
    /// `recordMailboxSyncFailure` above) needs its own account-level
    /// record.
    ///
    /// `autoRetry: false` (manual pull-to-refresh) is exactly the
    /// pre-Task-#69 behavior: one attempt, immediate record + rethrow on
    /// failure. `autoRetry: true` applies `SyncRetryPolicy`'s
    /// authentication/networkUnreachable/other classification — see
    /// `classify(_:)`/`SyncRetryPolicy`'s doc comments.
    private func connectWithRetry(auth: MailAuth, autoRetry: Bool) async throws -> any IMAPSessionProtocol {
        guard autoRetry else {
            let session = sessionFactory(account.imapConfig)
            do {
                try await session.connect(auth: auth)
            } catch {
                await recordAccountSyncFailure(error: error)
                throw error
            }
            accountNetworkFailureStreak = 0
            await clearAccountSyncFailureIfNeeded()
            return session
        }

        var attempt = 0
        while true {
            attempt += 1
            let session = sessionFactory(account.imapConfig)
            do {
                try await session.connect(auth: auth)
                accountNetworkFailureStreak = 0
                await clearAccountSyncFailureIfNeeded()
                return session
            } catch {
                switch Self.classify(error) {
                case .authentication:
                    // 認証エラーはリトライ無意味 — 即時表示 (Task #69 exception 1).
                    await recordAccountSyncFailure(error: error)
                    throw error

                case .networkUnreachable:
                    // オフライン系: このプロセス内ではスリープ/再試行せず、
                    // この呼び出し1回を streak に積んで即座に諦める — 次に
                    // フォアグラウンド復帰/IDLE 再接続/次回同期機会がこの
                    // メソッドをもう一度呼んだ時が「次の1回」になる (Task #69
                    // exception 3; `accountNetworkFailureStreak`の doc comment)。
                    accountNetworkFailureStreak += 1
                    if accountNetworkFailureStreak >= retryPolicy.maxAttempts {
                        await recordAccountSyncFailure(error: error)
                    }
                    throw error

                case .other:
                    guard attempt < retryPolicy.maxAttempts else {
                        await recordAccountSyncFailure(error: error)
                        throw error
                    }
                    let backoff = min(retryPolicy.backoffCap, retryPolicy.backoffBase * pow(2, Double(attempt - 1)))
                    await retryPolicy.sleep(backoff)
                    // Loop again — a fresh session/attempt.
                }
            }
        }
    }

    /// Task #69: runs one mailbox's sync body (`operation`) under the same
    /// retry/suppression policy `connectWithRetry(auth:autoRetry:)` applies
    /// to the account-level connect — see that method's doc comment and
    /// `SyncRetryPolicy`'s for the authentication/networkUnreachable/other
    /// classification both share. `mailboxId` keys
    /// `mailboxNetworkFailureStreaks` — see that property's doc comment for
    /// why each mailbox's offline streak is independent of every other
    /// mailbox's and of the account-level connect's.
    ///
    /// Unlike `connectWithRetry`, a retried attempt reuses whatever session
    /// `operation` closes over rather than rebuilding one — a mailbox-level
    /// failure (a transient `NO`/parse hiccup on this one mailbox) doesn't
    /// imply the connection itself is bad, so there's nothing to reconnect;
    /// `operation` itself would throw `.networkUnreachable` if the
    /// underlying connection actually did drop.
    private func syncMailboxWithRetry(
        mailboxId: Int64,
        autoRetry: Bool,
        operation: () async throws -> Void
    ) async throws {
        guard autoRetry else {
            do {
                try await operation()
            } catch {
                await recordMailboxSyncFailure(mailboxId: mailboxId, error: error)
                throw error
            }
            mailboxNetworkFailureStreaks[mailboxId] = 0
            await clearMailboxSyncFailureIfNeeded(mailboxId: mailboxId)
            return
        }

        var attempt = 0
        while true {
            attempt += 1
            do {
                try await operation()
                mailboxNetworkFailureStreaks[mailboxId] = 0
                await clearMailboxSyncFailureIfNeeded(mailboxId: mailboxId)
                return
            } catch {
                switch Self.classify(error) {
                case .authentication:
                    await recordMailboxSyncFailure(mailboxId: mailboxId, error: error)
                    throw error

                case .networkUnreachable:
                    let streak = (mailboxNetworkFailureStreaks[mailboxId] ?? 0) + 1
                    mailboxNetworkFailureStreaks[mailboxId] = streak
                    if streak >= retryPolicy.maxAttempts {
                        await recordMailboxSyncFailure(mailboxId: mailboxId, error: error)
                    }
                    throw error

                case .other:
                    guard attempt < retryPolicy.maxAttempts else {
                        await recordMailboxSyncFailure(mailboxId: mailboxId, error: error)
                        throw error
                    }
                    let backoff = min(retryPolicy.backoffCap, retryPolicy.backoffBase * pow(2, Double(attempt - 1)))
                    await retryPolicy.sleep(backoff)
                }
            }
        }
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
    /// - Parameter forceReconcileVanishedUIDs: Task #83 — forwarded verbatim
    ///   to every mailbox's `MailboxSyncer.incrementalSync` call this pass;
    ///   see that parameter's doc comment for which call sites should pass
    ///   `true`.
    @discardableResult
    public func performIncrementalSync(
        auth: MailAuth,
        scope: SyncScope = .inboxOnly,
        autoRetry: Bool = true,
        forceReconcileVanishedUIDs: Bool = false
    ) async throws -> MailboxSyncer.Progress {
        // Task #69 dedup: see `isAutoRetrying`'s doc comment.
        if autoRetry {
            guard !isAutoRetrying else { return MailboxSyncer.Progress() }
            isAutoRetrying = true
        }
        defer { if autoRetry { isAutoRetrying = false } }

        let session = try await connectWithRetry(auth: auth, autoRetry: autoRetry)
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
            // See `SyncScope.inboxOnly`'s doc comment: INBOX plus Drafts
            // (if this account has a Drafts-role mailbox at all — most
            // don't get created until the first `.saveDraft` replay
            // self-heals one, so `nil` here is the common case for a fresh
            // account and simply means "nothing to add").
            targets = [Self.inbox(among: mailboxInfos), Self.drafts(among: mailboxInfos)].compactMap { $0 }
        case .mailbox(let path):
            targets = mailboxInfos.filter { $0.path == path }
        case .mailboxes(let paths):
            targets = mailboxInfos.filter { paths.contains($0.path) }
        case .all:
            // メールボックス単位の非表示: a hidden mailbox is excluded from a
            // full manual refresh too (`docs/settings.md`'s "同期も止める"
            // judgment — battery/network cost, not just a display filter).
            // `.inboxOnly`/`.mailbox(path:)` above don't need the same
            // check: `.inboxOnly` only ever targets INBOX/Drafts (hiding
            // either would be a strange, unsupported edge case), and
            // `.mailbox(path:)` is only ever invoked with a path the caller
            // found in the (already hidden-filtered) sidebar/hamburger
            // tree.
            targets = mailboxInfos.filter { info in
                !info.attributes.contains(.noSelect) && !(mailboxRecordsByPath[info.path]?.isHidden ?? false)
            }
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
            // Task #69: same `syncMailboxWithRetry` wrapper
            // `performInitialSync`'s per-mailbox loop uses — see that call
            // site's doc comment.
            guard let mailboxId = record.id else { continue }
            do {
                var progress = MailboxSyncer.Progress()
                try await syncMailboxWithRetry(mailboxId: mailboxId, autoRetry: autoRetry) {
                    let (_, mailboxProgress) = try await mailboxSyncer.incrementalSync(
                        mailboxRecord: record,
                        mailboxPath: info.path,
                        accountId: account.id,
                        session: session,
                        capabilities: capabilities,
                        forceReconcileVanishedUIDs: forceReconcileVanishedUIDs
                    )
                    progress = mailboxProgress
                }
                combined.newMessages += progress.newMessages
                combined.flagChanges += progress.flagChanges
                combined.deletedMessages += progress.deletedMessages
                combined.didFullResync = combined.didFullResync || progress.didFullResync
            } catch {
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
                // Task #69: `autoRetry: false` here on purpose — this loop
                // already implements its *own* infinite reconnect-with-
                // backoff (5s/10s/.../300s, below) for as long as the app
                // stays foregrounded, which would otherwise stack with
                // `SyncRetryPolicy`'s separate 5-attempt/2s-32s policy in a
                // confusing way. `autoRetry: false` keeps this exactly the
                // pre-Task-#69 behavior: one attempt per reconnect, account
                // -level `lastSyncError` recorded/cleared around it same as
                // always.
                let session = try await connectWithRetry(auth: auth, autoRetry: false)
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

    private static func inbox(among mailboxes: [MailboxInfo]) -> MailboxInfo? {
        mailboxes.first { $0.role == .inbox }
            ?? mailboxes.first { $0.path.caseInsensitiveCompare("INBOX") == .orderedSame }
    }

    /// Drafts IMAP sync: the account's Drafts-role mailbox, if the server
    /// advertised one (`SPECIAL-USE`) or has a mailbox literally named
    /// `"Drafts"` — same fallback shape as `inbox(among:)`, and the same
    /// name `OpQueueProcessor.resolveOrCreateDraftsMailbox` self-heals
    /// towards when neither is true yet.
    static func drafts(among mailboxes: [MailboxInfo]) -> MailboxInfo? {
        mailboxes.first { $0.role == .drafts }
            ?? mailboxes.first { $0.path.caseInsensitiveCompare(OpQueueProcessor.draftsMailboxNameToCreate) == .orderedSame }
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
        // Task #120: before the normal upsert-by-`(mailboxId, uid)` below,
        // check whether this envelope is the real, server-confirmed arrival
        // of a message `MessageRemoval` already relocated to this mailbox
        // ahead of the server (`MessageRecord.isPendingRelocation`) —
        // reconcile it onto the real UID *in place* rather than letting the
        // upsert insert a brand-new row alongside it (a visible duplicate:
        // the same message would show up twice in this mailbox's list).
        try reconcilePendingRelocation(envelope: envelope, mailboxId: mailboxId, db: db)

        // ピン留め (E9): whether this resync should mirror the server's
        // current `\Flagged` bit into `MessageRecord.isPinnedLocal` — see
        // `PinSettingsStore`'s doc comment for why this reads the same raw
        // `UserDefaults` key directly (`SyncEngine` doesn't otherwise depend
        // on the app target's settings files) rather than being threaded in
        // as a parameter through every `AccountSyncer` call site. When
        // disabled (the default), `isPinnedLocal` is left untouched by a
        // resync entirely (`noOverwrite` below) so a purely local-only pin
        // survives regardless of what the server's `\Flagged` bit says.
        let pinSyncEnabled = UserDefaults.standard.bool(forKey: PinSettingsKeys.syncWithFlaggedKey)
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
            hasAttachments: envelope.hasAttachments,
            isPinnedLocal: pinSyncEnabled && envelope.flags.contains(.flagged),
            updatedAt: Date()
        )
        // `createdAt` is excluded from the update side of the upsert so a
        // resync doesn't overwrite the original insert timestamp.
        // `threadId` is also excluded: an already-threaded message's
        // thread assignment must survive a resync (only the code below,
        // via `ThreadAssigner`, is allowed to change it). `isPinnedLocal`
        // is excluded too unless `pinSyncEnabled` — see this method's doc
        // comment above.
        record = try record.upsertAndFetch(db, onConflict: ["mailboxId", "uid"]) { _ in
            var excluded = [Column("createdAt").noOverwrite, Column("threadId").noOverwrite]
            if !pinSyncEnabled {
                excluded.append(Column("isPinnedLocal").noOverwrite)
            }
            return excluded
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
    private static func reconcilePendingRelocation(envelope: FetchedEnvelope, mailboxId: Int64, db: Database) throws {
        guard let messageId = envelope.messageId, !messageId.isEmpty else { return }
        guard var pending = try MessageRecord
            .filter(Column("mailboxId") == mailboxId)
            .filter(Column("uid") <= 0)
            .filter(Column("messageId") == messageId)
            .fetchOne(db)
        else { return }
        pending.uid = Int64(envelope.uid)
        try pending.update(db, columns: [Column("uid")])
    }
}
