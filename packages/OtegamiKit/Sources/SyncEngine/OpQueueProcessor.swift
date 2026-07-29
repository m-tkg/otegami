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
        /// Task #152: every mailbox id a `.applied` `.setFlags`/`.move`/
        /// `.delete`/`.junk`/`.archive`/`.unarchive` op touched this pass —
        /// its source mailbox *and*, when the op resolved one (a move's
        /// destination, or a self-healed Trash/Junk/Archive/INBOX), the
        /// destination too. `SyncCoordinator.replayOpQueue` feeds this
        /// straight into `scheduleTargetedResync` so the mailbox(es) an
        /// offline action just touched get a prioritized resync instead of
        /// waiting for their turn in the periodic full-account sweep
        /// (`OtegamiApp.syncAllAccountsOnce`, unchanged by this task).
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

    private let database: AppDatabase
    private let sessionFactory: @Sendable (IMAPConfig) -> any IMAPSessionProtocol
    /// M5: opens the SMTP connection a `.send` op replays over. Separate
    /// from `sessionFactory` (IMAP) since a `.send` op needs both — the
    /// shared IMAP `session` this actor already holds open for the whole
    /// batch (for the best-effort Sent-mailbox `APPEND`) plus its own
    /// independent SMTP connection.
    private let smtpSessionFactory: @Sendable (SMTPConfig) -> any SMTPSessionProtocol
    /// M5: renders a `ComposeDraft` (an `outboxMessage` row's fields) to
    /// RFC 822 bytes. Injected rather than hardcoded to
    /// `MailTransportMailCore.MailCoreMessageBuilder` for the same reason
    /// `sessionFactory`/`smtpSessionFactory` are injected: `SyncEngine`
    /// stays independent of any specific MIME-building backend (the app
    /// wires the real one; tests inject a trivial pure-Swift stand-in).
    private let messageBuilder: @Sendable (ComposeDraft) -> BuiltMessage

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
    /// actor's single execution owner per account — a second call for an
    /// account already in flight is a safe no-op, since the in-flight call
    /// will pick up the exact same due ops this second call would have.
    private var inFlightAccountIds: Set<String> = []

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
            // Task #124: another `replay(account:auth:)` call for this same
            // account is already running this actor's fetch-due-ops →
            // apply → delete cycle — see `inFlightAccountIds`'s doc comment
            // for why racing a second pass through that cycle is exactly
            // how a `.send` op gets handed to SMTP twice. That in-flight
            // call already covers whatever this call would have done, so
            // this one is a safe, cheap no-op.
            Self.logger.notice("replay(accountId: \(account.id, privacy: .private)) skipped — already in flight (Task #124 per-account serialization)")
            return ReplayResult()
        }
        defer { inFlightAccountIds.remove(account.id) }

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
        Self.opReflectLogger.notice("replay completed accountId=\(account.id, privacy: .private) succeeded=\(result.succeeded) discardedStale=\(result.discardedStale) retrying=\(result.retrying) permanentlyFailed=\(result.permanentlyFailed) affectedMailboxCount=\(result.affectedMailboxIds.count)")
        return result
    }

    private enum ApplyOutcome {
        /// Task #152: carries every mailbox id this op actually touched
        /// (source, plus a resolved destination when there is one) — see
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
            return .applied(affectedMailboxIds: [payload.mailboxId])

        case .move:
            let payload = try JSONDecoder().decode(MoveOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            guard let destination = try await mailbox(id: payload.destinationMailboxId) else {
                return .staleDiscarded
            }
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: destination.path)
            return .applied(affectedMailboxIds: [payload.sourceMailboxId, payload.destinationMailboxId])

        case .delete:
            let payload = try JSONDecoder().decode(DeleteOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            guard let trash = try await resolveOrCreateTrashMailbox(accountId: account.id, session: session) else {
                // No Trash-role mailbox known for this account, and either
                // there was nothing to self-heal towards (see
                // `resolveOrCreateTrashMailbox`'s doc comment) or the
                // self-heal attempt itself failed. Leave the op pending — a
                // future replay (after a sync discovers Trash, or after
                // whatever blocked `CREATE` is fixed server-side) can still
                // complete it — rather than silently dropping a
                // user-intended delete.
                throw MailTransportError.mailboxNotFound(path: "(no Trash-role mailbox known)")
            }
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: trash.path)
            return .applied(affectedMailboxIds: Set([payload.sourceMailboxId, trash.id].compactMap { $0 }))

        case .junk:
            let payload = try JSONDecoder().decode(JunkOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            guard let junk = try await resolveOrCreateJunkMailbox(accountId: account.id, session: session) else {
                // Same "leave the op pending rather than silently dropping
                // a user-intended action" shape as `.delete`'s identical
                // Trash-resolution failure above.
                throw MailTransportError.mailboxNotFound(path: "(no Junk-role mailbox known)")
            }
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: junk.path)
            return .applied(affectedMailboxIds: Set([payload.sourceMailboxId, junk.id].compactMap { $0 }))

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
                return .applied(affectedMailboxIds: [payload.sourceMailboxId])
            }
            guard let archive = try await resolveOrCreateArchiveMailbox(accountId: account.id, session: session) else {
                // Same "leave the op pending rather than silently dropping
                // a user-intended action" shape as `.delete`/`.junk`'s
                // identical resolution failure.
                throw MailTransportError.mailboxNotFound(path: "(no Archive-role mailbox known)")
            }
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: archive.path)
            return .applied(affectedMailboxIds: Set([payload.sourceMailboxId, archive.id].compactMap { $0 }))

        case .unarchive:
            let payload = try JSONDecoder().decode(UnarchiveOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            guard let inbox = try await inboxMailbox(accountId: account.id) else {
                // No INBOX-role mailbox known yet for this account (should
                // only happen if the very first sync somehow hasn't
                // completed) — leave the op pending rather than silently
                // dropping a user-intended "アーカイブ解除", same shape as
                // every other `resolveOrCreate*`/lookup failure above.
                throw MailTransportError.mailboxNotFound(path: "(no INBOX-role mailbox known)")
            }
            if account.kind == .gmail {
                // Gmail: restoring the INBOX label is "add it to INBOX
                // too", never a move — see `OpQueueKind.unarchive`'s doc
                // comment. A plain `COPY`, not `MOVE`/`COPY`+delete+expunge:
                // the message must stay in All Mail exactly as it already
                // is.
                try await session.copy(mailboxPath: source.path, uids: UIDSet(payload.uids), to: inbox.path)
                return .applied(affectedMailboxIds: Set([payload.sourceMailboxId, inbox.id].compactMap { $0 }))
            }
            // Every other provider: the reverse of `.archive`'s own
            // `session.move(...)` call just above — a real move back to
            // INBOX from wherever it currently sits (its Archive-role
            // mailbox).
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: inbox.path)
            return .applied(affectedMailboxIds: Set([payload.sourceMailboxId, inbox.id].compactMap { $0 }))

        case .send:
            let payload = try JSONDecoder().decode(SendOpPayload.self, from: op.payload)
            guard let outbox = try await outboxMessage(id: payload.outboxMessageId) else {
                // Already sent (a previous replay pass succeeded and
                // deleted the row) or never existed — nothing to send.
                return .staleDiscarded
            }
            guard let smtpConfig = account.smtpConfig else {
                // No SMTP configured for this account — nothing sensible to
                // retry towards until the user fixes that; surfaced as a
                // per-op failure (not a connection-level batch-abort) so it
                // keeps counting toward maxAttempts/backoff like any other
                // misconfigured op, while unrelated setFlags/move/delete
                // ops in the same batch still proceed.
                throw MailTransportError.serverError(underlyingDescription: "Account \(account.id) has no SMTP configuration")
            }

            // M8: rebuilt from the `outboxAttachment` rows' bytes on disk at
            // replay time, same "rebuild from the row, not a pre-built
            // snapshot" pattern the rest of this draft already follows —
            // see `OutboxAttachmentRecord`'s doc comment. A row whose file
            // has gone missing (should not normally happen; best-effort
            // defensive skip rather than failing the whole send) is simply
            // left out rather than aborting the send over one bad
            // attachment.
            let attachmentRecords = try await outboxAttachments(outboxMessageId: payload.outboxMessageId)
            let composeAttachments: [ComposeAttachment] = attachmentRecords.compactMap { record in
                guard let data = FileManager.default.contents(atPath: record.localPath) else { return nil }
                return ComposeAttachment(filename: record.filename, mimeType: record.mimeType, data: data)
            }

            let draft = ComposeDraft(
                from: EmailAddress(name: account.displayName, address: account.email),
                to: outbox.toAddresses,
                cc: outbox.ccAddresses,
                bcc: outbox.bccAddresses,
                subject: outbox.subject,
                plainTextBody: outbox.plainTextBody,
                htmlBody: outbox.htmlBody,
                inReplyTo: outbox.inReplyToMessageId,
                references: outbox.references,
                attachments: composeAttachments
            )
            let built = messageBuilder(draft)
            let recipients = outbox.toAddresses + outbox.ccAddresses + outbox.bccAddresses

            // Task #124 (二重送信防止): claim exclusive right to actually
            // transmit this outboxMessage *immediately before* touching
            // SMTP at all — see `claimSendStart(outboxMessageId:)`'s doc
            // comment. This is the second, durable line of defense behind
            // `inFlightAccountIds` (which only protects against overlap
            // *within one still-running process*): if the process was
            // killed mid-send on a previous run, `sendStartedAt` survived
            // that crash and this claim fails here too, refusing to resend
            // a message whose previous delivery outcome is unknown rather
            // than risking a duplicate.
            guard try await claimSendStart(outboxMessageId: payload.outboxMessageId) else {
                Self.logger.error("send blocked: outboxMessageId \(payload.outboxMessageId) already claimed by another attempt — refusing to resend (Task #124 safety net)")
                throw MailTransportError.serverError(underlyingDescription: "送信を開始済みのため再送信をスキップしました(二重送信防止)。「同期エラー」から内容を確認し、必要なら手動で再送してください。")
            }

            // SMTP failures here must never be reclassified as
            // connection-level (which would abort the *whole* replay batch,
            // including unrelated setFlags/move/delete ops that still have
            // a perfectly good IMAP `session`) — wrapping as `.serverError`
            // routes them through `replay()`'s ordinary per-op
            // recordFailure/backoff path instead, exactly the "SMTP失敗→
            // リトライ残る" behavior the plan calls for.
            do {
                let smtpSession = smtpSessionFactory(smtpConfig)
                Self.logger.info("SMTP send starting for outboxMessageId \(payload.outboxMessageId)")
                try await smtpSession.connect(auth: Self.smtpAuth(imapAuth: auth, account: account))
                defer {
                    let smtpSession = smtpSession
                    Task { await smtpSession.disconnect() }
                }
                try await smtpSession.sendMessage(messageData: built.data, from: draft.from, recipients: recipients)
            } catch {
                // The attempt is definitively known to have failed locally
                // (this call returned control to us with an error, rather
                // than the process dying mid-await) — release the claim so
                // a later replay pass can retry normally, same as before
                // this task's idempotency guard existed.
                Self.logger.error("SMTP send failed for outboxMessageId \(payload.outboxMessageId): \(String(describing: error))")
                await releaseSendClaim(outboxMessageId: payload.outboxMessageId)
                throw MailTransportError.serverError(underlyingDescription: "SMTP send failed: \(error)")
            }
            Self.logger.info("SMTP send succeeded for outboxMessageId \(payload.outboxMessageId)")

            // The message has now genuinely been sent — from here on,
            // *nothing* is allowed to cause this op to be retried (a retry
            // would resend it). Saving a copy to Sent is therefore
            // best-effort only (`try?`): Gmail-kind accounts skip it
            // entirely (Gmail's own SMTP submission already saves a Sent
            // copy; a client-side APPEND would double it), and any other
            // failure here (no Sent mailbox known yet, IMAP hiccup) just
            // means the local Sent mailbox doesn't show a copy until the
            // next differential sync notices it — not a reason to fail
            // this op.
            if account.kind != .gmail, let sent = try await sentMailbox(accountId: account.id) {
                do {
                    _ = try await session.append(mailboxPath: sent.path, messageData: built.data, flags: .seen)
                    Self.logger.info("Sent APPEND succeeded for outboxMessageId \(payload.outboxMessageId)")
                } catch {
                    Self.logger.error("Sent APPEND failed (best-effort, not retried) for outboxMessageId \(payload.outboxMessageId): \(String(describing: error))")
                }
            }

            // Drafts IMAP sync: if this send was composed by resuming a
            // draft with a known server-side Drafts copy, that copy is now
            // redundant — best-effort delete it (`docs/roadmap.md`:
            // "送信完了時に...下書きがそのまま残るのは典型的なバグ"). Best-effort for
            // the same reason the Sent APPEND above is: the message has
            // already been irreversibly sent, so nothing past that point
            // may cause this op to retry.
            if let draftMailboxId = outbox.draftServerMailboxId,
               let draftUid = outbox.draftServerUid,
               let draftUidValidity = outbox.draftServerUidValidity,
               let draftMailbox = try? await mailboxIfCurrent(id: draftMailboxId, expectedUidValidity: draftUidValidity) {
                try? await deleteMessage(
                    mailboxPath: draftMailbox.path,
                    uid: UInt32(truncatingIfNeeded: draftUid),
                    uidValidity: draftUidValidity,
                    session: session
                )
            }

            try await deleteOutboxMessage(id: payload.outboxMessageId)
            Self.logger.info("outbox row deleted (send complete) for outboxMessageId \(payload.outboxMessageId)")
            return .applied(affectedMailboxIds: [])

        case .saveDraft:
            let payload = try JSONDecoder().decode(SaveDraftOpPayload.self, from: op.payload)
            guard let draft = try await draftMessage(id: payload.draftMessageId) else {
                // Already replaced by a previous replay pass and since
                // resumed (e.g. the user reopened this draft in Composer
                // before this op got its turn — `ComposerView`'s "load
                // transfers ownership" deletes the row immediately) or
                // deleted, or never existed. Nothing left to build.
                return .staleDiscarded
            }
            guard let drafts = try await resolveOrCreateDraftsMailbox(accountId: account.id, session: session) else {
                // See the `.delete` case's identical shape: leave the op
                // pending rather than silently dropping a save.
                throw MailTransportError.mailboxNotFound(path: "(no Drafts-role mailbox known)")
            }

            // Same "rebuild attachments from disk at replay time" pattern
            // as `.send`'s outboxAttachment handling above — a row whose
            // file has gone missing is best-effort skipped, not a reason
            // to fail the whole save.
            let attachmentRecords = try await draftAttachments(draftMessageId: payload.draftMessageId)
            let composeAttachments: [ComposeAttachment] = attachmentRecords.compactMap { record in
                guard let data = FileManager.default.contents(atPath: record.localPath) else { return nil }
                return ComposeAttachment(filename: record.filename, mimeType: record.mimeType, data: data)
            }

            let composeDraft = ComposeDraft(
                from: EmailAddress(name: account.displayName, address: account.email),
                to: draft.toAddresses,
                cc: draft.ccAddresses,
                subject: draft.subject,
                plainTextBody: draft.plainTextBody,
                htmlBody: draft.htmlBody,
                inReplyTo: draft.inReplyToMessageId,
                references: draft.references,
                attachments: composeAttachments
            )
            let built = messageBuilder(composeDraft)

            // IMAP has no "update a message" — a draft edit is always
            // APPEND-the-new-copy-first, delete-the-old-copy-second (never
            // the other order): if the delete happened first and the
            // APPEND then failed (offline, server rejects it), the draft
            // would vanish from the server entirely — an unacceptable data
            // loss this app's design explicitly rules out (plan: "曖昧な
            // 場合は消さずに両方残す"). A duplicate briefly existing (or,
            // if the best-effort delete below itself fails, permanently)
            // is the strictly safer failure mode.
            let newUid = try await session.append(mailboxPath: drafts.path, messageData: built.data, flags: .draft)

            // Best-effort replace of whatever server copy this row already
            // knew about (a previous save, or the server-origin draft this
            // save started from — see `DraftMessageRecord`'s doc comment).
            // Skipped outright (not even attempted) when `uidValidity`
            // no longer matches — the UID it names may not even refer to
            // this draft anymore. A failure here just leaves a stray
            // duplicate on the server rather than losing anything; nothing
            // past this point retries it, since this row's `serverUid` is
            // about to be overwritten to point at the *new* copy below —
            // documented as a known limitation (`docs/verify.md`).
            if let oldMailboxId = draft.serverMailboxId,
               let oldUid = draft.serverUid,
               let oldUidValidity = draft.serverUidValidity,
               let oldMailbox = try? await mailboxIfCurrent(id: oldMailboxId, expectedUidValidity: oldUidValidity) {
                try? await deleteMessage(
                    mailboxPath: oldMailbox.path,
                    uid: UInt32(truncatingIfNeeded: oldUid),
                    uidValidity: oldUidValidity,
                    session: session
                )
            }

            try await database.dbWriter.write { db in
                var updated = draft
                updated.serverMailboxId = drafts.id
                // `nil` when the server doesn't support UIDPLUS (no UID
                // returned from APPEND) — the row still records
                // `serverMailboxId`/`serverUidValidity`, but without a UID
                // there's nothing a later replace/delete/send-cleanup can
                // target; a documented known limitation on such servers
                // (`docs/verify.md`), not a crash or data-loss risk.
                updated.serverUid = newUid.map { Int64($0) }
                updated.serverUidValidity = drafts.uidValidity
                updated.updatedAt = Date()
                try updated.update(db)
            }
            return .applied(affectedMailboxIds: [])

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

    /// Task #87 (1): `.unarchive`'s destination — unlike Trash/Junk/Archive,
    /// INBOX never needs a self-healing `CREATE`: every IMAP account has one
    /// by construction, and this app's own initial sync always discovers
    /// and upserts it (`AccountSyncer`) before any op could possibly be
    /// queued against it. `nil` here would only mean "this account hasn't
    /// completed even its first sync yet" — the caller leaves the op
    /// pending in that case, same as every other `resolveOrCreate*`
    /// failure.
    private func inboxMailbox(accountId: String) async throws -> MailboxRecord? {
        try await database.dbWriter.read { db in
            try MailboxRecord
                .filter(Column("accountId") == accountId)
                .filter(Column("role") == MailboxRoleRecord.inbox.rawValue)
                .fetchOne(db)
        }
    }

    private func trashMailbox(accountId: String) async throws -> MailboxRecord? {
        try await database.dbWriter.read { db in
            try MailboxRecord
                .filter(Column("accountId") == accountId)
                .filter(Column("role") == MailboxRoleRecord.trash.rawValue)
                .fetchOne(db)
        }
    }

    /// The mailbox name `resolveOrCreateTrashMailbox` asks the server to
    /// `CREATE` when no Trash-role mailbox is known (`docs/roadmap.md`:
    /// "Trash メールボックスが存在しないサーバでの Trash 自動作成"). Plain
    /// `"Trash"`, no parent — the same flat name a server without
    /// `SPECIAL-USE`/an existing `Trash` mailbox would already be missing;
    /// there's no reliable way to infer a provider-specific hierarchy
    /// (e.g. Gmail's `[Gmail]/Trash`) from IMAP alone for an account this
    /// code path has, by construction, never seen a Trash-role mailbox
    /// from.
    static let trashMailboxNameToCreate = "Trash"

    /// Resolves this account's Trash-role mailbox, self-healing by
    /// `CREATE`+`SUBSCRIBE`-ing one named ``trashMailboxNameToCreate`` when
    /// none is known yet. Returns `nil` when there's still no usable Trash
    /// mailbox after that attempt (the `CREATE` itself failed — permission
    /// denied, a naming conflict, offline, ...) — the caller's existing
    /// `mailboxNotFound` retry path is unchanged in that case, so this is
    /// purely additive: an account whose server already advertises Trash
    /// never reaches the `CREATE` attempt at all (`trashMailbox` above
    /// already found it).
    private func resolveOrCreateTrashMailbox(accountId: String, session: any IMAPSessionProtocol) async throws -> MailboxRecord? {
        if let existing = try await trashMailbox(accountId: accountId) {
            return existing
        }

        do {
            try await session.createMailbox(path: Self.trashMailboxNameToCreate)
        } catch {
            return nil
        }

        // Re-list rather than assuming the just-created path/role: some
        // servers report a different `SPECIAL-USE` attribute or display
        // name for a freshly created mailbox than the literal string this
        // code asked to `CREATE`, and `MailboxInfo.role` (not the raw path)
        // is the source of truth `trashMailbox(accountId:)`'s query above
        // also relies on.
        let mailboxInfos = try await session.listMailboxes()
        guard let created = mailboxInfos.first(where: { info in
            info.role == .trash || info.path.caseInsensitiveCompare(Self.trashMailboxNameToCreate) == .orderedSame
        }) else {
            return nil
        }

        return try await upsertCreatedMailbox(accountId: accountId, info: created)
    }

    /// Inserts (or, on a name collision with something already upserted by
    /// a concurrent sync pass, updates) the mailbox `resolveOrCreateTrashMailbox`
    /// just created — the on-conflict column list mirrors `AccountSyncer
    /// .upsertMailboxes`'s (sync-state columns like `uidValidity` must
    /// survive if a race means a row already exists here), duplicated
    /// rather than shared since it's a two-line list and pulling in
    /// `AccountSyncer` from `OpQueueProcessor` for it isn't worth the
    /// coupling.
    private func upsertCreatedMailbox(accountId: String, info: MailboxInfo) async throws -> MailboxRecord {
        try await database.dbWriter.write { db in
            var record = MailboxRecord(
                accountId: accountId,
                path: info.path,
                displayPath: info.displayPath,
                delimiter: info.delimiter,
                role: MailboxRoleRecord(info.role),
                roleIsAuthoritative: info.roleIsAuthoritative,
                attributesRaw: info.attributes.rawValue
            )
            return try record.upsertAndFetch(db, onConflict: ["accountId", "path"]) { _ in
                [
                    Column("uidValidity").noOverwrite,
                    Column("uidNext").noOverwrite,
                    Column("highestModSeq").noOverwrite,
                    Column("messageCount").noOverwrite,
                    Column("lastSyncedAt").noOverwrite,
                ]
            }
        }
    }

    private func junkMailbox(accountId: String) async throws -> MailboxRecord? {
        try await database.dbWriter.read { db in
            try MailboxRecord
                .filter(Column("accountId") == accountId)
                .filter(Column("role") == MailboxRoleRecord.junk.rawValue)
                .fetchOne(db)
        }
    }

    /// The mailbox name `resolveOrCreateJunkMailbox` asks the server to
    /// `CREATE` when no Junk-role mailbox is known — same rationale as
    /// ``trashMailboxNameToCreate`` (D8's "迷惑メールにする = Junk role のメール
    /// ボックスへ移動（無い場合は Trash 自動作成と同じパターンで対処）" requirement).
    static let junkMailboxNameToCreate = "Junk"

    /// Resolves this account's Junk-role mailbox, self-healing by
    /// `CREATE`-ing one named ``junkMailboxNameToCreate`` when none is known
    /// yet — mirrors `resolveOrCreateTrashMailbox` exactly, reusing
    /// `upsertCreatedMailbox(accountId:info:)` the same way.
    private func resolveOrCreateJunkMailbox(accountId: String, session: any IMAPSessionProtocol) async throws -> MailboxRecord? {
        if let existing = try await junkMailbox(accountId: accountId) {
            return existing
        }

        do {
            try await session.createMailbox(path: Self.junkMailboxNameToCreate)
        } catch {
            return nil
        }

        let mailboxInfos = try await session.listMailboxes()
        guard let created = mailboxInfos.first(where: { info in
            info.role == .junk || info.path.caseInsensitiveCompare(Self.junkMailboxNameToCreate) == .orderedSame
        }) else {
            return nil
        }

        return try await upsertCreatedMailbox(accountId: accountId, info: created)
    }

    private func archiveMailbox(accountId: String) async throws -> MailboxRecord? {
        try await database.dbWriter.read { db in
            try MailboxRecord
                .filter(Column("accountId") == accountId)
                .filter(Column("role") == MailboxRoleRecord.archive.rawValue)
                .fetchOne(db)
        }
    }

    /// The mailbox name `resolveOrCreateArchiveMailbox` asks the server to
    /// `CREATE` when no Archive-role mailbox is known — same rationale as
    /// ``trashMailboxNameToCreate``/``junkMailboxNameToCreate``. Only
    /// reached for non-Gmail accounts (`OpQueueKind.archive`'s doc comment:
    /// Gmail never takes this path at all, so there's no risk of this
    /// clashing with Gmail's own folder naming).
    static let archiveMailboxNameToCreate = "Archive"

    /// Resolves this account's Archive-role mailbox, self-healing by
    /// `CREATE`-ing one named ``archiveMailboxNameToCreate`` when none is
    /// known yet — mirrors `resolveOrCreateTrashMailbox`/
    /// `resolveOrCreateJunkMailbox` exactly, reusing
    /// `upsertCreatedMailbox(accountId:info:)` the same way.
    private func resolveOrCreateArchiveMailbox(accountId: String, session: any IMAPSessionProtocol) async throws -> MailboxRecord? {
        if let existing = try await archiveMailbox(accountId: accountId) {
            return existing
        }

        do {
            try await session.createMailbox(path: Self.archiveMailboxNameToCreate)
        } catch {
            return nil
        }

        let mailboxInfos = try await session.listMailboxes()
        guard let created = mailboxInfos.first(where: { info in
            info.role == .archive || info.path.caseInsensitiveCompare(Self.archiveMailboxNameToCreate) == .orderedSame
        }) else {
            return nil
        }

        return try await upsertCreatedMailbox(accountId: accountId, info: created)
    }

    /// Builds SMTP-specific credentials from `account.smtpUsername` (the
    /// account setup form's own SMTP username field) rather than reusing
    /// `imapAuth` verbatim — the IMAP and SMTP username can legitimately
    /// differ, and reusing the IMAP username unconditionally would also
    /// mean an account with an intentionally-blank SMTP username (some
    /// relays require none — the dev mailstack's Mailpit among them; a
    /// blank username there makes `MailCoreSMTPSession.connect` skip
    /// `AUTH` entirely) would still attempt to authenticate. The password
    /// is the one already resolved for `imapAuth`, since the schema only
    /// stores a single Keychain-backed password per account (`AccountRecord`'s
    /// doc comment) — real providers needing genuinely distinct IMAP/SMTP
    /// passwords are out of scope until an account form actually collects
    /// a second one.
    private static func smtpAuth(imapAuth: MailAuth, account: AccountRecord) -> MailAuth {
        switch imapAuth {
        case .password(_, let password):
            .password(username: account.smtpUsername ?? "", password: password)
        case .xoauth2(let username, let accessToken):
            .xoauth2(username: account.smtpUsername ?? username, accessToken: accessToken)
        }
    }

    private func sentMailbox(accountId: String) async throws -> MailboxRecord? {
        try await database.dbWriter.read { db in
            try MailboxRecord
                .filter(Column("accountId") == accountId)
                .filter(Column("role") == MailboxRoleRecord.sent.rawValue)
                .fetchOne(db)
        }
    }

    private func draftsMailbox(accountId: String) async throws -> MailboxRecord? {
        try await database.dbWriter.read { db in
            try MailboxRecord
                .filter(Column("accountId") == accountId)
                .filter(Column("role") == MailboxRoleRecord.drafts.rawValue)
                .fetchOne(db)
        }
    }

    /// The mailbox name `resolveOrCreateDraftsMailbox` asks the server to
    /// `CREATE` when no Drafts-role mailbox is known — same rationale as
    /// ``trashMailboxNameToCreate``.
    static let draftsMailboxNameToCreate = "Drafts"

    /// Resolves this account's Drafts-role mailbox, self-healing by
    /// `CREATE`+`SUBSCRIBE`-ing one named ``draftsMailboxNameToCreate`` when
    /// none is known yet — the same self-heal `resolveOrCreateTrashMailbox`
    /// already does for Trash, reused here via ``upsertCreatedMailbox(accountId:info:)``.
    /// Returns `nil` when there's still no usable Drafts mailbox after that
    /// attempt.
    private func resolveOrCreateDraftsMailbox(accountId: String, session: any IMAPSessionProtocol) async throws -> MailboxRecord? {
        if let existing = try await draftsMailbox(accountId: accountId) {
            return existing
        }

        do {
            try await session.createMailbox(path: Self.draftsMailboxNameToCreate)
        } catch {
            return nil
        }

        let mailboxInfos = try await session.listMailboxes()
        guard let created = mailboxInfos.first(where: { info in
            info.role == .drafts || info.path.caseInsensitiveCompare(Self.draftsMailboxNameToCreate) == .orderedSame
        }) else {
            return nil
        }

        return try await upsertCreatedMailbox(accountId: accountId, info: created)
    }

    /// Returns `mailboxId`'s current `MailboxRecord` only if it still
    /// exists *and* its `uidValidity` still matches `expectedUidValidity`
    /// — `nil` otherwise (mailbox gone, or recreated with a different
    /// uidValidity since `expectedUidValidity` was captured). The same
    /// staleness contract `SetFlagsOpPayload`/`MoveOpPayload`/`DeleteOpPayload`
    /// already encode inline at each of their call sites; factored out here
    /// since `.saveDraft`'s old-copy cleanup, `.deleteDraft`, and `.send`'s
    /// linked-draft cleanup all need the identical check.
    private func mailboxIfCurrent(id: Int64, expectedUidValidity: Int64) async throws -> MailboxRecord? {
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
    private func deleteMessage(mailboxPath: String, uid: UInt32, uidValidity: Int64, session: any IMAPSessionProtocol) async throws {
        let change = FlagChange(
            uids: UIDSet([uid]), op: .add, flags: .deleted,
            uidValidity: UInt32(truncatingIfNeeded: uidValidity)
        )
        try await session.store(mailboxPath: mailboxPath, change: change)
        try await session.expunge(mailboxPath: mailboxPath)
    }

    private func draftMessage(id: Int64) async throws -> DraftMessageRecord? {
        try await database.dbWriter.read { db in try DraftMessageRecord.fetchOne(db, key: id) }
    }

    private func draftAttachments(draftMessageId: Int64) async throws -> [DraftAttachmentRecord] {
        try await database.dbWriter.read { db in
            try DraftAttachmentRecord.filter(Column("draftMessageId") == draftMessageId).fetchAll(db)
        }
    }

    private func outboxMessage(id: Int64) async throws -> OutboxMessageRecord? {
        try await database.dbWriter.read { db in try OutboxMessageRecord.fetchOne(db, key: id) }
    }

    /// Task #124 (二重送信防止): atomically claims the exclusive right to
    /// actually transmit `outboxMessageId` over SMTP — sets
    /// `OutboxMessageRecord.sendStartedAt` only if it was still `nil`,
    /// using one serialized `dbWriter.write` transaction as the
    /// compare-and-swap (GRDB's single writer connection means this
    /// fetch-check-update can't interleave with any other write, in this
    /// process or — since the writer is the SQLite file's actual serial
    /// lock — any other process either). Returns `true` if this call won
    /// the claim, `false` if another attempt already holds it (a
    /// concurrent replay racing on the same op — belt-and-suspenders
    /// behind `inFlightAccountIds`, which normally rules this out already
    /// — or a previous attempt that claimed this row and then never
    /// reached `releaseSendClaim`/the outbox row's own deletion before the
    /// process died).
    private func claimSendStart(outboxMessageId: Int64) async throws -> Bool {
        try await database.dbWriter.write { db in
            guard var outbox = try OutboxMessageRecord.fetchOne(db, key: outboxMessageId) else {
                // Row already gone (a previous pass finished the send and
                // deleted it) — nothing to claim; the caller's own
                // `outboxMessage(id:)` guard normally catches this first,
                // but stay defensive here too.
                return false
            }
            guard outbox.sendStartedAt == nil else { return false }
            outbox.sendStartedAt = Date()
            try outbox.update(db, columns: [Column("sendStartedAt")])
            return true
        }
    }

    /// Releases a claim `claimSendStart(outboxMessageId:)` won, for when
    /// the SMTP attempt itself is *definitively* known to have failed (a
    /// local exception returned control to this actor before/during
    /// `sendMessage`, rather than the process dying mid-await with no
    /// chance to run this at all) — letting a later replay pass retry
    /// normally, same as before this task's idempotency guard existed.
    /// Never called once `sendMessage` has actually succeeded — see the
    /// `.send` case's own comment for why the claim staying set from that
    /// point on is intentional.
    private func releaseSendClaim(outboxMessageId: Int64) async {
        try? await database.dbWriter.write { db in
            guard var outbox = try OutboxMessageRecord.fetchOne(db, key: outboxMessageId) else { return }
            outbox.sendStartedAt = nil
            try outbox.update(db, columns: [Column("sendStartedAt")])
        }
    }

    private func outboxAttachments(outboxMessageId: Int64) async throws -> [OutboxAttachmentRecord] {
        try await database.dbWriter.read { db in
            try OutboxAttachmentRecord.filter(Column("outboxMessageId") == outboxMessageId).fetchAll(db)
        }
    }

    /// Deletes the `outboxMessage` row (its `outboxAttachment` rows cascade
    /// via the schema's `onDelete: .cascade` FK) and, best-effort, the
    /// staged files under `<Application Support>/otegami/Outbox/...` those
    /// rows pointed at — read *before* the row delete since the FK cascade
    /// would otherwise remove the very rows this needs to find the paths.
    /// A failed unlink (already gone, permissions) is silently ignored:
    /// the message has already been sent successfully by this point, so
    /// nothing about the send itself should be allowed to fail here — see
    /// this case's caller for why nothing past the SMTP send may retry.
    private func deleteOutboxMessage(id: Int64) async throws {
        let attachmentPaths = try await outboxAttachments(outboxMessageId: id).map(\.localPath)
        _ = try await database.dbWriter.write { db in try OutboxMessageRecord.deleteOne(db, key: id) }
        for path in attachmentPaths {
            try? FileManager.default.removeItem(atPath: path)
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
        case .serverError, .malformedResponse, .mailboxNotFound, .notImplemented, .invalidAddress:
            false
        }
    }
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
