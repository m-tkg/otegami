import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore
import SyncEngine

extension ComposerView {
    /// Resuming a saved local draft (M10): loads its fields, then deletes
    /// the row immediately — `ComposerLaunchPayload.Kind.draft`'s doc
    /// comment explains why ("load transfers ownership" avoids needing
    /// update-vs-insert branching in `saveDraft()`). Best-effort: if the
    /// row is already gone (e.g. deleted from `DraftsView` in another
    /// window right as this one opened), the Composer just opens blank
    /// rather than erroring.
    ///
    /// Drafts IMAP sync: also carries forward `serverMailboxId`/`serverUid`/
    /// `serverUidValidity` (this row may itself be a mirror of a previous
    /// save's server copy) into `draftServerMailboxId`/etc. for
    /// `saveDraft()`'s replace flow, and restores any `draftAttachment`
    /// rows into `pendingAttachments` by reading their bytes back off disk
    /// — read *before* the row delete (which cascades them away), then the
    /// now-orphaned files are removed once their bytes are safely in memory
    /// (mirrors `OpQueueProcessor.deleteOutboxMessage`'s "read paths,
    /// delete row, then unlink" order). A fresh `saveDraft()` re-stages
    /// whatever's still in `pendingAttachments` to new files, so nothing
    /// keeps pointing at the removed ones.
    func loadDraft(draftId: Int64) async {
        struct Loaded {
            var draft: DraftMessageRecord
            var attachments: [DraftAttachmentRecord]
        }
        let loaded: Loaded? = try? await environment.database.dbWriter.write { db in
            guard let draft = try DraftMessageRecord.fetchOne(db, key: draftId) else { return nil }
            let attachments = try DraftAttachmentRecord.filter(Column("draftMessageId") == draftId).fetchAll(db)
            try draft.delete(db)
            return Loaded(draft: draft, attachments: attachments)
        }
        guard let loaded else { return }
        let draft = loaded.draft
        selectedAccountId = draft.accountId
        toText = draft.toAddresses.map(\.description).joined(separator: ", ")
        ccText = draft.ccAddresses.map(\.description).joined(separator: ", ")
        subject = draft.subject
        // Task #161: restore formatting when this draft has an
        // `htmlBody` (every draft saved from here on) — same decode
        // path `loadCancelledSend(_:)` already uses for C7's cancelled-
        // send restore. Falls back to the plain-text projection for a
        // draft saved before this task (schema predates `htmlBody`, or
        // resumed from a `.serverDraft` this Composer session itself
        // hasn't re-saved yet).
        if let htmlBody = draft.htmlBody {
            attributedBodyText = RichTextAttributedString.makeAttributedString(from: RichTextHTMLCoder.decode(html: htmlBody))
        } else {
            setPlainBody(draft.plainTextBody)
        }
        // Task #162: the signature choice this draft was saved with —
        // restored verbatim (never re-derived) rather than left for
        // `loadAvailableSignatures()`'s auto-select to fill in, same as
        // every other field above. `nil` for a draft this schema predates
        // (no migration) or one whose signature was still literal text
        // inside `plainTextBody` back then — either way `selectedSignatureId`
        // simply falls through to the normal auto-select priority chain.
        selectedSignatureId = draft.signatureId
        inReplyToMessageId = draft.inReplyToMessageId
        references = draft.references
        draftServerMailboxId = draft.serverMailboxId
        draftServerUid = draft.serverUid
        draftServerUidValidity = draft.serverUidValidity

        for attachment in loaded.attachments {
            guard let data = FileManager.default.contents(atPath: attachment.localPath) else { continue }
            pendingAttachments.append(PendingAttachment(filename: attachment.filename, mimeType: attachment.mimeType, data: data))
        }
        for attachment in loaded.attachments {
            try? FileManager.default.removeItem(atPath: attachment.localPath)
        }
    }

    /// C7 送信キャンセル: restores every field a cancelled pending send had,
    /// synchronously — see `ComposerLaunchPayload.Kind.cancelledSend`'s doc
    /// comment.
    ///
    /// Task #156: restores formatting too when `snapshot.htmlBody` is
    /// present (decode the HTML back to a `RichTextDocument`, then rebuild
    /// the live `NSAttributedString` — `RichTextAttributedString
    /// .makeAttributedString(from:)`'s doc comment) instead of always
    /// falling back to the plain-text projection, so cancelling a formatted
    /// send and reopening it doesn't silently strip the bold/italic/
    /// underline/strikethrough/list/indent the user had applied.
    func loadCancelledSend(_ snapshot: PendingSendDraftSnapshot) {
        selectedAccountId = snapshot.accountId
        toText = snapshot.toText
        ccText = snapshot.ccText
        bccText = snapshot.bccText
        subject = snapshot.subject
        if let htmlBody = snapshot.htmlBody {
            attributedBodyText = RichTextAttributedString.makeAttributedString(from: RichTextHTMLCoder.decode(html: htmlBody))
        } else {
            setPlainBody(snapshot.bodyText)
        }
        // Task #162: the signature selected at send time — restored
        // straight into `selectedSignatureId` (not mixed back into the
        // body, which `snapshot.bodyText`/`.htmlBody` never contained in
        // the first place).
        selectedSignatureId = snapshot.signatureId
        inReplyToMessageId = snapshot.inReplyToMessageId
        references = snapshot.references
        pendingAttachments = snapshot.attachments
        draftServerMailboxId = snapshot.draftServerMailboxId
        draftServerUid = snapshot.draftServerUid
        draftServerUidValidity = snapshot.draftServerUidValidity
    }

    /// Resuming a server-origin draft (Drafts IMAP sync): a `message` row
    /// living in a `MailboxRoleRecord.drafts` mailbox that no local
    /// `draftMessage` row has claimed (`DraftQuery.UnifiedRow.server`).
    /// Unlike `loadDraft(draftId:)`, this deletes/consumes nothing — the
    /// server remains the sole source of truth until (and unless) the user
    /// actually saves an edit, at which point `saveDraft()` creates a new
    /// `draftMessage` row carrying `draftServerMailboxId`/`draftServerUid`/
    /// `draftServerUidValidity` (captured here) forward as "the old copy to
    /// replace". Fetches the body over the network first if it hasn't been
    /// fetched yet (same on-demand pattern `MessageView.load()` uses for
    /// any message) and downloads every attachment's bytes into
    /// `pendingAttachments` the same way (`AttachmentFetcher`, via
    /// `SyncCoordinator.fetchAttachment`) — best-effort throughout: a
    /// network failure here just leaves the Composer with whatever text/
    /// attachments it already had (from local `message`/`messageBody`/
    /// `attachment` rows if any), never an error blocking the open.
    func loadServerDraft(messageId: Int64) async {
        struct Context {
            var message: MessageRecord
            var accountId: String
            var mailboxPath: String
            var mailboxId: Int64
            var mailboxUidValidity: Int64
            var referenceValues: [String]
            var bodyRecord: MessageBodyRecord?
            var attachments: [AttachmentRecord]
        }

        let context: Context? = try? await environment.database.dbWriter.read { db -> Context? in
            guard let message = try MessageRecord.fetchOne(db, key: messageId) else { return nil }
            guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId), let mailboxId = mailbox.id else { return nil }
            let referenceValues = try MessageReferenceRecord
                .filter(Column("messageId") == messageId)
                .order(Column("position"))
                .fetchAll(db)
                .map(\.referenceValue)
            let bodyRecord = try MessageBodyRecord.fetchOne(db, key: messageId)
            let attachments = try AttachmentRecord.filter(Column("messageId") == messageId).order(Column("id")).fetchAll(db)
            return Context(
                message: message, accountId: mailbox.accountId, mailboxPath: mailbox.path,
                mailboxId: mailboxId, mailboxUidValidity: mailbox.uidValidity,
                referenceValues: referenceValues, bodyRecord: bodyRecord, attachments: attachments
            )
        }
        guard var context else { return }

        selectedAccountId = context.accountId
        toText = context.message.toAddresses.map(\.description).joined(separator: ", ")
        ccText = context.message.ccAddresses.map(\.description).joined(separator: ", ")
        subject = context.message.subject ?? ""
        inReplyToMessageId = context.message.inReplyTo
        references = context.referenceValues

        draftServerMailboxId = context.mailboxId
        draftServerUid = context.message.uid
        draftServerUidValidity = context.mailboxUidValidity

        let account = environment.accounts.first { $0.id == context.accountId }
        var auth: MailAuth?
        if let account {
            auth = try? await environment.auth(for: account)
        }

        // Task #221: checks whether a `messageBody` row actually exists
        // (not `context.message.bodyState != .fetched`) — see
        // `ComposerView+ReplyBuilder.swift`'s identical fetch's doc
        // comment for why `bodyState` alone isn't trustworthy here.
        if context.bodyRecord == nil, let account, let auth {
            try? await environment.syncCoordinator.fetchBody(for: context.message, mailboxPath: context.mailboxPath, account: account, auth: auth)
            context.bodyRecord = try? await environment.database.dbWriter.read { db in try MessageBodyRecord.fetchOne(db, key: messageId) }
            context.attachments = (try? await environment.database.dbWriter.read { db in
                try AttachmentRecord.filter(Column("messageId") == messageId).order(Column("id")).fetchAll(db)
            }) ?? context.attachments
        }

        if let plainText = context.bodyRecord?.plainText, !plainText.isEmpty {
            setPlainBody(plainText)
        } else if let html = context.bodyRecord?.html, !html.isEmpty {
            setPlainBody(HTMLTextExtractor.plainText(fromHTML: html))
        } else {
            setPlainBody("")
        }

        if let account, let auth {
            for attachment in context.attachments {
                guard let fetched = try? await environment.syncCoordinator.fetchAttachment(
                    attachment, messageUID: context.message.uid, mailboxPath: context.mailboxPath, account: account, auth: auth
                ), let localPath = fetched.localPath, let data = FileManager.default.contents(atPath: localPath) else { continue }
                pendingAttachments.append(
                    PendingAttachment(
                        filename: fetched.filename ?? "attachment",
                        mimeType: "\(fetched.mimeType)/\(fetched.mimeSubtype)",
                        data: data
                    )
                )
            }
        }
    }

    /// Persists the current fields as a new `DraftMessageRecord` row, stages
    /// any `pendingAttachments` to disk as `draftAttachment` rows, and
    /// enqueues `OpQueueKind.saveDraft` to `APPEND` it to the account's
    /// Drafts mailbox (Drafts IMAP sync milestone — the M10-era
    /// local-only/attachment-dropping behavior this doc comment used to
    /// describe is superseded; see `DraftMessageRecord`'s doc comment for
    /// the full replace-flow design). `draftServerMailboxId`/`draftServerUid`/
    /// `draftServerUidValidity` — populated by `loadDraft(draftId:)`/
    /// `loadServerDraft(messageId:)` when this Composer session resumed an
    /// already-uploaded-or-downloaded draft — are carried onto the new row
    /// as "the old server copy to replace"; `OpQueueProcessor`'s
    /// `.saveDraft` replay reads them back off that row at replay time.
    func saveDraft() async {
        guard let accountId = selectedAccountId else { return }
        let toAddresses = EmailAddress.parseAddresses(toText)
        let ccAddresses = EmailAddress.parseAddresses(ccText)
        // Nothing at all to save (a blank "新規作成" opened and immediately
        // cancelled without `hasUnsavedChanges` ever going true reaches
        // `dismiss()` directly in `handleCloseRequested()`, so this handles
        // the rarer case of unsaved *whitespace-only* edits) — skip writing
        // an empty row. Attachments alone (no text at all) still count as
        // "something to save" — `pendingAttachments` reaching here nonempty
        // only happens via an explicit user action (picker/photo/loaded
        // from an existing draft), never as a side effect of doing nothing.
        guard !toAddresses.isEmpty || !ccAddresses.isEmpty || !subject.isEmpty
            || !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
        else {
            return
        }
        do {
            let stagedAttachments = try Self.stageAttachments(pendingAttachments, subdirectory: "Drafts")

            try await environment.database.dbWriter.write { db in
                var draft = DraftMessageRecord(
                    accountId: accountId,
                    toAddresses: toAddresses,
                    ccAddresses: ccAddresses,
                    subject: subject,
                    plainTextBody: bodyText,
                    htmlBody: bodySnapshotString,
                    // Task #162: the signature choice, kept separate from
                    // the body above (never mixed in) — see
                    // `DraftMessageRecord.signatureId`'s doc comment.
                    signatureId: selectedSignatureId,
                    inReplyToMessageId: inReplyToMessageId,
                    references: references,
                    serverMailboxId: draftServerMailboxId,
                    serverUid: draftServerUid,
                    serverUidValidity: draftServerUidValidity
                )
                try draft.insert(db)
                guard let draftId = draft.id else { return }
                for staged in stagedAttachments {
                    var attachmentRecord = DraftAttachmentRecord(
                        draftMessageId: draftId, filename: staged.filename,
                        mimeType: staged.mimeType, localPath: staged.url.path, size: staged.size
                    )
                    try attachmentRecord.insert(db)
                }
                try OpQueue.enqueueSaveDraft(accountId: accountId, draftMessageId: draftId, db: db)
            }

            // Best-effort immediate replay, same pattern as `send()` below
            // — harmless if offline, the op just waits for the next
            // successful connection.
            if let account = environment.accounts.first(where: { $0.id == accountId }), let auth = try? await environment.auth(for: account) {
                Task { _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth) }
            }
        } catch {
            // Best-effort, matching every other Composer persistence path
            // in this file (`send()`'s doc comment) — a failure here means
            // the draft is simply lost, same as tapping "破棄" would have.
        }
    }
}
