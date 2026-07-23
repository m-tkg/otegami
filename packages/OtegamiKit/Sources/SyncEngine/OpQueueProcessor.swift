import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore

/// Replays queued offline operations (`opQueue`) against the server, FIFO,
/// over one connection per `replay(account:auth:)` call. Owns no
/// persistent connection of its own — like `AccountSyncer`, it opens,
/// uses, and closes a fresh session per replay pass, since replay is
/// triggered opportunistically (successful reconnect, foreground,
/// incremental sync) rather than run continuously.
public actor OpQueueProcessor {
    /// After this many failed attempts, an op is left in the table (for a
    /// future UI banner to surface — `attempts >= maxAttempts` *is* "failed",
    /// no separate status column needed) but never retried again.
    public static let maxAttempts = 5

    /// Exponential backoff between retries of the same op: 30s, 60s, 120s,
    /// 240s, capped at 30 minutes so a long-offline device doesn't end up
    /// waiting hours between attempts once it's back online.
    static let backoffBase: TimeInterval = 30
    static let backoffCap: TimeInterval = 30 * 60

    public struct ReplayResult: Sendable, Equatable {
        public var succeeded = 0
        /// Discarded because the op's `uidValidity` (or referenced
        /// mailbox) no longer matches current state — see
        /// `SetFlagsOpPayload`'s doc comment.
        public var discardedStale = 0
        /// Failed this pass but still under `maxAttempts`; will be retried
        /// after its backoff window.
        public var retrying = 0
        /// Just crossed `maxAttempts` on this pass; won't be retried again
        /// automatically.
        public var permanentlyFailed = 0
    }

    private let database: AppDatabase
    private let sessionFactory: @Sendable (IMAPConfig) -> any IMAPSessionProtocol

    public init(
        database: AppDatabase,
        sessionFactory: @escaping @Sendable (IMAPConfig) -> any IMAPSessionProtocol
    ) {
        self.database = database
        self.sessionFactory = sessionFactory
    }

    /// Replays every due (`attempts < maxAttempts`, backoff window elapsed)
    /// op for `account`, oldest first. Returns early (without opening a
    /// connection at all) if there's nothing due. A connection-level
    /// failure (dead socket, bad credentials) aborts the remaining batch
    /// and rethrows — those ops' `attempts` are *not* incremented, since
    /// the connection is at fault, not any specific op; a per-op rejection
    /// (stale `uidValidity`, a `NO`/`BAD` IMAP response) doesn't stop the
    /// batch, so one bad op can't jam every op enqueued after it.
    @discardableResult
    public func replay(account: AccountRecord, auth: MailAuth) async throws -> ReplayResult {
        var result = ReplayResult()

        let now = Date()
        let allPending = try await database.dbWriter.read { db in
            try OpQueueRecord
                .filter(Column("accountId") == account.id)
                .filter(Column("attempts") < OpQueueProcessor.maxAttempts)
                .order(Column("id"))
                .fetchAll(db)
        }
        let dueOps = allPending.filter { op in
            guard let nextRetryAt = op.nextRetryAt else { return true }
            return nextRetryAt <= now
        }
        guard !dueOps.isEmpty else { return result }

        let session = sessionFactory(account.imapConfig)
        try await session.connect(auth: auth)
        defer {
            let session = session
            Task { await session.disconnect() }
        }

        for op in dueOps {
            do {
                switch try await apply(op: op, account: account, session: session) {
                case .applied:
                    try await delete(op: op)
                    result.succeeded += 1
                case .staleDiscarded:
                    try await delete(op: op)
                    result.discardedStale += 1
                }
            } catch let error as MailTransportError where Self.isConnectionLevel(error) {
                throw error
            } catch {
                let attempts = try await recordFailure(op: op, error: error)
                if attempts >= OpQueueProcessor.maxAttempts {
                    result.permanentlyFailed += 1
                } else {
                    result.retrying += 1
                }
            }
        }
        return result
    }

    private enum ApplyOutcome {
        case applied
        case staleDiscarded
    }

    private func apply(
        op: OpQueueRecord,
        account: AccountRecord,
        session: any IMAPSessionProtocol
    ) async throws -> ApplyOutcome {
        switch OpQueueKind(rawValue: op.kind) {
        case .setFlags:
            let payload = try JSONDecoder().decode(SetFlagsOpPayload.self, from: op.payload)
            guard let mailbox = try await mailbox(id: payload.mailboxId), mailbox.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            let change = FlagChange(
                uids: UIDSet(payload.uids),
                op: .replace,
                flags: MessageFlags(rawValue: payload.flagsRaw),
                uidValidity: UInt32(truncatingIfNeeded: payload.uidValidity)
            )
            try await session.store(mailboxPath: mailbox.path, change: change)
            return .applied

        case .move:
            let payload = try JSONDecoder().decode(MoveOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            guard let destination = try await mailbox(id: payload.destinationMailboxId) else {
                return .staleDiscarded
            }
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: destination.path)
            return .applied

        case .delete:
            let payload = try JSONDecoder().decode(DeleteOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            guard let trash = try await trashMailbox(accountId: account.id) else {
                // No Trash-role mailbox known for this account yet (e.g.
                // `listMailboxes` hasn't run since the account was added).
                // Leave the op pending — a future replay, after a sync has
                // discovered Trash, can still complete it — rather than
                // silently dropping a user-intended delete.
                throw MailTransportError.mailboxNotFound(path: "(no Trash-role mailbox known)")
            }
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: trash.path)
            return .applied

        case nil:
            // An unrecognized kind (e.g. a newer app version's op being
            // replayed after a downgrade) — nothing sensible to retry.
            return .staleDiscarded
        }
    }

    private func mailbox(id: Int64) async throws -> MailboxRecord? {
        try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: id) }
    }

    private func trashMailbox(accountId: String) async throws -> MailboxRecord? {
        try await database.dbWriter.read { db in
            try MailboxRecord
                .filter(Column("accountId") == accountId)
                .filter(Column("role") == MailboxRoleRecord.trash.rawValue)
                .fetchOne(db)
        }
    }

    private func delete(op: OpQueueRecord) async throws {
        _ = try await database.dbWriter.write { db in try op.delete(db) }
    }

    /// Records a failed attempt and returns the new `attempts` count.
    @discardableResult
    private func recordFailure(op: OpQueueRecord, error: Error) async throws -> Int {
        let attempts = op.attempts + 1
        let backoff = min(
            OpQueueProcessor.backoffCap,
            OpQueueProcessor.backoffBase * pow(2, Double(attempts - 1))
        )
        let failed = attempts >= OpQueueProcessor.maxAttempts
        try await database.dbWriter.write { db in
            var record = op
            record.attempts = attempts
            record.lastError = String(describing: error)
            record.nextRetryAt = failed ? nil : Date().addingTimeInterval(backoff)
            try record.update(db)
        }
        return attempts
    }

    /// Errors that mean "this connection/credential is broken", not "this
    /// particular op is invalid" — worth aborting the whole replay batch
    /// over rather than burning through every remaining op's attempts
    /// budget on the same underlying cause.
    private static func isConnectionLevel(_ error: MailTransportError) -> Bool {
        switch error {
        case .connectionFailed, .notConnected, .cancelled, .authenticationFailed:
            true
        case .serverError, .malformedResponse, .mailboxNotFound, .notImplemented:
            false
        }
    }
}
