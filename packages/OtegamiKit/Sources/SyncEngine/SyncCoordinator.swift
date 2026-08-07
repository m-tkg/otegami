import Foundation
import GRDB
import MailTransport
import OtegamiStore
import os

/// Top-level sync entry point, owned by `AppEnvironment`. Manages one
/// `AccountSyncer` per account (created on first sync, reused afterward) so
/// callers never need to think about which account maps to which syncer.
///
/// The IMAP session factory is injected rather than hardcoded to
/// `MailCoreIMAPSession` so `SyncEngine` stays independent of any specific
/// transport backend (the app wires the real factory; tests inject
/// `FakeIMAPSession`).
public actor SyncCoordinator {
    private let database: AppDatabase
    private let sessionFactory: @Sendable (IMAPConfig) -> any IMAPSessionProtocol
    /// Phase 3 (IMAP 接続の再利用): passed straight through to every
    /// `AccountSyncer` this coordinator creates as *its*
    /// `idleSessionFactory` — see that property's doc comment. Production
    /// wiring (`AppEnvironment`) passes the raw, unpooled
    /// `MailCoreIMAPSession` factory here while `sessionFactory` above goes
    /// through `PooledIMAPSessionFactory`; defaults to `sessionFactory`
    /// itself for every other caller (tests, and any future call site that
    /// doesn't care about the distinction).
    private let idleSessionFactory: @Sendable (IMAPConfig) -> any IMAPSessionProtocol
    /// M5's SMTP session factory, retained here (not just forwarded to
    /// `opQueueProcessor`) for `sendCalendarReply(draft:account:auth:)`
    /// (Task #66) — a calendar RSVP reply sends immediately over its own
    /// short-lived SMTP connection, the same "opens its own session, no
    /// persistent connection" shape `fetchBody`/`fetchAttachment` already
    /// use, rather than going through the durable `outboxMessage`/`opQueue`
    /// path (see that method's doc comment for why immediate send was the
    /// natural fit here).
    private let smtpSessionFactory: @Sendable (SMTPConfig) -> any SMTPSessionProtocol
    private let messageBuilder: @Sendable (ComposeDraft) -> BuiltMessage
    private var syncers: [String: AccountSyncer] = [:]
    private let bodyFetcher: BodyFetcher
    private let attachmentFetcher: AttachmentFetcher
    /// 古いメールのバックフィル同期: shared across every backfill batch this
    /// coordinator schedules, same "one instance per coordinator, not per
    /// call" shape as `bodyFetcher`/`attachmentFetcher` above.
    private let backfillSyncer: BackfillSyncer
    /// 検索の IMAP サーバーサイド SEARCH フォールバック: shared across every
    /// `serverSearch(query:accounts:authProvider:timeout:)` call, same
    /// "one instance per coordinator, not per call" shape as
    /// `bodyFetcher`/`backfillSyncer` above.
    private let serverSearchService: ServerSearchService
    /// Task #103: no `AppDatabase` dependency (unlike `bodyFetcher`/
    /// `attachmentFetcher`) — see `MessageSourceFetcher`'s own doc comment
    /// for why. Constructed directly here rather than in `init` alongside
    /// the other two, since it needs nothing from this type's own
    /// parameters.
    private let messageSourceFetcher = MessageSourceFetcher()
    private let opQueueProcessor: OpQueueProcessor
    /// Task #152: the pure debounce/coalesce policy behind
    /// `scheduleTargetedResync` — see `TargetedResyncScheduler`'s own doc
    /// comment. Its `debounceInterval` is injectable (`targetedResync
    /// DebounceInterval` below) purely so tests don't have to wait through
    /// several real seconds per case; every production call site leaves it
    /// at the default.
    private var targetedResyncScheduler: TargetedResyncScheduler
    /// Account/auth captured alongside each `targetedResyncScheduler
    /// .request` call, keyed by accountId — the scheduler itself only knows
    /// mailbox ids/timing (see its doc comment for why), so this is where
    /// `performTargetedResync` gets what it needs to actually open a
    /// connection once an account's debounce window elapses. Last-write-wins
    /// per account: within one short debounce window the account/auth pair
    /// a burst of ops supplies is for all practical purposes identical, so
    /// there's no need to track more than the most recent one.
    private var targetedResyncContext: [String: (account: AccountRecord, auth: MailAuth)] = [:]
    /// The long-lived loop `ensureTargetedResyncLoopRunning` starts on the
    /// first `scheduleTargetedResync` call and that same loop clears back to
    /// `nil` once nothing is pending — `nil` here just means "no burst is
    /// currently being waited out", not "this feature is off".
    private var targetedResyncLoopTask: Task<Void, Never>?
    /// Task #152's OSLog category — see `OpQueue.opReflectLogger`'s doc
    /// comment for the full enqueue → replay → targeted-resync lifecycle
    /// this is the last leg of.
    private static let opReflectLogger = Logger(subsystem: "com.mtkg.otegami", category: "OpReflect")

    public init(
        database: AppDatabase,
        sessionFactory: @escaping @Sendable (IMAPConfig) -> any IMAPSessionProtocol,
        idleSessionFactory: (@Sendable (IMAPConfig) -> any IMAPSessionProtocol)? = nil,
        smtpSessionFactory: @escaping @Sendable (SMTPConfig) -> any SMTPSessionProtocol = { config in NotImplementedSMTPSession(config: config) },
        messageBuilder: @escaping @Sendable (ComposeDraft) -> BuiltMessage = { _ in
            BuiltMessage(data: Data(), messageId: "<unbuilt@otegami.local>")
        },
        targetedResyncDebounceInterval: TimeInterval = TargetedResyncScheduler.defaultDebounceInterval
    ) {
        self.database = database
        self.sessionFactory = sessionFactory
        self.idleSessionFactory = idleSessionFactory ?? sessionFactory
        self.smtpSessionFactory = smtpSessionFactory
        self.messageBuilder = messageBuilder
        self.bodyFetcher = BodyFetcher(database: database)
        self.attachmentFetcher = AttachmentFetcher(database: database)
        self.backfillSyncer = BackfillSyncer(database: database)
        self.serverSearchService = ServerSearchService(database: database)
        self.opQueueProcessor = OpQueueProcessor(
            database: database,
            sessionFactory: sessionFactory,
            smtpSessionFactory: smtpSessionFactory,
            messageBuilder: messageBuilder
        )
        self.targetedResyncScheduler = TargetedResyncScheduler(debounceInterval: targetedResyncDebounceInterval)
    }

    /// Runs initial sync for `account` (creating its `AccountSyncer` if
    /// this is the first sync since launch). Safe to call again — e.g. from
    /// a manual refresh or pull-to-refresh — since `AccountSyncer`'s
    /// initial sync upserts idempotently. Full differential sync (only
    /// fetching what changed since the last sync) lands in M3.
    /// `autoRetry` (Task #69, default `true`): applies `AccountSyncer
    /// .SyncRetryPolicy`'s automatic-retry-then-suppress-until-given-up
    /// behavior — see that type's doc comment for the authentication/
    /// networkUnreachable/other classification it drives, and
    /// `syncAccountIncrementally(_:auth:scope:autoRetry:)`'s doc comment
    /// for why every entry point except a manual pull-to-refresh should
    /// leave this at its default.
    @discardableResult
    public func syncAccount(
        _ account: AccountRecord,
        auth: MailAuth,
        autoRetry: Bool = true,
        onProgress: (@Sendable (AccountSyncer.Progress) -> Void)? = nil
    ) async throws -> AccountSyncer.Progress {
        let syncer = syncer(for: account)
        return try await syncer.performInitialSync(auth: auth, autoRetry: autoRetry, onProgress: onProgress)
    }

    /// Fetches (and persists) one message's body on demand — the "開封時は
    /// 該当メッセージを最優先で取得" path: the app calls this when a message
    /// is opened and its `bodyState` isn't already `.fetched`. Opens its
    /// own short-lived session (connect → select → fetch → disconnect)
    /// rather than reusing a syncer's connection, since this can happen at
    /// any time independent of any sync pass in progress. A no-op if
    /// `message` has no `id` (shouldn't happen for a message read back out
    /// of the database).
    public func fetchBody(
        for message: MessageRecord,
        mailboxPath: String,
        account: AccountRecord,
        auth: MailAuth
    ) async throws {
        // Task #120: skip opening a connection at all for a
        // `MessageRecord.isPendingRelocation` row — `BodyFetcher.fetchBody`
        // would just reject it anyway (see its own doc comment), so there's
        // nothing a network round trip could accomplish here yet.
        guard !message.isPendingRelocation else {
            throw SyncEngineError.pendingRelocation(messageId: message.id)
        }
        try await withIMAPSession(account: account, auth: auth, selecting: mailboxPath) { session in
            try await bodyFetcher.fetchBody(message: message, mailboxPath: mailboxPath, session: session)
        }
    }

    /// Fetches (and persists) one attachment's data on demand (M8) — the
    /// "受信側: タップ→未取得ならスピナー付き取得" and cid-inline-image paths both
    /// go through this. Opens its own short-lived session, same rationale
    /// as `fetchBody(for:mailboxPath:account:auth:)` above (this can happen
    /// at any time, independent of any sync pass, e.g. mid-scroll through a
    /// `WKWebView`'s inline images).
    @discardableResult
    public func fetchAttachment(
        _ attachment: AttachmentRecord,
        messageUID: Int64,
        mailboxPath: String,
        account: AccountRecord,
        auth: MailAuth
    ) async throws -> AttachmentRecord {
        // Task #120: `messageUID <= 0` means the owning message is a
        // `MessageRecord.isPendingRelocation` row — same reasoning as
        // `fetchBody(for:mailboxPath:account:auth:)`'s identical guard
        // above; there's no real server UID to `UID FETCH` a part of yet.
        guard messageUID > 0 else {
            throw SyncEngineError.pendingRelocation(messageId: nil)
        }
        return try await withIMAPSession(account: account, auth: auth, selecting: mailboxPath) { session in
            try await attachmentFetcher.fetchAndStore(
                attachment: attachment,
                accountId: account.id,
                messageUID: messageUID,
                mailboxPath: mailboxPath,
                session: session
            )
        }
    }

    /// Task #103 ("ソースを表示" — 表示崩れメールの eml を受け渡す調査経路):
    /// fetches (caching to disk) and returns the local file `URL` of one
    /// message's raw RFC822 source — the on-demand "調査経路として今すぐ
    /// 必要" counterpart to `fetchBody`/`fetchAttachment` above, same
    /// short-lived-session shape (open → select → fetch → disconnect).
    ///
    /// Checks `MessageSourceFetcher.cachedURL` *before* opening a
    /// connection at all: a message whose source was already fetched once
    /// (this session or a previous one — the cache is on disk, not in
    /// memory) resolves entirely offline, matching this feature's "取得後は
    /// ローカルにキャッシュ...再表示時は再取得しない" requirement without
    /// even attempting a network round trip on the common "already viewed
    /// this one" path.
    @discardableResult
    public func fetchRawSource(
        messageId: Int64,
        messageUID: Int64,
        mailboxPath: String,
        account: AccountRecord,
        auth: MailAuth
    ) async throws -> URL {
        if let cached = MessageSourceFetcher.cachedURL(accountId: account.id, messageId: messageId) {
            return cached
        }
        // Task #120: same "no real server UID yet" guard as
        // `fetchAttachment`/`fetchBody` above.
        guard messageUID > 0 else {
            throw SyncEngineError.pendingRelocation(messageId: messageId)
        }
        return try await withIMAPSession(account: account, auth: auth, selecting: mailboxPath) { session in
            try await messageSourceFetcher.fetchAndStore(
                messageId: messageId,
                accountId: account.id,
                messageUID: messageUID,
                mailboxPath: mailboxPath,
                session: session
            )
        }
    }

    /// Opens a short-lived IMAP session, `SELECT`s `mailboxPath`, runs
    /// `body`, and always disconnects afterward — the exact "connect →
    /// select → do the one on-demand thing → disconnect" shape `fetchBody`/
    /// `fetchAttachment`/`fetchRawSource` above each used to repeat
    /// byte-for-byte. Disconnect happens in a `defer`, same as before this
    /// extraction: on any throw from `select`/`body`, the session is still
    /// torn down.
    ///
    /// **Not** used by `runUnifiedInboxPrefetch`/`prefetchMessageBodies` —
    /// both wrap their `connect` in `do/catch { continue }` *inside a loop
    /// over multiple mailboxes/accounts*, a genuinely different control
    /// flow (best-effort, skip-and-continue on failure, one connection
    /// serving several `select`s) that this single-mailbox/single-body
    /// helper doesn't fit. Forcing them onto this shape wasn't part of this
    /// refactor's scope.
    private func withIMAPSession<T>(
        account: AccountRecord,
        auth: MailAuth,
        selecting mailboxPath: String,
        body: (any IMAPSessionProtocol) async throws -> T
    ) async throws -> T {
        let session = sessionFactory(account.imapConfig)
        try await session.connect(auth: auth)
        defer {
            let session = session
            Task { await session.disconnect() }
        }
        _ = try await session.select(mailboxPath)
        return try await body(session)
    }

    /// Sends a calendar invite RSVP (`ICSReplyBuilder.buildReply`'s
    /// `text/calendar; method=REPLY` attachment, wrapped in `draft`) over
    /// its own short-lived SMTP connection — Task #66's "承諾/辞退/未定"
    /// buttons. Deliberately bypasses the durable `outboxMessage`/`opQueue`
    /// path `ComposerView`'s regular sends go through: an RSVP reply has no
    /// user-facing "送信待ち"/cancel affordance to begin with (the invite
    /// card's own buttons are the only UI for it), and immediate send-or-
    /// fail lets the card show a normal inline error with a retry (tap the
    /// button again) exactly like `MessageView.openAttachment`'s on-demand
    /// attachment fetch already does — no new durable-queue plumbing
    /// (`OutboxAttachmentRecord` has no `contentTypeParameters` column,
    /// and adding one only for this single caller isn't worth the schema
    /// migration) needed for what is, from the network's perspective, a
    /// single one-shot send.
    public func sendCalendarReply(
        _ draft: ComposeDraft,
        account: AccountRecord,
        auth: MailAuth
    ) async throws {
        guard let smtpConfig = account.smtpConfig else {
            throw MailTransportError.serverError(underlyingDescription: "Account \(account.id) has no SMTP configuration")
        }
        let built = messageBuilder(draft)
        let smtpSession = smtpSessionFactory(smtpConfig)
        try await smtpSession.connect(auth: SMTPAuthResolver.resolve(imapAuth: auth, account: account))
        defer {
            let smtpSession = smtpSession
            Task { await smtpSession.disconnect() }
        }
        let recipients = draft.to + draft.cc + draft.bcc
        try await smtpSession.sendMessage(messageData: built.data, from: draft.from, recipients: recipients)
    }

    /// Differential sync (M3): only fetches what changed since the last
    /// sync (new mail, flag changes, uidValidity-triggered resync) rather
    /// than re-walking the whole initial-sync window. What pull-to-refresh,
    /// foreground-resume, and IDLE wake-ups all call — see
    /// `AccountSyncer.performIncrementalSync`'s doc comment for the exact
    /// per-mailbox behavior.
    ///
    /// `autoRetry` (Task #69, default `true`): whether a connect/mailbox
    /// failure gets `AccountSyncer.SyncRetryPolicy`'s automatic-retry-then-
    /// suppress-until-given-up treatment (see that type's doc comment) or
    /// the pre-Task-#69 "one attempt, record/show immediately" behavior.
    /// Every automatic call site (IDLE wake, foreground/launch sync, the
    /// post-sync prefetch trigger below) should leave this at its default;
    /// `MessageListView`'s manual pull-to-refresh is the one caller that
    /// passes `false` — 「手動 pull-to-refresh はユーザー操作起点 → 即時1回
    /// 実行し、失敗は従来どおり表示」(Task #69's request) means a user who
    /// just pulled to refresh should see the result of *that* attempt, not
    /// wait through up to ~30s of silent background retries first.
    ///
    /// `forceReconcileVanishedUIDs` (Task #83, default `false`): forwarded
    /// to `AccountSyncer.performIncrementalSync`/`MailboxSyncer
    /// .incrementalSync` — see that parameter's doc comment. `true` for
    /// `MessageListView`'s pull-to-refresh and its 5-minute mailbox-display
    /// auto-resync, the launch/foreground-resume pass
    /// (`AppEnvironment.syncAllAccountsOnce`) and the `IDLE`-wake call
    /// below (実機バグ「別クライアントで全部アーカイブ→アプリを切り替えて
    /// 戻すと未読メールが復活」— all of those are exactly the moments a
    /// vanished-elsewhere message must disappear locally too); left at
    /// `false` only for the remaining high-frequency automatic paths
    /// (targeted resync, notification-tap priority sync) so they don't
    /// pay for an extra `UID SEARCH` per mailbox on every pass.
    /// `schedulesPostSyncPrefetch` (push 通知起点バックグラウンド受信 Phase 1,
    /// default `true`): whether a successful sync schedules the Task #63
    /// post-sync prefetch trigger below. `PushTriggeredInboxSync` — called
    /// from the `NotificationService` Extension on every push receipt — is
    /// the one caller that passes `false`: `schedulePostSyncPrefetchIfNeeded`
    /// fires a *detached* low-priority `Task` that keeps running after this
    /// method returns (see that method's own doc comment), and an
    /// Extension process has no guarantee it survives past the moment it
    /// hands its `UNNotificationContent` back to the system — a detached
    /// prefetch `Task` started there could be killed mid-flight, or open a
    /// second IMAP connection to a mailbox this same call just finished
    /// syncing right as the process is about to be torn down. Every other
    /// caller (pull-to-refresh, IDLE wake, foreground/launch sync) runs
    /// inside the long-lived app process the detached `Task` safely
    /// outlives this call in, so they all keep the default.
    ///
    /// `schedulesBackfill` (古いメールのバックフィル同期, default `true`):
    /// whether a successful sync schedules `scheduleBackfillIfNeeded(for:
    /// auth:)` below — same "detached background `Task` a short-lived
    /// Notification Service Extension process can't rely on surviving"
    /// reasoning as `schedulesPostSyncPrefetch` above, and the same one
    /// caller (`PushTriggeredInboxSync`) opts out for it.
    @discardableResult
    public func syncAccountIncrementally(
        _ account: AccountRecord,
        auth: MailAuth,
        scope: SyncScope = .inboxOnly,
        autoRetry: Bool = true,
        forceReconcileVanishedUIDs: Bool = false,
        schedulesPostSyncPrefetch: Bool = true,
        schedulesBackfill: Bool = true,
        onProgress: (@Sendable (MailboxSyncer.SyncProgressUpdate) -> Void)? = nil
    ) async throws -> MailboxSyncer.Progress {
        let syncer = syncer(for: account)
        let progress = try await syncer.performIncrementalSync(
            auth: auth,
            scope: scope,
            autoRetry: autoRetry,
            forceReconcileVanishedUIDs: forceReconcileVanishedUIDs,
            onProgress: onProgress
        )
        // Task #63: "各メールボックスの同期完了後にも1回" — see
        // `schedulePostSyncPrefetchIfNeeded(for:auth:)`'s doc comment. Only
        // scheduled after a *successful* sync (the `try await` above would
        // have already thrown and returned early otherwise), and only when
        // the caller didn't ask to suppress it (see `schedulesPostSyncPrefetch`'s
        // doc comment above).
        if schedulesPostSyncPrefetch {
            schedulePostSyncPrefetchIfNeeded(for: account, auth: auth)
        }
        // 古いメールのバックフィル同期: same "only after a successful sync,
        // only when the caller didn't opt out" shape as the post-sync
        // prefetch trigger just above — see `scheduleBackfillIfNeeded(for:
        // auth:)`'s doc comment for the debounce/cap policy.
        if schedulesBackfill {
            scheduleBackfillIfNeeded(for: account, auth: auth)
        }
        return progress
    }

    /// Replays `account`'s queued offline operations (flag changes,
    /// moves/deletes) against the server. Cheap to call opportunistically
    /// — a no-op (no connection opened) when the queue is empty or
    /// nothing is due yet; see `OpQueueProcessor.replay`.
    ///
    /// Task #152 (実機報告「フラグ/アーカイブ操作後、他の受信箱一覧への反映が
    /// 遅い」): when an applied op has a destination mailbox, schedules a
    /// prioritized targeted resync of that destination only
    /// (`result.affectedMailboxIds`) via `scheduleTargetedResync`. The
    /// optimistically-updated source is intentionally excluded; refreshing
    /// it before an eventually-consistent server reflects the operation can
    /// restore stale flags/messages and make the row briefly reappear.
    /// Scheduled, not awaited inline: this call
    /// already made its own IMAP round trip for the replay itself, and the
    /// resync fires after a short debounce anyway (`TargetedResyncScheduler
    /// .defaultDebounceInterval`) to coalesce a burst of consecutive
    /// operations, so blocking this call on it would both slow down every
    /// existing caller (swipe actions, foreground sync, IDLE wake) and
    /// contradict the debounce itself.
    @discardableResult
    public func replayOpQueue(for account: AccountRecord, auth: MailAuth) async throws -> OpQueueProcessor.ReplayResult {
        let result = try await opQueueProcessor.replay(account: account, auth: auth)
        if result.succeeded > 0, !result.affectedMailboxIds.isEmpty {
            scheduleTargetedResync(account: account, auth: auth, mailboxIds: result.affectedMailboxIds)
        }
        return result
    }

    /// Starts `account`'s foreground `IDLE` loop: on each server push, first
    /// flushes any queued offline operations, then runs an incremental sync
    /// (a newly-online connection is exactly when queued offline operations
    /// should get their chance to flush). Meant to be called once when the
    /// app becomes active per M3's "フォアグラウンド IDLE" requirement — see
    /// `AccountSyncer.startIdleLoop`'s doc comment for the reconnect/backoff
    /// behavior underneath.
    ///
    /// **Order: replay before sync, not after (実機報告「Gmail で既読化/
    /// アーカイブしてもサーバに反映されず、再読込でサーバ状態に巻き戻る」の
    /// 調査で判明)**: an incremental sync's envelope refresh overwrites a
    /// message's local `flagsRaw` with whatever the server currently reports
    /// (`MessageReadMarker.markSeen`'s doc comment — only `createdAt`/
    /// `threadId`/`isPinnedLocal` survive a resync untouched, flags don't).
    /// If `syncAccountIncrementally` ran *first*, an `IDLE` wake landing
    /// while a flag/archive op was still sitting unsent in `opQueue` would
    /// have the sync observe the server's still-old state and write it back
    /// over the user's own optimistic local change — visibly undoing the
    /// action that was, from the user's perspective, already done — and
    /// only *then* would `replayOpQueue` send it, too late to prevent that
    /// visible flicker/rollback. Flushing the user's own pending intent
    /// first means any sync that follows already observes what the user
    /// just did (once the server has processed it) instead of stomping on
    /// it.
    public func startIdleLoop(for account: AccountRecord, auth: MailAuth) async {
        let syncer = syncer(for: account)
        await syncer.startIdleLoop(auth: auth) { [weak self] in
            guard let self else { return }
            _ = try? await self.replayOpQueue(for: account, auth: auth)
            // `forceReconcileVanishedUIDs: true`: an `IDLE` wake *is* the
            // server saying "something changed in this mailbox" — and one of
            // the things that can have changed is another client expunging
            // messages (archive-elsewhere). Gmail doesn't reliably bump
            // HIGHESTMODSEQ for those (Task #83), so without the forced
            // reconcile an idle-wake sync would leave the vanished messages
            // sitting locally (still unread) until the 5-minute display
            // loop happens to catch them. One extra `UID SEARCH` per actual
            // server push is proportionate to that signal.
            _ = try? await self.syncAccountIncrementally(account, auth: auth, forceReconcileVanishedUIDs: true)
        }
    }

    /// Stops `account`'s foreground `IDLE` loop (app entering background).
    public func stopIdleLoop(for account: AccountRecord) async {
        guard let syncer = syncers[account.id] else { return }
        await syncer.stopIdleLoop()
    }

    /// Stops every account's `IDLE` loop in one call, for `RootView`'s
    /// `scenePhase` handling (`.active` → `.background`/`.inactive`).
    public func stopAllIdleLoops() async {
        for syncer in syncers.values {
            await syncer.stopIdleLoop()
        }
    }

    /// Drops the cached `AccountSyncer` for `accountId`, if one exists —
    /// called after an account edit (host/port/credentials changed) so the
    /// *next* `syncAccount`/`syncAccountIncrementally`/`startIdleLoop` call
    /// builds a fresh `AccountSyncer` from the freshly-saved `AccountRecord`
    /// instead of reusing a syncer that's still holding the pre-edit
    /// host/port in its own `let account` (see `syncer(for:)` below — it
    /// only ever builds a *new* `AccountSyncer` for an id it hasn't seen
    /// before; every other call site's `account` parameter is otherwise
    /// silently ignored once a syncer for that id already exists). Stops
    /// the syncer's `IDLE` loop first — dropping the dictionary's only
    /// strong reference would otherwise leave a still-running `idleTask`
    /// racing this method's own caller, relying on `AccountSyncer.deinit`
    /// to cancel it only if nothing else happens to be racing a retain in
    /// the meantime.
    public func invalidateSyncer(for accountId: String) async {
        guard let syncer = syncers.removeValue(forKey: accountId) else { return }
        await syncer.stopIdleLoop()
    }

    /// How far back `prefetchUnifiedInboxBodiesIfNeeded`/the post-sync
    /// prefetch trigger look for not-yet-fetched unified inbox messages
    /// (Task #63 — "直近3日間くらいのものでいい"). Replaces Task #31's
    /// original flat "直近30件" count-based criterion: a quiet inbox
    /// shouldn't reach past 3 days just to fill a count, and a noisy one
    /// shouldn't skip fetching a message that arrived 2 days ago just
    /// because 30 newer ones already filled the list. See `MessageQuery
    /// .unfetchedUnifiedInboxCandidates(accountIds:since:limit:db:)`'s doc
    /// comment for the query itself.
    public static let unifiedInboxPrefetchWindow: TimeInterval = 3 * 24 * 60 * 60

    /// Safety cap on top of `unifiedInboxPrefetchWindow` — a first sync, or
    /// an unusually high-volume inbox, could otherwise have far more than a
    /// handful of not-yet-fetched messages inside the 3-day window; this
    /// bounds one background pass's worst case rather than fetching an
    /// unbounded number of bodies. Generous relative to Task #31's original
    /// flat 30-message limit since the window is now doing the primary
    /// filtering.
    public static let unifiedInboxPrefetchCandidateLimit = 200

    /// Debounce for the launch/foreground prefetch pass
    /// (`prefetchUnifiedInboxBodiesIfNeeded`) — battery/network conscious
    /// "once per launch/foreground, not once per scenePhase blip"
    /// (locking/unlocking the device, or a quick app-switch-and-back, can
    /// otherwise fire `RootView.handleScenePhaseChange`'s `.active` case
    /// several times in quick succession).
    private static let unifiedInboxPrefetchInterval: TimeInterval = 5 * 60

    /// In-memory only (not persisted to `UserDefaults`) — deliberately
    /// resets on every process launch, so a cold launch always runs the
    /// prefetch once rather than being blocked by a debounce window from
    /// the *previous* process's last foreground.
    private var lastUnifiedInboxPrefetchDate: Date?

    /// Debounce for the *post-sync* prefetch trigger
    /// (`schedulePostSyncPrefetchIfNeeded(for:auth:)`, Task #63) — much
    /// shorter than `unifiedInboxPrefetchInterval` on purpose: this
    /// trigger's whole point is reacting promptly to *this* mailbox's
    /// just-synced new mail ("新着の本文が即先読みされるように"), not
    /// waiting out the 5-minute launch/foreground debounce. Keyed
    /// per-account (`lastPostSyncPrefetchDateByAccount`) rather than one
    /// shared timestamp, so a busy account's frequent IDLE wake-ups can't
    /// starve another account's post-sync prefetch, and a foreground pass
    /// that just ran doesn't block the very next sync's post-sync trigger
    /// for a full 5 minutes.
    private static let postSyncPrefetchInterval: TimeInterval = 60

    /// In-memory only, same rationale as `lastUnifiedInboxPrefetchDate`.
    private var lastPostSyncPrefetchDateByAccount: [String: Date] = [:]

    /// Task #31 (docs/roadmap.md): background-prefetches bodies for the
    /// unified inbox's not-yet-fetched messages received within
    /// `unifiedInboxPrefetchWindow` (up to `unifiedInboxPrefetchCandidateLimit`
    /// as a safety cap), right after launch and on every foreground return
    /// — the fix for "さっき読んだメールも、アプリを起動し直すと読み込みが
    /// 入る?表示まで時間がかかる" (a message near the top of the list whose
    /// body was never lazily fetched otherwise pays a network round trip
    /// the moment it's opened, every time). Meant to be called from a
    /// low-priority, fire-and-forget `Task`
    /// (`RootView.handleScenePhaseChange`'s `.active` case) — never awaited
    /// inline with user-visible sync/refresh work, so it can't delay them.
    /// `schedulePostSyncPrefetchIfNeeded(for:auth:)` is this method's Task
    /// #63 sibling — same candidate query/window, but triggered per-account
    /// right after that account's own incremental sync completes, instead
    /// of only at launch/foreground.
    ///
    /// - Debounced to at most once per `unifiedInboxPrefetchInterval` (see
    ///   its doc comment) — a no-op, returning `0`, when called again too
    ///   soon.
    /// - Silent best-effort throughout: an offline device, an account whose
    ///   credentials can't be resolved (`authProvider` throwing), a
    ///   `connect()`/`select()` failure, or an individual message's fetch
    ///   failing all just skip that piece and move on — no error banner,
    ///   no thrown error, so a broken connection at launch never surfaces
    ///   as a user-visible failure for a feature the user never asked to
    ///   run. There's always a next foreground to try again.
    /// - Sequential per account (`for account in accounts`), one account's
    ///   candidates fetched over one connection before moving to the next
    ///   — deliberately not fanned out in parallel, matching every other
    ///   per-account loop in this codebase (`RootView.syncAllAccountsOnce`/
    ///   `startIdleLoops`), so this doesn't open `accounts.count` IMAP
    ///   connections at once on every foreground.
    /// - `authProvider` is injected (rather than this actor resolving
    ///   credentials itself) because `SyncEngine` has no dependency on
    ///   Keychain/OAuth — `AppEnvironment.auth(for:)` is the real caller in
    ///   production; tests pass a trivial closure.
    ///
    /// Returns the number of messages actually fetched (for tests; the
    /// caller doesn't need this).
    @discardableResult
    public func prefetchUnifiedInboxBodiesIfNeeded(
        accounts: [AccountRecord],
        now: Date = Date(),
        authProvider: @Sendable (AccountRecord) async throws -> MailAuth
    ) async -> Int {
        if let last = lastUnifiedInboxPrefetchDate, now.timeIntervalSince(last) < Self.unifiedInboxPrefetchInterval {
            return 0
        }
        // Recorded regardless of what's found below (even "no accounts" or
        // "no candidates") — matches `AppEnvironment
        // .reconcilePushWatchesIfNeeded()`'s "the throttle protects against
        // repeating the attempt, not against repeating a specific outcome"
        // convention.
        lastUnifiedInboxPrefetchDate = now
        guard !accounts.isEmpty else { return 0 }

        return await runUnifiedInboxPrefetch(
            accounts: accounts,
            since: now.addingTimeInterval(-Self.unifiedInboxPrefetchWindow),
            authProvider: authProvider
        )
    }

    /// Task #63 follow-up to `prefetchUnifiedInboxBodiesIfNeeded`'s
    /// launch/foreground pass: "各メールボックスの同期完了後にも1回" — called
    /// from `syncAccountIncrementally` right after a successful sync, so
    /// newly-arrived mail's body is usually already local by the time the
    /// message list re-renders with it, not only at the next
    /// launch/foreground. Scoped to just `account` (the one that just
    /// synced) rather than every account, since that's the only account
    /// that could plausibly have new unified-inbox candidates as of this
    /// exact sync completing.
    ///
    /// Fires as a detached, low-priority `Task` — never awaited inline —
    /// so it can never delay `syncAccountIncrementally`'s own caller
    /// (pull-to-refresh, IDLE wake-ups, `OtegamiApp.syncAllAccountsOnce()`),
    /// matching every other prefetch entry point's "must not block
    /// user-visible sync" rule.
    ///
    /// Debounced per-account (`lastPostSyncPrefetchDateByAccount`,
    /// `postSyncPrefetchInterval`) — see that property's doc comment for
    /// why it doesn't share `lastUnifiedInboxPrefetchDate`/
    /// `unifiedInboxPrefetchInterval` with the launch/foreground pass.
    ///
    /// Cannot infinite-loop: this only ever opens its own short-lived IMAP
    /// session and calls `bodyFetcher.fetchBody` directly — never
    /// `syncAccountIncrementally` itself — and fetching a body only ever
    /// changes `MessageRecord.bodyState`/body columns, which nothing in
    /// this app treats as a trigger for another `syncAccountIncrementally`
    /// call (no database-change observer wires the two together). A body
    /// fetched here therefore can't cause a resync that reschedules this
    /// same prefetch again.
    private func schedulePostSyncPrefetchIfNeeded(for account: AccountRecord, auth: MailAuth) {
        let now = Date()
        if let last = lastPostSyncPrefetchDateByAccount[account.id], now.timeIntervalSince(last) < Self.postSyncPrefetchInterval {
            return
        }
        lastPostSyncPrefetchDateByAccount[account.id] = now
        lastPostSyncPrefetchTask = Task(priority: .background) { [weak self] in
            guard let self else { return 0 }
            return await self.runUnifiedInboxPrefetch(
                accounts: [account],
                since: now.addingTimeInterval(-Self.unifiedInboxPrefetchWindow),
                authProvider: { _ in auth }
            )
        }
    }

    /// The `Task` `schedulePostSyncPrefetchIfNeeded` most recently created
    /// (`nil` if none has run yet, or the last call was itself debounced) —
    /// exists purely so `waitForPendingPostSyncPrefetchForTesting()` below
    /// has something to await; production code never reads this.
    private var lastPostSyncPrefetchTask: Task<Int, Never>?

    /// Test-only synchronization hook (not `public` — reachable only via
    /// `@testable import SyncEngine`, same pattern as `RelayStore
    /// .rawEncryptedSecretForTesting()`): awaits the post-sync prefetch
    /// `Task` scheduled by the most recent `syncAccountIncrementally` call,
    /// if any, so a test can assert on its result deterministically instead
    /// of racing a detached background `Task` that production code
    /// deliberately never waits for (see `schedulePostSyncPrefetchIfNeeded`'s
    /// doc comment for why it must stay detached). Returns `nil` if no
    /// post-sync prefetch was scheduled (e.g. the call was debounced).
    func waitForPendingPostSyncPrefetchForTesting() async -> Int? {
        await lastPostSyncPrefetchTask?.value
    }

    /// Shared worker behind both `prefetchUnifiedInboxBodiesIfNeeded` (the
    /// launch/foreground pass) and `schedulePostSyncPrefetchIfNeeded` (the
    /// post-sync trigger) — everything except the debounce bookkeeping,
    /// which differs between the two callers (see each one's doc comment).
    /// Always applies `unifiedInboxPrefetchCandidateLimit` as the safety
    /// cap described on that constant.
    private func runUnifiedInboxPrefetch(
        accounts: [AccountRecord],
        since: Date,
        authProvider: @Sendable (AccountRecord) async throws -> MailAuth
    ) async -> Int {
        let accountIds = accounts.map(\.id)
        let candidates: [UnifiedInboxPrefetchCandidate]
        do {
            candidates = try await database.dbWriter.read { db in
                try MessageQuery.unfetchedUnifiedInboxCandidates(
                    accountIds: accountIds,
                    since: since,
                    limit: Self.unifiedInboxPrefetchCandidateLimit,
                    db: db
                )
            }
        } catch {
            return 0
        }
        guard !candidates.isEmpty else { return 0 }

        var candidatesByAccount: [String: [UnifiedInboxPrefetchCandidate]] = [:]
        for candidate in candidates {
            candidatesByAccount[candidate.accountId, default: []].append(candidate)
        }

        var fetchedCount = 0
        for account in accounts {
            guard let group = candidatesByAccount[account.id], let mailboxPath = group.first?.mailboxPath else { continue }
            guard let auth = try? await authProvider(account) else { continue }

            let session = sessionFactory(account.imapConfig)
            do {
                try await session.connect(auth: auth)
            } catch {
                continue
            }
            defer {
                let session = session
                Task { await session.disconnect() }
            }
            guard (try? await session.select(mailboxPath)) != nil else { continue }

            for candidate in group {
                // Re-check fresh state right before fetching, not the
                // (possibly stale) `bodyState` the candidate list captured
                // at query time — something else (the on-open fetch, an
                // earlier prefetch pass) may have already fetched this
                // exact message by now. `BodyFetcher.fetchBody` itself
                // always forces a fetch regardless of `bodyState` (its
                // `prefetchRecent`/on-open/compose-quote callers rely on
                // that to force a refresh on demand), so this "already
                // fetched? skip" check belongs here, specific to this
                // best-effort prefetch pass, not in the shared fetch
                // entry point.
                guard let messageId = candidate.message.id else { continue }
                let current = try? await database.dbWriter.read { db in
                    try MessageRecord.fetchOne(db, key: messageId)
                }
                if current?.bodyState == .fetched { continue }

                if (try? await bodyFetcher.fetchBody(message: candidate.message, mailboxPath: mailboxPath, session: session)) != nil {
                    fetchedCount += 1
                }
            }
        }
        return fetchedCount
    }

    // MARK: - 古いメールのバックフィル同期

    /// How many `BackfillSyncer.backfillOneBatch` calls one background pass
    /// makes for a single mailbox before moving on to the next candidate —
    /// keeps one mailbox's backfill from monopolizing an entire pass's
    /// budget (`backfillMaxBatchesPerCycle` below) even when it has far
    /// more still-unscanned history than every other candidate combined.
    public static let backfillBatchesPerMailboxPerCycle = 2

    /// Overall cap on `BackfillSyncer.backfillOneBatch` calls across every
    /// mailbox one background pass (`runBackfill(account:auth:)`) touches —
    /// bounds one pass's worst case (a freshly-migrated account with many
    /// mailboxes all needing backfill) rather than opening an unbounded
    /// number of `FETCH` batches on one connection. Deliberately modest:
    /// this is a low-priority background feature ("数セッションで全履歴が
    /// ローカル化される設計" — the plan explicitly trades speed for staying
    /// out of the way of real, user-visible sync work), not a bulk import.
    public static let backfillMaxBatchesPerCycle = 4

    /// Debounce for `scheduleBackfillIfNeeded` — same rationale as
    /// `postSyncPrefetchInterval`'s doc comment (a busy account's frequent
    /// IDLE wake-ups shouldn't each open their own backfill connection),
    /// but a longer window: unlike a body prefetch, one backfill pass can
    /// issue up to `backfillMaxBatchesPerCycle` full `FETCH` batches, so
    /// this needs to stay out of the way of `IDLE`-wake-frequency sync far
    /// more conservatively.
    private static let backfillInterval: TimeInterval = 5 * 60

    /// In-memory only, same rationale as `lastPostSyncPrefetchDateByAccount`.
    private var lastBackfillDateByAccount: [String: Date] = [:]

    /// The `Task` `scheduleBackfillIfNeeded` most recently created — same
    /// "test-only synchronization handle, production never reads it" shape
    /// as `lastPostSyncPrefetchTask`.
    private var lastBackfillTask: Task<Void, Never>?

    /// Records a backfill attempt for `account` (debounced — see
    /// `backfillInterval`'s doc comment) and fires it as a detached,
    /// low-priority `Task`, never awaited inline — same "must not delay
    /// `syncAccountIncrementally`'s own caller" rule as
    /// `schedulePostSyncPrefetchIfNeeded`'s identical shape, since this
    /// runs right after every successful `syncAccountIncrementally` call
    /// that didn't opt out via `schedulesBackfill: false`.
    private func scheduleBackfillIfNeeded(for account: AccountRecord, auth: MailAuth) {
        let now = Date()
        if let last = lastBackfillDateByAccount[account.id], now.timeIntervalSince(last) < Self.backfillInterval {
            return
        }
        lastBackfillDateByAccount[account.id] = now
        lastBackfillTask = Task(priority: .background) { [weak self] in
            await self?.runBackfill(account: account, auth: auth)
        }
    }

    /// The actual background pass: finds every non-hidden mailbox of
    /// `account` still needing backfill (`mailbox.backfillLowerBound > 1`
    /// — the same "同期も止める"/"メールボックス単位の非表示" judgment
    /// `SyncScope.all`'s own filter already applies, since a hidden
    /// mailbox's whole point is paying no further sync cost), INBOX first
    /// (見出しの「まずはINBOX優先」— everything else keeps whatever order
    /// the query returns it in, since the plan calls a stricter ordering
    /// "複雑になるなら順不同で可"), then opens one connection and runs up
    /// to `backfillBatchesPerMailboxPerCycle` batches per mailbox until
    /// either that mailbox completes, the per-mailbox cap is reached, or
    /// this whole pass's `backfillMaxBatchesPerCycle` budget runs out.
    ///
    /// Entirely best-effort and silent, matching every other background
    /// prefetch entry point in this file: a connection failure, a `select`
    /// failure on one candidate mailbox, or one batch throwing just skips
    /// that piece and moves on (or, for a thrown batch, stops that
    /// mailbox and moves to the next candidate) — this is a low-priority
    /// feature that gets another chance next cycle, not a user-visible
    /// sync whose failure should surface anywhere.
    private func runBackfill(account: AccountRecord, auth: MailAuth) async {
        struct Candidate { var mailboxId: Int64; var path: String }

        let pendingMailboxes: [MailboxRecord]
        do {
            pendingMailboxes = try await database.dbWriter.read { db in
                let request = MailboxRecord
                    .filter(Column("accountId") == account.id)
                    .filter(Column("isHidden") == false)
                    .filter(Column("backfillLowerBound") > 1)
                return try request.fetchAll(db)
            }
        } catch {
            return
        }
        let sortedMailboxes = pendingMailboxes.sorted { lhs, rhs in
            (lhs.role == .inbox ? 0 : 1) < (rhs.role == .inbox ? 0 : 1)
        }
        let candidates: [Candidate] = sortedMailboxes.compactMap { record in
            guard let mailboxId = record.id else { return nil }
            return Candidate(mailboxId: mailboxId, path: record.path)
        }
        guard !candidates.isEmpty else { return }

        let session = sessionFactory(account.imapConfig)
        do {
            try await session.connect(auth: auth)
        } catch {
            return
        }
        defer {
            let session = session
            Task { await session.disconnect() }
        }

        var totalBatches = 0
        for candidate in candidates {
            guard totalBatches < Self.backfillMaxBatchesPerCycle else { break }
            guard (try? await session.select(candidate.path)) != nil else { continue }

            for _ in 0..<Self.backfillBatchesPerMailboxPerCycle {
                guard totalBatches < Self.backfillMaxBatchesPerCycle else { break }
                let mailboxRecord: MailboxRecord
                do {
                    guard let record = try await database.dbWriter.read({ db in
                        try MailboxRecord.fetchOne(db, key: candidate.mailboxId)
                    }) else { break }
                    mailboxRecord = record
                } catch {
                    break
                }
                guard mailboxRecord.backfillLowerBound > 1 else { break }

                guard let result = try? await backfillSyncer.backfillOneBatch(
                    mailboxRecord: mailboxRecord,
                    mailboxPath: candidate.path,
                    accountId: account.id,
                    session: session
                ) else { break }
                totalBatches += 1
                if result.isComplete { break }
            }
        }
    }

    /// Test-only synchronization hook (not `public` — reachable only via
    /// `@testable import SyncEngine`), same pattern as
    /// `waitForPendingPostSyncPrefetchForTesting()`: awaits the backfill
    /// `Task` scheduled by the most recent `syncAccountIncrementally` call,
    /// if any, so a test can assert on its effects deterministically
    /// instead of racing a detached background `Task` production code
    /// deliberately never awaits inline. A no-op (returns immediately) if
    /// no backfill was scheduled (e.g. the call was debounced, or every
    /// mailbox was already complete).
    func waitForPendingBackfillForTesting() async {
        await lastBackfillTask?.value
    }

    // MARK: - Task #80: list/search-update-triggered background prefetch

    /// How many of the leading not-yet-fetched messages in a just-updated
    /// list `MessageListView`/`SearchScreenView` ask
    /// `prefetchMessageBodies(messageIds:accounts:authProvider:)` to fetch —
    /// shared by both call sites so "top of whatever's currently on screen"
    /// means the same thing everywhere, matching `BodyFetcher
    /// .defaultPrefetchLimit`'s identical role for the post-initial-sync
    /// prefetch.
    public static let listUpdatePrefetchLimit = 50

    /// Task #80 (「直近3日200件だけでなく、検索結果など、メール一覧が更新
    /// されたときに、バックグラウンドでメールを取得するようにしてほしい」):
    /// fetches bodies for whichever of `messageIds` don't have one yet, as a
    /// general-purpose sibling to `prefetchUnifiedInboxBodiesIfNeeded`'s
    /// fixed "unified inbox, last 3 days" candidate set — here the *caller*
    /// decides which ids matter (`MessageListView`/`SearchScreenView` pass
    /// the leading `listUpdatePrefetchLimit` of whatever list/search-result
    /// content just came on screen, threading/flat mode and search scope
    /// already resolved by the time this is called).
    ///
    /// Re-reads each id's current `MessageRecord`/owning `MailboxRecord`
    /// fresh from the database rather than trusting anything the caller
    /// captured earlier — by the time this actually runs (typically hopped
    /// through a low-priority background `Task`), an id could already be
    /// `.fetched` (the on-open fetch, or another prefetch pass, beat it to
    /// it), or its owning mailbox could have changed. An id whose message
    /// row is gone, already `.fetched`, or whose mailbox's account isn't in
    /// `accounts` is simply skipped — not our job to fetch on behalf of an
    /// account this call wasn't told about.
    ///
    /// Grouped by account first (one IMAP connection open at a time, in
    /// `accounts` order — the same "don't fan out N accounts' connections
    /// at once" convention `runUnifiedInboxPrefetch` and every other
    /// per-account loop in this app follow), then by `mailboxPath` *within*
    /// that account: unlike the unified-inbox candidate set (always exactly
    /// one inbox-role mailbox per account), an arbitrary id list can span
    /// more than one mailbox of the same account — a search result mixing
    /// an INBOX hit with an Archive hit, say — so each distinct mailboxPath
    /// gets its own `select` before fetching the messages that belong to
    /// it.
    ///
    /// No debounce and no "did the list actually change" diffing here —
    /// that's the caller's responsibility (`MessageListView`/
    /// `SearchScreenView` each debounce their own trigger a few seconds and
    /// skip re-running for unchanged content, since a search box firing
    /// this on every keystroke would be its own bug). This method only ever
    /// applies the same best-effort/offline-silent behavior every other
    /// prefetch entry point here already has: a connection failure, a
    /// credential resolution failure, or one message's fetch failing all
    /// just skip that piece and move on — no thrown error, no error banner.
    ///
    /// Shares `BodyFetcher.fetchBody`'s per-message in-flight dedupe with
    /// every other caller (the on-open fetch, the unified-inbox prefetch
    /// passes) — two overlapping calls to this method (e.g. the list and
    /// search screens both prefetching the same message) or a race with the
    /// on-open fetch never triggers two independent network fetches for the
    /// same message id.
    ///
    /// Returns the number of messages actually fetched (for tests; the
    /// caller doesn't need this).
    @discardableResult
    public func prefetchMessageBodies(
        messageIds: [Int64],
        accounts: [AccountRecord],
        authProvider: @Sendable (AccountRecord) async throws -> MailAuth
    ) async -> Int {
        guard !messageIds.isEmpty, !accounts.isEmpty else { return 0 }
        let knownAccountIds = Set(accounts.map(\.id))

        struct Candidate {
            var message: MessageRecord
            var accountId: String
            var mailboxPath: String
        }

        let candidates: [Candidate]
        do {
            candidates = try await database.dbWriter.read { db in
                var result: [Candidate] = []
                for messageId in messageIds {
                    guard let message = try MessageRecord.fetchOne(db, key: messageId),
                          message.bodyState != .fetched,
                          let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId),
                          knownAccountIds.contains(mailbox.accountId)
                    else { continue }
                    result.append(Candidate(message: message, accountId: mailbox.accountId, mailboxPath: mailbox.path))
                }
                return result
            }
        } catch {
            return 0
        }
        guard !candidates.isEmpty else { return 0 }

        var candidatesByAccount: [String: [Candidate]] = [:]
        for candidate in candidates {
            candidatesByAccount[candidate.accountId, default: []].append(candidate)
        }

        var fetchedCount = 0
        for account in accounts {
            guard let group = candidatesByAccount[account.id] else { continue }
            guard let auth = try? await authProvider(account) else { continue }

            let session = sessionFactory(account.imapConfig)
            do {
                try await session.connect(auth: auth)
            } catch {
                continue
            }
            defer {
                let session = session
                Task { await session.disconnect() }
            }

            // Sub-group by mailboxPath, preserving first-seen order —
            // `select` each distinct mailbox once rather than re-selecting
            // per message.
            var mailboxOrder: [String] = []
            var candidatesByMailbox: [String: [MessageRecord]] = [:]
            for candidate in group {
                if candidatesByMailbox[candidate.mailboxPath] == nil {
                    mailboxOrder.append(candidate.mailboxPath)
                }
                candidatesByMailbox[candidate.mailboxPath, default: []].append(candidate.message)
            }

            for mailboxPath in mailboxOrder {
                guard (try? await session.select(mailboxPath)) != nil else { continue }
                for message in candidatesByMailbox[mailboxPath] ?? [] {
                    guard let messageId = message.id else { continue }
                    // Re-check fresh state right before fetching — see this
                    // method's doc comment on why the candidate list alone
                    // can't be trusted as of the moment this actually runs.
                    let current = try? await database.dbWriter.read { db in
                        try MessageRecord.fetchOne(db, key: messageId)
                    }
                    if current?.bodyState == .fetched { continue }

                    if (try? await bodyFetcher.fetchBody(message: message, mailboxPath: mailboxPath, session: session)) != nil {
                        fetchedCount += 1
                    }
                }
            }
        }
        return fetchedCount
    }

    // MARK: - Task #152: post-replay targeted resync

    /// Records a targeted-resync request for `account`/`mailboxIds` (see
    /// `TargetedResyncScheduler`'s doc comment for the debounce/coalesce
    /// policy this defers to) and makes sure the loop that will eventually
    /// act on it is running. Cheap and non-blocking — never opens a
    /// connection itself, just updates in-memory state and, at most, starts
    /// one background `Task` the first time this account (or any account)
    /// has a pending request.
    private func scheduleTargetedResync(account: AccountRecord, auth: MailAuth, mailboxIds: Set<Int64>) {
        guard !mailboxIds.isEmpty else { return }
        let now = Date()
        targetedResyncContext[account.id] = (account, auth)
        targetedResyncScheduler.request(accountId: account.id, mailboxIds: mailboxIds, now: now)
        Self.opReflectLogger.notice("targeted resync requested accountId=\(account.id, privacy: .private) mailboxCount=\(mailboxIds.count) debounceUntil=\(now.addingTimeInterval(self.targetedResyncScheduler.debounceInterval).timeIntervalSince1970)")
        ensureTargetedResyncLoopRunning()
    }

    /// Starts `runTargetedResyncLoop()` if it isn't already running — a
    /// no-op when a loop from an earlier `scheduleTargetedResync` call is
    /// still alive (it will pick up this newest request too, since it reads
    /// `targetedResyncScheduler`/`targetedResyncContext` fresh on every
    /// pass). The loop naturally exits (and this goes back to `nil`) once
    /// `targetedResyncScheduler.nextFireAt` is `nil` — nothing left pending
    /// — rather than running forever in the background.
    private func ensureTargetedResyncLoopRunning() {
        guard targetedResyncLoopTask == nil else { return }
        targetedResyncLoopTask = Task { [weak self] in
            await self?.runTargetedResyncLoop()
        }
    }

    /// Sleeps until the next pending request's debounce window elapses,
    /// fires every account that's due as of then, and repeats — exits (back
    /// to `targetedResyncLoopTask = nil`) once nothing is pending, so a
    /// quiet app doesn't keep a `Task` alive doing nothing between bursts of
    /// operations. Actor-isolated like every other method here, so reading/
    /// mutating `targetedResyncScheduler`/`targetedResyncContext` across the
    /// `await Task.sleep` below is race-free — a `scheduleTargetedResync`
    /// call that arrives mid-sleep just updates the same in-memory state
    /// this loop re-reads the next time it wakes.
    private func runTargetedResyncLoop() async {
        while true {
            guard let nextFireAt = targetedResyncScheduler.nextFireAt else { break }
            let interval = nextFireAt.timeIntervalSinceNow
            if interval > 0 {
                try? await Task.sleep(for: .seconds(interval))
            }
            let due = targetedResyncScheduler.due(now: Date())
            for (accountId, mailboxIds) in due {
                guard let context = targetedResyncContext.removeValue(forKey: accountId) else { continue }
                await performTargetedResync(account: context.account, auth: context.auth, mailboxIds: mailboxIds)
            }
        }
        targetedResyncLoopTask = nil
    }

    /// The actual prioritized resync: resolves `mailboxIds` to their current
    /// paths and syncs exactly that set over one connection
    /// (`SyncScope.mailboxes(paths:)`), reusing the same `MailboxSyncer`
    /// path every other incremental sync goes through — no bespoke
    /// mailbox-mutation logic here, so this can't diverge from (or race)
    /// Task #83's forced-UID-SEARCH reconciliation or Task #120's
    /// placeholder-relocation matching, both of which already live inside
    /// that shared path. `autoRetry: false` and
    /// `forceReconcileVanishedUIDs: false`: this is a frequent, best-effort,
    /// already-debounced background trigger — the same reasoning
    /// `syncAccountIncrementally`'s own doc comment gives for why its IDLE-
    /// wake/post-sync-prefetch call sites leave `forceReconcileVanishedUIDs`
    /// at `false`, and Task #69's automatic-retry policy exists for
    /// longer-lived sync passes, not a short, frequently-repeated targeted
    /// nudge like this one — a failure here just means the next opQueue
    /// replay (or the periodic full-account sweep, unchanged by this task)
    /// eventually catches it up instead.
    private func performTargetedResync(account: AccountRecord, auth: MailAuth, mailboxIds: Set<Int64>) async {
        let start = Date()
        let paths: [String]
        do {
            paths = try await database.dbWriter.read { db in
                try MailboxRecord.filter(keys: mailboxIds).fetchAll(db).map(\.path)
            }
        } catch {
            return
        }
        guard !paths.isEmpty else { return }
        Self.opReflectLogger.notice("targeted resync starting accountId=\(account.id, privacy: .private) mailboxCount=\(paths.count)")
        _ = try? await syncAccountIncrementally(
            account, auth: auth, scope: .mailboxes(paths: Set(paths)),
            autoRetry: false, forceReconcileVanishedUIDs: false
        )
        Self.opReflectLogger.notice("targeted resync completed accountId=\(account.id, privacy: .private) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1000))")
    }

    /// Test-only synchronization hook (not `public` — reachable only via
    /// `@testable import SyncEngine`, same pattern as `waitForPendingPost
    /// SyncPrefetchForTesting()` above): awaits the targeted-resync loop
    /// `Task` if one is currently running, so a test can assert on its
    /// effects deterministically instead of racing a detached background
    /// loop production code deliberately never awaits inline. A no-op
    /// (returns immediately) if nothing is pending.
    func waitForPendingTargetedResyncForTesting() async {
        await targetedResyncLoopTask?.value
    }

    // MARK: - Server search fallback (検索の IMAP サーバーサイド SEARCH フォールバック)

    /// Default overall budget for `serverSearch(query:accounts:authProvider:
    /// timeout:)` — a "サーバーで検索" tap is user-initiated and blocking (the
    /// screen shows a spinner), so this needs to be short enough that a
    /// slow/unreachable account doesn't leave the user staring at a spinner
    /// indefinitely, while still leaving enough headroom for a handful of
    /// sequential per-mailbox `SEARCH`+`FETCH` round trips on a normal
    /// connection.
    public static let defaultServerSearchTimeout: Duration = .seconds(20)

    /// Runs `ServerSearchService.search(account:query:session:)` for every
    /// account in `accounts`, concurrently (each account opens and manages
    /// its own connection independently — no shared IMAP connection, no
    /// per-account serialization needed since `IMAPSessionProtocol`
    /// conformers are already actors), and merges the results — the
    /// `SyncCoordinator`-level entry point `SearchScreenView`'s「サーバーで
    /// 検索」button calls, never auto-triggered.
    ///
    /// **Per-account failure tolerance**: one account's connect/auth/search
    /// failure never blocks the others — its id lands in
    /// `ServerSearchOutcome.failedAccountIds` instead of throwing.
    ///
    /// **Overall timeout**: implemented as a race against `Task.sleep`
    /// rather than structured `TaskGroup` cancellation. Putting each
    /// account's work in a `TaskGroup` and calling `cancelAll()` on timeout
    /// wouldn't actually bound this method's wall-clock time — MailCore2's
    /// callback-based API means an in-flight `SEARCH`/`FETCH`'s
    /// `withCheckedThrowingContinuation` can't be interrupted, only waited
    /// out, and Swift's structured concurrency requires `withTaskGroup` to
    /// await every child before returning even after `cancelAll()`. Instead,
    /// each account's search runs as an independent unstructured `Task`
    /// that reports into a shared `ServerSearchCollector`; this method waits
    /// for either "every account reported in" or `timeout` to elapse,
    /// whichever comes first, and returns whatever the collector has
    /// gathered at that point. A still-running account's `Task` is simply
    /// abandoned (not cancelled/awaited) — its eventual result, if any,
    /// only ever reaches a `ServerSearchCollector` nothing still references,
    /// so it's harmless, just wasted work.
    public func serverSearch(
        query: String,
        accounts: [AccountRecord],
        authProvider: @escaping @Sendable (AccountRecord) async throws -> MailAuth,
        timeout: Duration = SyncCoordinator.defaultServerSearchTimeout
    ) async -> ServerSearchOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !accounts.isEmpty else { return ServerSearchOutcome() }

        let collector = ServerSearchCollector(accountCount: accounts.count)
        let service = serverSearchService
        let sessionFactory = self.sessionFactory

        for account in accounts {
            Task {
                do {
                    let auth = try await authProvider(account)
                    let session = sessionFactory(account.imapConfig)
                    try await session.connect(auth: auth)
                    defer {
                        let session = session
                        Task { await session.disconnect() }
                    }
                    let summaries = try await service.search(account: account, query: trimmed, session: session)
                    await collector.recordSuccess(summaries)
                } catch {
                    await collector.recordFailure(accountId: account.id)
                }
            }
        }

        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            await collector.markTimedOut()
        }
        let timedOut = await collector.waitForCompletionOrTimeout()
        timeoutTask.cancel()

        let (summaries, failedAccountIds) = await collector.snapshot()
        let sorted = summaries.sorted { lhs, rhs in
            let lhsDate = lhs.latestMessage?.date ?? lhs.latestMessage?.internalDate ?? .distantPast
            let rhsDate = rhs.latestMessage?.date ?? rhs.latestMessage?.internalDate ?? .distantPast
            return lhsDate > rhsDate
        }
        return ServerSearchOutcome(summaries: sorted, failedAccountIds: failedAccountIds, timedOut: timedOut)
    }

    private func syncer(for account: AccountRecord) -> AccountSyncer {
        if let existing = syncers[account.id] {
            return existing
        }
        // Task #221: shares this coordinator's own `bodyFetcher` rather
        // than letting `AccountSyncer` default-construct a second,
        // independent one — see `AccountSyncer.init`'s doc comment for why
        // that split used to fragment in-flight dedup/self-heal state
        // across the two.
        let syncer = AccountSyncer(
            account: account,
            database: database,
            sessionFactory: sessionFactory,
            idleSessionFactory: idleSessionFactory,
            bodyFetcher: bodyFetcher
        )
        syncers[account.id] = syncer
        return syncer
    }
}

/// `SyncCoordinator.serverSearch(query:accounts:authProvider:timeout:)`'s
/// result: every hit's `ThreadSummary` (existing local rows and freshly-
/// ingested ones alike, newest first — see `ServerSearchService.search`'s
/// doc comment on why no further local re-filtering happens on top of what
/// the server itself matched), which accounts (if any) failed to connect/
/// search, and whether the overall budget ran out before every account
/// finished reporting in.
public struct ServerSearchOutcome: Sendable, Equatable {
    public var summaries: [ThreadSummary]
    public var failedAccountIds: [String]
    public var timedOut: Bool

    public init(summaries: [ThreadSummary] = [], failedAccountIds: [String] = [], timedOut: Bool = false) {
        self.summaries = summaries
        self.failedAccountIds = failedAccountIds
        self.timedOut = timedOut
    }
}

/// The shared accumulator `SyncCoordinator.serverSearch` hands one
/// unstructured `Task` per account — see that method's doc comment for why
/// this isn't a `TaskGroup`. Collects results as they land and lets the
/// caller wait for either "every account has reported in" or an external
/// `markTimedOut()` call, whichever happens first.
actor ServerSearchCollector {
    private var summaries: [ThreadSummary] = []
    private var failedAccountIds: [String] = []
    /// Dedupes by `ThreadSummary.id` (== the underlying message id for the
    /// flat-mode summaries `ServerSearchService.search` always builds) —
    /// two accounts can't share a message, but the same account could in
    /// principle report the same message twice if a future caller ever
    /// passed overlapping account lists; deduping here rather than trusting
    /// every future caller to pre-dedupe its own `accounts` is the cheaper
    /// invariant to maintain.
    private var seenIds = Set<Int64>()
    private var remaining: Int
    private var resolved = false
    private var didTimeOut = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(accountCount: Int) {
        remaining = accountCount
    }

    func recordSuccess(_ result: [ThreadSummary]) {
        for summary in result where seenIds.insert(summary.id).inserted {
            summaries.append(summary)
        }
        remaining -= 1
        if remaining <= 0 { resolve(timedOut: false) }
    }

    func recordFailure(accountId: String) {
        failedAccountIds.append(accountId)
        remaining -= 1
        if remaining <= 0 { resolve(timedOut: false) }
    }

    func markTimedOut() {
        resolve(timedOut: true)
    }

    /// Suspends until every account has reported in (`recordSuccess`/
    /// `recordFailure` reaching `remaining <= 0`) or `markTimedOut()` is
    /// called, whichever comes first — a no-op returning immediately if
    /// that already happened before this was called (covers the case where
    /// every account finishes before the caller even starts waiting).
    /// Returns whether the timeout is what ended the wait.
    func waitForCompletionOrTimeout() async -> Bool {
        guard !resolved else { return didTimeOut }
        await withCheckedContinuation { self.continuation = $0 }
        return didTimeOut
    }

    func snapshot() -> (summaries: [ThreadSummary], failedAccountIds: [String]) {
        (summaries, failedAccountIds)
    }

    private func resolve(timedOut: Bool) {
        guard !resolved else { return }
        resolved = true
        didTimeOut = timedOut
        continuation?.resume()
        continuation = nil
    }
}
