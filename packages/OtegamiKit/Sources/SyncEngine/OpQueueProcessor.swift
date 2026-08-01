import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore
import os

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
        /// Task #152: destination mailbox ids that need a prioritized
        /// post-operation resync. Source mailboxes are deliberately absent:
        /// the UI has already applied the requested flag/removal locally,
        /// and an immediate source refresh can observe an eventually-
        /// consistent IMAP server's old state and visibly undo that update
        /// until the next manual refresh. A pure `.setFlags` operation and
        /// Gmail's source-only archive therefore leave this empty; moves and
        /// relocations include only their destination. `SyncCoordinator
        /// .replayOpQueue` feeds this into `scheduleTargetedResync`.
        /// Deliberately not populated for `.send`/`.saveDraft`/
        /// `.deleteDraft` — those aren't the "他の受信箱一覧への反映が遅い"
        /// complaint this task addresses, and `.send`'s own Task #124
        /// idempotency guard is unrelated to mailbox-list reflection.
        public var affectedMailboxIds: Set<Int64> = []
    }

    /// Task #124 shared logging category — `PendingSendCoordinator` and
    /// `ComposerView` use the same category so the whole enqueue → schedule
    /// → finalize → replay → SMTP → Sent-append lifecycle for one send can
    /// be read as a single interleaved stream in Console.app.
    static let logger = Logger(subsystem: "com.mtkg.otegami", category: "PendingSend")

    /// Task #152: same "OpReflect" category `OpQueue.opReflectLogger`
    /// (enqueue) and `SyncCoordinator` (targeted resync) use — see
    /// `OpQueue.opReflectLogger`'s doc comment for the full lifecycle this
    /// stitches together in Console.app/`log collect`.
    private static let opReflectLogger = Logger(subsystem: "com.mtkg.otegami", category: "OpReflect")

    /// Not `private`: `OpQueueProcessor+Send.swift`/`OpQueueProcessor
    /// +SaveDraft.swift` (extensions in other files) need direct access —
    /// Swift's `private` is file-scoped even for extensions of the same
    /// type, so a same-module/internal-by-default level is required for
    /// anything those extracted `.send`/`.saveDraft` case handlers touch.
    /// Still not `public`: nothing outside `SyncEngine` needs it.
    let database: AppDatabase
    private let sessionFactory: @Sendable (IMAPConfig) -> any IMAPSessionProtocol
    /// M5: opens the SMTP connection a `.send` op replays over. Separate
    /// from `sessionFactory` (IMAP) since a `.send` op needs both — the
    /// shared IMAP `session` this actor already holds open for the whole
    /// batch (for the best-effort Sent-mailbox `APPEND`) plus its own
    /// independent SMTP connection. Not `private` — see `database`'s doc
    /// comment above for why.
    let smtpSessionFactory: @Sendable (SMTPConfig) -> any SMTPSessionProtocol
    /// M5: renders a `ComposeDraft` (an `outboxMessage` row's fields) to
    /// RFC 822 bytes. Injected rather than hardcoded to
    /// `MailTransportMailCore.MailCoreMessageBuilder` for the same reason
    /// `sessionFactory`/`smtpSessionFactory` are injected: `SyncEngine`
    /// stays independent of any specific MIME-building backend (the app
    /// wires the real one; tests inject a trivial pure-Swift stand-in).
    /// Not `private` — see `database`'s doc comment above for why.
    let messageBuilder: @Sendable (ComposeDraft) -> BuiltMessage

    /// Task #124 (二重送信防止): `replay(account:auth:)` is called
    /// opportunistically from a dozen+ independent triggers — swipe
    /// actions, foreground sync, the IDLE loop's post-push callback,
    /// `PendingSendCoordinator`'s countdown finalize — any of which can
    /// overlap for the *same* account. Because this type is an `actor`,
    /// two overlapping calls can still interleave at any `await` inside
    /// `replay(account:auth:)` (actor reentrancy): without this guard,
    /// both could fetch the same still-pending `.send` op before either
    /// had deleted it, and both hand it to SMTP — the actual mechanism
    /// behind the reported "同じメールが2通送信された" bug. Mutating this set
    /// only ever happens at non-suspending points (right at
    /// `replay(account:auth:)`'s entry/exit), so no further race is
    /// possible on the set itself; it makes `replay(account:auth:)` this
    /// actor's single execution owner per account. A second call for an
    /// account already in flight requests one coalesced trailing pass via
    /// `trailingReplayAccountIds`: the active pass may already have fetched
    /// its queue snapshot, so treating the overlap as a no-op can otherwise
    /// strand an operation enqueued after that snapshot until the next IDLE
    /// wake, foreground transition, or manual refresh.
    private var inFlightAccountIds: Set<String> = []

    /// Accounts whose in-flight replay received at least one overlapping
    /// replay request. A set deliberately coalesces any number of triggers
    /// into one additional pass; if another trigger arrives during that
    /// trailing pass, the loop runs once more. This never retries failed or
    /// backed-off operations on its own — each pass still applies the usual
    /// `nextRetryAt` filtering.
    private var trailingReplayAccountIds: Set<String> = []

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
        self.smtpSessionFactory = smtpSessionFactory
        self.messageBuilder = messageBuilder
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
        guard inFlightAccountIds.insert(account.id).inserted else {
            trailingReplayAccountIds.insert(account.id)
            Self.logger.notice("replay(accountId: \(account.id, privacy: .private)) coalesced — trailing pass requested")
            return ReplayResult()
        }
        trailingReplayAccountIds.remove(account.id)
        defer {
            inFlightAccountIds.remove(account.id)
            trailingReplayAccountIds.remove(account.id)
        }

        var combined = ReplayResult()
        repeat {
            let pass = try await replayPass(account: account, auth: auth)
            combined.succeeded += pass.succeeded
            combined.discardedStale += pass.discardedStale
            combined.retrying += pass.retrying
            combined.permanentlyFailed += pass.permanentlyFailed
            combined.affectedMailboxIds.formUnion(pass.affectedMailboxIds)
        } while trailingReplayAccountIds.remove(account.id) != nil
        return combined
    }

    /// One queue snapshot → connection → apply/delete cycle. Ownership and
    /// overlap coalescing live in `replay(account:auth:)`; keeping one pass
    /// separate keeps each trailing pass on its own session and runs the
    /// existing session-scoped disconnect cleanup at every pass boundary.
    private func replayPass(account: AccountRecord, auth: MailAuth) async throws -> ReplayResult {
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
                switch try await apply(op: op, account: account, session: session, auth: auth) {
                case .applied(let affectedMailboxIds):
                    try await delete(op: op)
                    result.succeeded += 1
                    result.affectedMailboxIds.formUnion(affectedMailboxIds)
                case .staleDiscarded:
                    try await delete(op: op)
                    result.discardedStale += 1
                }
            } catch let error as MailTransportError where SyncFailureClass.classify(error) == .connectionLevel {
                throw error
            } catch where DatabaseSuspensionSupport.isSuspensionError(error) {
                // Task #192 (0xDEAD10CC 対策): the shared database is
                // suspended — `recordFailure(op:error:)` right below is
                // itself a `database.dbWriter.write` call, which would just
                // fail the exact same way (and, unlike every other call site
                // in this file, isn't wrapped in `try?`, so that failure
                // would propagate out of this `catch` block uncaught).
                // Every remaining op in `dueOps` would hit the same wall, so
                // treat this like a connection-level failure and abort the
                // whole batch — a normal replay picks the untouched queue
                // back up once the app foregrounds and the database resumes
                // (`OtegamiApp.handleScenePhaseChange`'s `.active` case
                // already calls `replayOpQueue` on every foreground return).
                // Deliberately not counted against `op.attempts`: this
                // wasn't the op's fault.
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
        Self.opReflectLogger.notice("replay completed accountId=\(account.id, privacy: .private) succeeded=\(result.succeeded) discardedStale=\(result.discardedStale) retrying=\(result.retrying) permanentlyFailed=\(result.permanentlyFailed) affectedMailboxCount=\(result.affectedMailboxIds.count)")
        return result
    }

    /// Not `private` — `applySend`/`applySaveDraft`
    /// (`OpQueueProcessor+Send.swift`/`OpQueueProcessor+SaveDraft.swift`)
    /// return this too; see `database`'s doc comment above for why.
    enum ApplyOutcome {
        /// Task #152: carries the destination mailbox ids safe to refresh
        /// immediately after this op (never its optimistic source) — see
        /// `ReplayResult.affectedMailboxIds`'s doc comment.
        case applied(affectedMailboxIds: Set<Int64>)
        case staleDiscarded
    }

    private func apply(
        op: OpQueueRecord,
        account: AccountRecord,
        session: any IMAPSessionProtocol,
        auth: MailAuth
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
            return .applied(affectedMailboxIds: [])

        case .move:
            let payload = try JSONDecoder().decode(MoveOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            guard let destination = try await mailbox(id: payload.destinationMailboxId) else {
                return .staleDiscarded
            }
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: destination.path)
            return .applied(affectedMailboxIds: [payload.destinationMailboxId])

        case .delete:
            let payload = try JSONDecoder().decode(DeleteOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            guard let trash = try await MailboxRoleResolver.resolveOrCreate(role: .trash, accountId: account.id, session: session, database: database) else {
                // No Trash-role mailbox known for this account, and either
                // there was nothing to self-heal towards (see
                // `MailboxRoleResolver.resolveOrCreate`'s doc comment) or the
                // self-heal attempt itself failed. Leave the op pending — a
                // future replay (after a sync discovers Trash, or after
                // whatever blocked `CREATE` is fixed server-side) can still
                // complete it — rather than silently dropping a
                // user-intended delete.
                throw SyncEngineError.noRoleMailbox(role: .trash)
            }
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: trash.path)
            return .applied(affectedMailboxIds: Set([trash.id].compactMap { $0 }))

        case .junk:
            let payload = try JSONDecoder().decode(JunkOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            guard let junk = try await MailboxRoleResolver.resolveOrCreate(role: .junk, accountId: account.id, session: session, database: database) else {
                // Same "leave the op pending rather than silently dropping
                // a user-intended action" shape as `.delete`'s identical
                // Trash-resolution failure above.
                throw SyncEngineError.noRoleMailbox(role: .junk)
            }
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: junk.path)
            return .applied(affectedMailboxIds: Set([junk.id].compactMap { $0 }))

        case .archive:
            let payload = try JSONDecoder().decode(ArchiveOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            if account.kind == .gmail {
                // Gmail has no `\Archive`-flagged folder (see
                // `OpQueueKind.archive`'s doc comment) — "archiving" is
                // un-labeling the source mailbox, not moving anywhere.
                // Gmail auto-retains every non-Spam/Trash message in "All
                // Mail" regardless of label state, so `\Deleted`+`EXPUNGE`
                // on the *source* mailbox only (never Trash, never a COPY)
                // removes it from that label without deleting it.
                let change = FlagChange(
                    uids: UIDSet(payload.uids), op: .add, flags: .deleted,
                    uidValidity: UInt32(truncatingIfNeeded: payload.uidValidity)
                )
                try await session.store(mailboxPath: source.path, change: change)
                try await session.expunge(mailboxPath: source.path)
                return .applied(affectedMailboxIds: [])
            }
            guard let archive = try await MailboxRoleResolver.resolveOrCreate(role: .archive, accountId: account.id, session: session, database: database) else {
                // Same "leave the op pending rather than silently dropping
                // a user-intended action" shape as `.delete`/`.junk`'s
                // identical resolution failure.
                throw SyncEngineError.noRoleMailbox(role: .archive)
            }
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: archive.path)
            return .applied(affectedMailboxIds: Set([archive.id].compactMap { $0 }))

        case .unarchive:
            let payload = try JSONDecoder().decode(UnarchiveOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            guard let inbox = try await MailboxRoleResolver.mailbox(role: .inbox, accountId: account.id, database: database) else {
                // No INBOX-role mailbox known yet for this account (should
                // only happen if the very first sync somehow hasn't
                // completed) — leave the op pending rather than silently
                // dropping a user-intended "アーカイブ解除", same shape as
                // every other `resolveOrCreate*`/lookup failure above.
                throw SyncEngineError.noRoleMailbox(role: .inbox)
            }
            if account.kind == .gmail {
                // Gmail: restoring the INBOX label is "add it to INBOX
                // too", never a move — see `OpQueueKind.unarchive`'s doc
                // comment. A plain `COPY`, not `MOVE`/`COPY`+delete+expunge:
                // the message must stay in All Mail exactly as it already
                // is.
                try await session.copy(mailboxPath: source.path, uids: UIDSet(payload.uids), to: inbox.path)
                return .applied(affectedMailboxIds: Set([inbox.id].compactMap { $0 }))
            }
            // Every other provider: the reverse of `.archive`'s own
            // `session.move(...)` call just above — a real move back to
            // INBOX from wherever it currently sits (its Archive-role
            // mailbox).
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: inbox.path)
            return .applied(affectedMailboxIds: Set([inbox.id].compactMap { $0 }))

        case .send:
            // Moved to `OpQueueProcessor+Send.swift` (`applySend`) —
            // Task #124's `claimSendStart`/`releaseSendClaim` idempotency
            // guard's timing/ordering is preserved character-for-character,
            // only relocated.
            return try await applySend(op: op, account: account, session: session, auth: auth)

        case .saveDraft:
            // Moved to `OpQueueProcessor+SaveDraft.swift` (`applySaveDraft`)
            // — logic unchanged, only relocated.
            return try await applySaveDraft(op: op, account: account, session: session)

        case .deleteDraft:
            let payload = try JSONDecoder().decode(DeleteDraftOpPayload.self, from: op.payload)
            guard let mailbox = try await mailboxIfCurrent(id: payload.mailboxId, expectedUidValidity: payload.uidValidity) else {
                return .staleDiscarded
            }
            try await deleteMessage(mailboxPath: mailbox.path, uid: payload.uid, uidValidity: payload.uidValidity, session: session)
            return .applied(affectedMailboxIds: [])

        case nil:
            // An unrecognized kind (e.g. a newer app version's op being
            // replayed after a downgrade) — nothing sensible to retry.
            return .staleDiscarded
        }
    }

    private func mailbox(id: Int64) async throws -> MailboxRecord? {
        try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: id) }
    }

    /// Role-mailbox lookups (INBOX/Trash/Junk/Archive/Sent/Drafts) and the
    /// self-healing `CREATE` for Trash/Junk/Archive/Drafts now live in
    /// `MailboxRoleResolver` — extracted since this actor used to carry six
    /// lookup functions and four resolve-or-create functions that were
    /// byte-for-byte identical except for the role. See that type's doc
    /// comments for the self-heal semantics this preserves exactly
    /// (including that `.inbox`/`.sent` never self-heal).

    /// Kept as a thin forwarding alias — `AccountSyncer.drafts(among:)`
    /// references this exact name to recognize the same self-heal target
    /// `MailboxRoleResolver.resolveOrCreate(role: .drafts, ...)` now
    /// creates, and that call site is out of scope for this refactor.
    static let draftsMailboxNameToCreate = MailboxRoleResolver.mailboxNameToCreate(for: .drafts) ?? "Drafts"

    /// Returns `mailboxId`'s current `MailboxRecord` only if it still
    /// exists *and* its `uidValidity` still matches `expectedUidValidity`
    /// — `nil` otherwise (mailbox gone, or recreated with a different
    /// uidValidity since `expectedUidValidity` was captured). The same
    /// staleness contract `SetFlagsOpPayload`/`MoveOpPayload`/`DeleteOpPayload`
    /// already encode inline at each of their call sites; factored out here
    /// since `.saveDraft`'s old-copy cleanup, `.deleteDraft`, and `.send`'s
    /// linked-draft cleanup all need the identical check.
    /// Not `private` — `applySend`/`applySaveDraft` call this too; see
    /// `database`'s doc comment above for why.
    func mailboxIfCurrent(id: Int64, expectedUidValidity: Int64) async throws -> MailboxRecord? {
        guard let candidate = try await mailbox(id: id), candidate.uidValidity == expectedUidValidity else { return nil }
        return candidate
    }

    /// Marks `uid` `\Deleted` and expunges it — the replace/delete
    /// primitive `.saveDraft`'s old-copy cleanup, `.deleteDraft`, and
    /// `.send`'s linked-draft cleanup all share. No staleness check here;
    /// callers are expected to have already done theirs via
    /// ``mailboxIfCurrent(id:expectedUidValidity:)``. `uidValidity` is
    /// carried through purely as `FlagChange`'s required field — the real
    /// `MailCoreIMAPSession.store` implementation doesn't actually consult
    /// it (a mailbox is already addressed by path, already `SELECT`-free
    /// per-command over IMAP), only `FakeIMAPSession`'s test recorder does.
    /// Not `private` — `applySend`/`applySaveDraft` call this too; see
    /// `database`'s doc comment above for why.
    func deleteMessage(mailboxPath: String, uid: UInt32, uidValidity: Int64, session: any IMAPSessionProtocol) async throws {
        let change = FlagChange(
            uids: UIDSet([uid]), op: .add, flags: .deleted,
            uidValidity: UInt32(truncatingIfNeeded: uidValidity)
        )
        try await session.store(mailboxPath: mailboxPath, change: change)
        try await session.expunge(mailboxPath: mailboxPath)
    }

    /// Everything `.saveDraft` (`draftMessage(id:)`/`draftAttachments
    /// (draftMessageId:)`) and `.send` (`outboxMessage(id:)`/
    /// `claimSendStart`/`releaseSendClaim`/`outboxAttachments
    /// (outboxMessageId:)`/`deleteOutboxMessage(id:)`, including the
    /// Task #124 二重送信防止 claim/release pair) exclusively needed has
    /// moved with those case handlers into `OpQueueProcessor+SaveDraft.swift`/
    /// `OpQueueProcessor+Send.swift` — nothing else in this file called them.

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
            // `SyncEngineError.userFacingMessage` rather than `String
            // (describing:)` directly — preserves `FailedOperationsView`'s
            // existing caption text for `.duplicateSendBlocked` (the one
            // case with real UI copy, not just a technical description;
            // see `SyncEngineError.userFacingMessage`'s doc comment).
            // `String(describing:)` unchanged for every other error type
            // (`MailTransportError`, GRDB's `DatabaseError`, ...).
            record.lastError = (error as? SyncEngineError)?.userFacingMessage ?? String(describing: error)
            record.nextRetryAt = failed ? nil : Date().addingTimeInterval(backoff)
            try record.update(db)
        }
        return attempts
    }

    // `isConnectionLevel(_:)` moved to `SyncFailureClass.classify(_:)` — see
    // that type's doc comment for why it's a standalone type rather than
    // reusing `AccountSyncer`'s own private `FailureClass`.
}

/// The default `smtpSessionFactory` for callers that never queue a `.send`
/// op (every M1–M4 test/call site) — throws `.notImplemented` rather than
/// requiring every existing `OpQueueProcessor(database:sessionFactory:)`
/// call to start naming an SMTP factory it doesn't use.
public actor NotImplementedSMTPSession: SMTPSessionProtocol {
    public init(config: SMTPConfig) {}
    public func connect(auth: MailAuth) async throws {
        throw MailTransportError.notImplemented("No smtpSessionFactory configured for this OpQueueProcessor")
    }
    public func disconnect() async {}
    public func sendMessage(messageData: Data, from: EmailAddress, recipients: [EmailAddress]) async throws {
        throw MailTransportError.notImplemented("No smtpSessionFactory configured for this OpQueueProcessor")
    }
}
