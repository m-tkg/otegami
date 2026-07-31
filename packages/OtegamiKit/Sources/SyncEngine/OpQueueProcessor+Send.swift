import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore

/// The `.send` op handler, extracted verbatim out of `OpQueueProcessor
/// .apply(op:account:session:auth:)`'s 358-line `switch` (only relocated —
/// no logic changed) alongside every private helper it alone needed. Kept
/// as its own file per Task #124's 二重送信防止 (`claimSendStart`/
/// `releaseSendClaim`) being the single most fragile, actually-shipped bug
/// fix in this actor — isolating it makes the diff for any future change
/// here small and easy to re-audit against that guard's timing/ordering.
extension OpQueueProcessor {
    func applySend(
        op: OpQueueRecord,
        account: AccountRecord,
        session: any IMAPSessionProtocol,
        auth: MailAuth
    ) async throws -> ApplyOutcome {
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
            throw SyncEngineError.duplicateSendBlocked
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
            try await smtpSession.connect(auth: SMTPAuthResolver.resolve(imapAuth: auth, account: account))
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
        if account.kind != .gmail, let sent = try await MailboxRoleResolver.mailbox(role: .sent, accountId: account.id, database: database) {
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
}
