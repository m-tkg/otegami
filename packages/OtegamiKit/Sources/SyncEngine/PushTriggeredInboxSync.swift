import Foundation
import GRDB
import MailTransport
import OtegamiStore

/// Push 通知起点バックグラウンド受信 Phase 1: the entry point the
/// `NotificationService` Extension calls on every push receipt to actually
/// pull the new message's envelope (and, optionally, a body preview) into
/// the shared database *before* the notification is shown — rather than
/// only inferring/enriching from the bare `accountId`/`uidNext` payload the
/// way `NotificationService.enrich(...)`/`PushNotificationActionExecutor`
/// do today.
///
/// No UI in scope, no chance to show an error, and (crucially) no guarantee
/// the Extension process survives past the moment it hands its
/// `UNNotificationContent` back to the system — so, like
/// `PushNotificationActionExecutor`, every step here degrades silently to
/// "leave it for the next normal sync" rather than throw or retry. Every
/// internal failure (unknown account, no INBOX known yet, the sync itself
/// failing — including a `DatabaseSuspensionSupport.isSuspensionError(_:)`/
/// `SQLITE_BUSY` race against the app's own writer, see `AppDatabase
/// .makeConfiguration(observesSuspensionNotifications:)`'s doc comment for
/// why that race is now expected) is handled by giving up immediately and
/// returning an empty ``Outcome`` — there is no retry loop anywhere in this
/// type, on the theory that the next push (or the app's own next
/// foreground/IDLE sync) will simply catch things up.
///
/// Deliberately has no dependency on `MailTransportMailCore`, Keychain, or
/// any OAuth client — same rationale as `PushNotificationActionExecutor`'s
/// own doc comment: `sessionFactory`/`auth` are both injected, so this stays
/// independent of any specific transport/credential backend and is testable
/// with `FakeIMAPSession` + `AppDatabase.makeInMemory()` alone.
public enum PushTriggeredInboxSync {
    /// What one push-triggered sync pass managed to produce — both fields
    /// `nil` on any failure (see this type's own doc comment), or when the
    /// sync succeeded but the target message still isn't known locally
    /// (e.g. the `uidNext - 1` heuristic missed, or the server hadn't
    /// actually made the new message visible yet).
    public struct Outcome: Sendable {
        /// The locally-stored row for `uid = max(uidNext - 1, 1)` in the
        /// account's INBOX, if the sync found one — the same heuristic
        /// `PushNotificationActionExecutor`'s doc comment describes,
        /// factored into `PushNotificationActionExecutor.inferredTargetUID(
        /// uidNext:)`.
        public let message: MessageRecord?
        /// The account's INBOX unread count as of right after this sync, if
        /// it could be computed (i.e. the INBOX mailbox itself was
        /// resolvable — this doesn't depend on `message` being found).
        public let unreadCount: Int?

        public init(message: MessageRecord?, unreadCount: Int?) {
            self.message = message
            self.unreadCount = unreadCount
        }

        static let empty = Outcome(message: nil, unreadCount: nil)
    }

    /// Runs one push-triggered INBOX-only incremental sync for `accountId`,
    /// then resolves the pushed message (and, best-effort, its unread
    /// count) out of the freshly-synced database.
    ///
    /// - Parameter fetchBodyPreview: when `true` and the resolved message's
    ///   `bodyState` isn't already `.fetched`, also fetches (and persists)
    ///   its body over the same sync's session-factory — the "通知に本文の
    ///   プレビューを載せる" case. `false` skips this (and its extra network
    ///   round trip) for callers that only need the envelope/unread count,
    ///   e.g. a plain badge-count refresh.
    /// - Parameter sessionFactory: injected IMAP session factory — see this
    ///   type's own doc comment for why (mirrors `PushNotificationActionExecutor`).
    public static func run(
        accountId: String,
        uidNext: Int,
        fetchBodyPreview: Bool,
        database: AppDatabase,
        auth: MailAuth,
        sessionFactory: @escaping @Sendable (IMAPConfig) -> any IMAPSessionProtocol
    ) async -> Outcome {
        await run(
            accountId: accountId,
            uidNext: uidNext,
            fetchBodyPreview: fetchBodyPreview,
            database: database,
            auth: auth,
            coordinator: SyncCoordinator(database: database, sessionFactory: sessionFactory)
        )
    }

    /// Test-only overload (reachable only via `@testable import SyncEngine`,
    /// same pattern as `SyncCoordinator.waitForPendingPostSyncPrefetchForTesting()`):
    /// lets a test supply — and keep a reference to — the exact
    /// `SyncCoordinator` this run uses, so it can call that coordinator's
    /// own `waitForPendingPostSyncPrefetchForTesting()` afterward to prove
    /// `schedulesPostSyncPrefetch: false` below really suppressed the
    /// launch/foreground prefetch trigger, instead of racing a detached
    /// background `Task` with a sleep. The `public` overload above is the
    /// only one production code ever calls.
    static func run(
        accountId: String,
        uidNext: Int,
        fetchBodyPreview: Bool,
        database: AppDatabase,
        auth: MailAuth,
        coordinator: SyncCoordinator
    ) async -> Outcome {
        guard let account = try? await database.dbWriter.read({ db in
            try AccountRecord.fetchOne(db, key: accountId)
        }) else { return .empty }

        // `autoRetry: false` — same reasoning `PushNotificationActionExecutor
        // .fetchAndResolveOpenTarget`'s identical `.inboxOnly` priority sync
        // gives: this is a single opportunistic attempt from a
        // short-lived Extension process, not a long-lived session that
        // should sit through `AccountSyncer.SyncRetryPolicy`'s automatic
        // retry-then-suppress window.
        //
        // `schedulesPostSyncPrefetch: false` — see that parameter's own doc
        // comment on `SyncCoordinator.syncAccountIncrementally`: a detached
        // prefetch `Task` started from inside a Notification Service
        // Extension has no guarantee it survives past this call returning.
        guard (try? await coordinator.syncAccountIncrementally(
            account, auth: auth, scope: .inboxOnly, autoRetry: false, schedulesPostSyncPrefetch: false
        )) != nil else {
            return .empty
        }

        guard let mailbox = try? await MailboxRoleResolver.mailbox(role: .inbox, accountId: accountId, database: database),
              let mailboxId = mailbox.id
        else { return .empty }

        let uid = PushNotificationActionExecutor.inferredTargetUID(uidNext: uidNext)
        var message = try? await database.dbWriter.read { db in
            try PushNotificationActionExecutor.fetchMessage(mailboxId: mailboxId, uid: uid, db: db)
        }

        if fetchBodyPreview, let current = message, current.bodyState != .fetched {
            _ = try? await coordinator.fetchBody(for: current, mailboxPath: mailbox.path, account: account, auth: auth)
            // Re-read regardless of whether the fetch above reported
            // success — `BodyFetcher.fetchBody` persists as it goes, so a
            // partial/racing failure could still have left a usable body
            // behind; falling back to `current` (the pre-fetch row) if the
            // re-read itself fails is strictly no worse than skipping the
            // re-read entirely.
            message = (try? await database.dbWriter.read { db in
                try MessageRecord.fetchOne(db, key: current.id)
            }) ?? current
        }

        let unreadCount = try? await database.dbWriter.read { db in
            try MessageQuery.unreadCount(mailboxId: mailboxId, accountId: accountId, db: db)
        }

        return Outcome(message: message, unreadCount: unreadCount)
    }
}
