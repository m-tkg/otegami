import Foundation
import OtegamiCore
import OtegamiStore
import SyncEngine

extension ComposerView {
    func send() async {
        guard let accountId = selectedAccountId,
              let account = environment.accounts.first(where: { $0.id == accountId })
        else { return }

        let toAddresses = EmailAddress.parseAddresses(toText)
        guard !toAddresses.isEmpty else {
            errorMessage = "宛先を入力してください。"
            return
        }
        let ccAddresses = EmailAddress.parseAddresses(ccText)
        let bccAddresses = EmailAddress.parseAddresses(bccText)

        isSending = true
        defer { isSending = false }

        do {
            // M8: stage each pending attachment's bytes onto disk *before*
            // the DB transaction below — `OutboxAttachmentRecord.localPath`
            // is `NOT NULL` (unlike the received-side `attachment.localPath`,
            // which starts `nil`), so a row for it should never exist
            // without a file already backing it. A staging failure here
            // (out of disk space, ...) surfaces as this whole send failing
            // up front, rather than an inconsistent partially-attached
            // outbox row.
            let stagedAttachments = try Self.stageAttachments(pendingAttachments, subdirectory: "Outbox")

            // Task #162: "本文 + 空行 + 署名" combined exactly once, here, for
            // the actual RFC822 payload — see `bodyDocumentWithSignature`'s
            // doc comment for why the plain/HTML pair is derived from one
            // shared `RichTextDocument` rather than two independently-built
            // strings.
            let sendDocument = bodyDocumentWithSignature
            let outboxId: Int64? = try await environment.database.dbWriter.write { db in
                var outbox = OutboxMessageRecord(
                    accountId: accountId,
                    toAddresses: toAddresses,
                    ccAddresses: ccAddresses,
                    bccAddresses: bccAddresses,
                    subject: subject,
                    plainTextBody: sendDocument.plainText,
                    htmlBody: RichTextHTMLCoder.encode(sendDocument),
                    inReplyToMessageId: inReplyToMessageId,
                    references: references,
                    draftServerMailboxId: draftServerMailboxId,
                    draftServerUid: draftServerUid,
                    draftServerUidValidity: draftServerUidValidity
                )
                try outbox.insert(db)
                guard let outboxId = outbox.id else { return nil }
                for staged in stagedAttachments {
                    var attachmentRecord = OutboxAttachmentRecord(
                        outboxMessageId: outboxId, filename: staged.filename,
                        mimeType: staged.mimeType, localPath: staged.url.path, size: staged.size
                    )
                    try attachmentRecord.insert(db)
                }
                try OpQueue.enqueueSend(accountId: accountId, outboxMessageId: outboxId, db: db)
                return outboxId
            }

            // C6/C7: the message is already durably queued at this point
            // (the transaction above committed) — everything from here on
            // only decides *when* it's allowed to actually leave, never
            // whether it's lost. `dismiss()` happens unconditionally
            // either way, matching the pre-C7 behavior of closing the
            // Composer the instant the local write succeeds.
            dismiss()
            guard let outboxId else { return }
            Self.pendingSendLogger.notice("enqueued: outboxMessageId=\(outboxId, privacy: .public) accountId=\(accountId, privacy: .private)")

            #if os(iOS)
            // iOS only (`SendCancelWindow`'s doc comment covers the "why
            // not 30s/60s" reasoning; macOS's Composer is its own window
            // rather than a sheet over a persistent tab bar, so there's no
            // natural home for `SendCountdownBar` there — send stays
            // immediate on that platform, matching every prior milestone's
            // behavior).
            if let duration = SendCancelWindow(rawValue: sendCancelWindowRaw)?.duration ?? SendCancelSettingsStore.defaultWindow.duration {
                // Task #162: deliberately the *unmerged* body (`bodyText`/
                // `bodySnapshotString`, not `sendDocument` above) plus the
                // signature choice kept separate — reopening a cancelled
                // send should show the same editable body and signature
                // preview the Composer had, not the body with the
                // signature already baked into it.
                let snapshot = PendingSendDraftSnapshot(
                    accountId: accountId, toText: toText, ccText: ccText, bccText: bccText, subject: subject, bodyText: bodyText,
                    htmlBody: bodySnapshotString,
                    signatureId: selectedSignatureId,
                    inReplyToMessageId: inReplyToMessageId, references: references,
                    attachments: pendingAttachments,
                    draftServerMailboxId: draftServerMailboxId, draftServerUid: draftServerUid, draftServerUidValidity: draftServerUidValidity
                )
                await environment.pendingSendCoordinator.schedule(outboxMessageId: outboxId, accountId: accountId, duration: duration, snapshot: snapshot)
                return
            }
            #endif

            // Cancel window is "なし" (or this is macOS): best-effort
            // immediate replay, same pattern as
            // MessageView.markAsReadIfNeeded/MessageListView's swipe
            // actions — harmless if offline, the op just waits for the
            // next successful connection.
            if let auth = try? await environment.auth(for: account) {
                Task { _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth) }
            }
        } catch {
            errorMessage = "送信の準備に失敗しました: \(error)"
        }
    }
}
