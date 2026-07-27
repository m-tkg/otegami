import Foundation
import MailTransport
import OtegamiStore

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
    private var syncers: [String: AccountSyncer] = [:]
    private let bodyFetcher: BodyFetcher
    private let attachmentFetcher: AttachmentFetcher
    private let opQueueProcessor: OpQueueProcessor

    public init(
        database: AppDatabase,
        sessionFactory: @escaping @Sendable (IMAPConfig) -> any IMAPSessionProtocol,
        smtpSessionFactory: @escaping @Sendable (SMTPConfig) -> any SMTPSessionProtocol = { config in NotImplementedSMTPSession(config: config) },
        messageBuilder: @escaping @Sendable (ComposeDraft) -> BuiltMessage = { _ in
            BuiltMessage(data: Data(), messageId: "<unbuilt@otegami.local>")
        }
    ) {
        self.database = database
        self.sessionFactory = sessionFactory
        self.bodyFetcher = BodyFetcher(database: database)
        self.attachmentFetcher = AttachmentFetcher(database: database)
        self.opQueueProcessor = OpQueueProcessor(
            database: database,
            sessionFactory: sessionFactory,
            smtpSessionFactory: smtpSessionFactory,
            messageBuilder: messageBuilder
        )
    }

    /// Runs initial sync for `account` (creating its `AccountSyncer` if
    /// this is the first sync since launch). Safe to call again — e.g. from
    /// a manual refresh or pull-to-refresh — since `AccountSyncer`'s
    /// initial sync upserts idempotently. Full differential sync (only
    /// fetching what changed since the last sync) lands in M3.
    @discardableResult
    public func syncAccount(
        _ account: AccountRecord,
        auth: MailAuth,
        onProgress: (@Sendable (AccountSyncer.Progress) -> Void)? = nil
    ) async throws -> AccountSyncer.Progress {
        let syncer = syncer(for: account)
        return try await syncer.performInitialSync(auth: auth, onProgress: onProgress)
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
        let session = sessionFactory(account.imapConfig)
        try await session.connect(auth: auth)
        defer {
            let session = session
            Task { await session.disconnect() }
        }
        _ = try await session.select(mailboxPath)
        try await bodyFetcher.fetchBody(message: message, mailboxPath: mailboxPath, session: session)
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
        let session = sessionFactory(account.imapConfig)
        try await session.connect(auth: auth)
        defer {
            let session = session
            Task { await session.disconnect() }
        }
        _ = try await session.select(mailboxPath)
        return try await attachmentFetcher.fetchAndStore(
            attachment: attachment,
            accountId: account.id,
            messageUID: messageUID,
            mailboxPath: mailboxPath,
            session: session
        )
    }

    /// Differential sync (M3): only fetches what changed since the last
    /// sync (new mail, flag changes, uidValidity-triggered resync) rather
    /// than re-walking the whole initial-sync window. What pull-to-refresh,
    /// foreground-resume, and IDLE wake-ups all call — see
    /// `AccountSyncer.performIncrementalSync`'s doc comment for the exact
    /// per-mailbox behavior.
    @discardableResult
    public func syncAccountIncrementally(
        _ account: AccountRecord,
        auth: MailAuth,
        scope: SyncScope = .inboxOnly
    ) async throws -> MailboxSyncer.Progress {
        let syncer = syncer(for: account)
        return try await syncer.performIncrementalSync(auth: auth, scope: scope)
    }

    /// Replays `account`'s queued offline operations (flag changes,
    /// moves/deletes) against the server. Cheap to call opportunistically
    /// — a no-op (no connection opened) when the queue is empty or
    /// nothing is due yet; see `OpQueueProcessor.replay`.
    @discardableResult
    public func replayOpQueue(for account: AccountRecord, auth: MailAuth) async throws -> OpQueueProcessor.ReplayResult {
        try await opQueueProcessor.replay(account: account, auth: auth)
    }

    /// Starts `account`'s foreground `IDLE` loop: on each server push,
    /// runs an incremental sync followed by an opQueue replay (a
    /// newly-online connection is exactly when queued offline operations
    /// should get their chance to flush). Meant to be called once when the
    /// app becomes active per M3's "フォアグラウンド IDLE" requirement — see
    /// `AccountSyncer.startIdleLoop`'s doc comment for the reconnect/backoff
    /// behavior underneath.
    public func startIdleLoop(for account: AccountRecord, auth: MailAuth) async {
        let syncer = syncer(for: account)
        await syncer.startIdleLoop(auth: auth) { [weak self] in
            guard let self else { return }
            _ = try? await self.syncAccountIncrementally(account, auth: auth)
            _ = try? await self.replayOpQueue(for: account, auth: auth)
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

    /// How many of the unified inbox's most-recently-received not-yet-
    /// fetched messages `prefetchUnifiedInboxBodiesIfNeeded` prefetches per
    /// launch/foreground pass (Task #31 — "直近30件程度" of what a user is
    /// likely to open next, mirroring `BodyFetcher.defaultPrefetchLimit`'s
    /// per-mailbox post-initial-sync counterpart but scoped to the unified
    /// inbox across every account, since that's what the message list
    /// actually shows first).
    public static let unifiedInboxPrefetchLimit = 30

    /// Debounce for `prefetchUnifiedInboxBodiesIfNeeded` — battery/network
    /// conscious "once per launch/foreground, not once per scenePhase
    /// blip" (locking/unlocking the device, or a quick app-switch-and-back,
    /// can otherwise fire `RootView.handleScenePhaseChange`'s `.active`
    /// case several times in quick succession).
    private static let unifiedInboxPrefetchInterval: TimeInterval = 5 * 60

    /// In-memory only (not persisted to `UserDefaults`) — deliberately
    /// resets on every process launch, so a cold launch always runs the
    /// prefetch once rather than being blocked by a debounce window from
    /// the *previous* process's last foreground.
    private var lastUnifiedInboxPrefetchDate: Date?

    /// Task #31 (docs/roadmap.md): background-prefetches bodies for the
    /// unified inbox's most recent `limit` not-yet-fetched messages, right
    /// after launch and on every foreground return — the fix for "さっき
    /// 読んだメールも、アプリを起動し直すと読み込みが入る?表示まで時間が
    /// かかる" (a message near the top of the list whose body was never
    /// lazily fetched otherwise pays a network round trip the moment it's
    /// opened, every time). Meant to be called from a low-priority,
    /// fire-and-forget `Task` (`RootView.handleScenePhaseChange`'s `.active`
    /// case) — never awaited inline with user-visible sync/refresh work, so
    /// it can't delay them.
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

        let accountIds = accounts.map(\.id)
        let candidates: [UnifiedInboxPrefetchCandidate]
        do {
            candidates = try await database.dbWriter.read { db in
                try MessageQuery.unfetchedUnifiedInboxCandidates(
                    accountIds: accountIds,
                    limit: Self.unifiedInboxPrefetchLimit,
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

    private func syncer(for account: AccountRecord) -> AccountSyncer {
        if let existing = syncers[account.id] {
            return existing
        }
        let syncer = AccountSyncer(account: account, database: database, sessionFactory: sessionFactory)
        syncers[account.id] = syncer
        return syncer
    }
}
