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
    private let opQueueProcessor: OpQueueProcessor

    public init(
        database: AppDatabase,
        sessionFactory: @escaping @Sendable (IMAPConfig) -> any IMAPSessionProtocol
    ) {
        self.database = database
        self.sessionFactory = sessionFactory
        self.bodyFetcher = BodyFetcher(database: database)
        self.opQueueProcessor = OpQueueProcessor(database: database, sessionFactory: sessionFactory)
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

    /// Differential sync (M3): only fetches what changed since the last
    /// sync (new mail, flag changes, uidValidity-triggered resync) rather
    /// than re-walking the whole initial-sync window. What pull-to-refresh,
    /// foreground-resume, and IDLE wake-ups all call — see
    /// `AccountSyncer.performIncrementalSync`'s doc comment for the exact
    /// per-mailbox behavior.
    @discardableResult
    public func syncAccountIncrementally(_ account: AccountRecord, auth: MailAuth) async throws -> MailboxSyncer.Progress {
        let syncer = syncer(for: account)
        return try await syncer.performIncrementalSync(auth: auth)
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

    private func syncer(for account: AccountRecord) -> AccountSyncer {
        if let existing = syncers[account.id] {
            return existing
        }
        let syncer = AccountSyncer(account: account, database: database, sessionFactory: sessionFactory)
        syncers[account.id] = syncer
        return syncer
    }
}
