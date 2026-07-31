import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore

/// The `.saveDraft` op handler, extracted verbatim out of `OpQueueProcessor
/// .apply(op:account:session:auth:)`'s 358-line `switch` (only relocated —
/// no logic changed) alongside the two private helpers it alone needed.
extension OpQueueProcessor {
    func applySaveDraft(
        op: OpQueueRecord,
        account: AccountRecord,
        session: any IMAPSessionProtocol
    ) async throws -> ApplyOutcome {
        let payload = try JSONDecoder().decode(SaveDraftOpPayload.self, from: op.payload)
        guard let draft = try await draftMessage(id: payload.draftMessageId) else {
            // Already replaced by a previous replay pass and since
            // resumed (e.g. the user reopened this draft in Composer
            // before this op got its turn — `ComposerView`'s "load
            // transfers ownership" deletes the row immediately) or
            // deleted, or never existed. Nothing left to build.
            return .staleDiscarded
        }
        guard let drafts = try await MailboxRoleResolver.resolveOrCreate(role: .drafts, accountId: account.id, session: session, database: database) else {
            // See the `.delete` case's identical shape: leave the op
            // pending rather than silently dropping a save.
            throw SyncEngineError.noRoleMailbox(role: .drafts)
        }

        // Same "rebuild attachments from disk at replay time" pattern
        // as `.send`'s outboxAttachment handling — a row whose
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
    }

    private func draftMessage(id: Int64) async throws -> DraftMessageRecord? {
        try await database.dbWriter.read { db in try DraftMessageRecord.fetchOne(db, key: id) }
    }

    private func draftAttachments(draftMessageId: Int64) async throws -> [DraftAttachmentRecord] {
        try await database.dbWriter.read { db in
            try DraftAttachmentRecord.filter(Column("draftMessageId") == draftMessageId).fetchAll(db)
        }
    }
}
