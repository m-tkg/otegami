import Foundation
import SwiftUI
import OtegamiCore
import OtegamiStore
import MailTransport

// MARK: - Attachments (M8)

extension MessageView {
    /// Inline (`cid:`-referenced) parts are excluded — those render inside
    /// `HTMLMessageView`'s body itself (via the `otegami-cid://` scheme
    /// handler), so listing them again here as a separate downloadable row
    /// would be confusing/redundant. Task #84: recognized calendar-invite
    /// technical parts (the unnamed `text/calendar` alternative, the
    /// `invite.ics`-style attachment) are excluded too, same rationale as
    /// Gmail/Spark — `CalendarInviteSectionView` above already shows the
    /// event as a card, so re-listing its raw MIME carrier(s) as plain
    /// "here's a file" rows would just be confusing technical noise, not
    /// useful to the user. Only genuine "here's a file" parts show up in
    /// this list.
    private var listableAttachments: [AttachmentRecord] {
        attachments.filter { !$0.isInline && !Self.isCalendarInvitePart($0) }
    }

    /// Task #66/#84: the MIME part driving `CalendarInviteSectionView`
    /// above. A real Google Calendar invite carries the event as *two*
    /// separate parts — an unnamed `text/calendar; method=REQUEST` part
    /// (nested as a third sibling of `multipart/alternative`'s `text/plain`/
    /// `text/html`, not the `multipart/mixed`-level sibling the original
    /// fixture modeled) plus a separately named `application/ics`
    /// (`invite.ics`) attachment — so either alone finding a match isn't
    /// enough; `CalendarInviteAttachmentMatching.primaryInvitePart` picks
    /// whichever single one should feed the card, in preference order (see
    /// its own doc comment). Still listed in `attachmentSection` too before
    /// Task #84 (now hidden via `listableAttachments` above) — this
    /// computed property is purely "does an invite card exist", not about
    /// what else is visible below it.
    var calendarInviteAttachment: AttachmentRecord? {
        CalendarInviteAttachmentMatching.primaryInvitePart(
            among: attachments,
            mimeType: { $0.mimeType },
            mimeSubtype: { $0.mimeSubtype },
            filename: { $0.filename }
        )
    }

    private static func isCalendarInvitePart(_ attachment: AttachmentRecord) -> Bool {
        CalendarInviteAttachmentMatching.isInvitePart(
            mimeType: attachment.mimeType, mimeSubtype: attachment.mimeSubtype, filename: attachment.filename
        )
    }

    /// Task #76 (Spark 参考画像を基にしたカード表示への刷新):
    /// 「添付ファイル N 個」ヘッダ + `AttachmentCardRow` のカード列。行の
    /// 中身は `AttachmentCardRow` (別ファイル) に切り出し済み — CLAUDE.md の
    /// 「`ForEach`の中身は独立した`View`型に切り出す」というCI型チェック
    /// タイムアウト対策のルール参照。エラーはカードごと
    /// (`attachmentErrorMessages[id]`) に持つよう変更 — 以前は
    /// リスト全体の下に1つだけ表示していたが (`missingCredentialAwareErrorMessage`
    /// が返す「(Google認証が原因の可能性)」的な文言も含め)、複数の添付が
    /// ある時にどれの取得が失敗したのか分からなくなるため、失敗した
    /// カード自身にエラー文言を出す設計に変更した。
    var attachmentSection: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
            Text("添付ファイル \(listableAttachments.count) 個")
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkSecondary)
                .accessibilityIdentifier("messageDetail.attachmentsHeader")
            ForEach(listableAttachments) { attachment in
                let attachmentId = attachment.id ?? 0
                AttachmentCardRow(
                    attachment: attachment,
                    isDownloading: fetchingAttachmentIds.contains(attachmentId),
                    errorMessage: attachmentErrorMessages[attachmentId],
                    onTap: { Task { await openAttachment(attachment) } }
                )
            }
        }
        .accessibilityIdentifier("messageDetail.attachments")
    }

    /// Tapping an attachment row: already-downloaded (`localPath` points at
    /// a file that still exists) opens QuickLook immediately; otherwise
    /// fetches it first (with `fetchingAttachmentIds` driving that row's
    /// spinner — plan: "タップ → 未取得ならスピナー付き取得 → QuickLook プレビュー"),
    /// then opens it. `.quickLookPreview($previewURL)` (SwiftUI's own
    /// modifier, available on both iOS and macOS since it was introduced)
    /// is used over a hand-rolled `QLPreviewController`/`QLPreviewPanel`
    /// wrapper per platform — simpler, and it's exactly the single-URL case
    /// this view needs (one attachment previewed at a time, no "next/
    /// previous" browsing across the whole attachment list).
    private func openAttachment(_ attachment: AttachmentRecord) async {
        guard let attachmentId = attachment.id else { return }
        attachmentErrorMessages[attachmentId] = nil

        if let localPath = attachment.localPath, FileManager.default.fileExists(atPath: localPath) {
            previewURL = URL(fileURLWithPath: localPath)
            return
        }
        guard !fetchingAttachmentIds.contains(attachmentId) else { return }

        fetchingAttachmentIds.insert(attachmentId)
        defer { fetchingAttachmentIds.remove(attachmentId) }

        do {
            let updated = try await fetchAttachmentOverNetwork(attachment)
            if let index = attachments.firstIndex(where: { $0.id == attachmentId }) {
                attachments[index] = updated
            }
            if let localPath = updated.localPath {
                previewURL = URL(fileURLWithPath: localPath)
            } else {
                attachmentErrorMessages[attachmentId] = "添付ファイルの取得に失敗しました。"
            }
        } catch {
            attachmentErrorMessages[attachmentId] = await missingCredentialAwareErrorMessage(prefix: "添付ファイルの取得に失敗しました", underlyingError: error)
        }
    }

    private func fetchAttachmentOverNetwork(_ attachment: AttachmentRecord) async throws -> AttachmentRecord {
        guard let message, let mailboxPath else { throw MailTransportError.notConnected }
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else {
            throw MailTransportError.notConnected
        }
        let auth: MailAuth
        do {
            auth = try await environment.auth(for: account)
        } catch {
            // Bug fix: this used to discard whatever `auth(for:)` actually
            // threw and replace it with a fixed "資格情報が見つかりません",
            // which meant a Keychain read failure, an expired OAuth
            // refresh token, and "no GOOGLE_OAUTH_CLIENT_ID configured"
            // all showed the exact same message — indistinguishable from
            // the user-visible side, and useless for diagnosing a real
            // report against it. Preserving `error`'s own description
            // (`AuthResolutionError`/`TokenStoreError` are both named
            // enums, and `KeychainCredentialStore.KeychainError` already
            // has a real `CustomStringConvertible` description) keeps this
            // still wrapped as a `MailTransportError.authenticationFailed`
            // (so existing call sites that only branch on the error *case*
            // keep working) while no longer hiding *why*.
            throw MailTransportError.authenticationFailed(underlyingDescription: "\(error)")
        }
        return try await environment.syncCoordinator.fetchAttachment(
            attachment, messageUID: message.uid, mailboxPath: mailboxPath, account: account, auth: auth
        )
    }
}
