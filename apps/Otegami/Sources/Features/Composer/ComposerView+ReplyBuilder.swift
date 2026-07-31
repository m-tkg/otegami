import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore

extension ComposerView {
    func prefillReply(toOriginalMessageId originalMessageId: Int64, replyAll: Bool) async {
        struct ReplyContext {
            var message: MessageRecord
            var accountId: String
            var referenceValues: [String]
            var bodyRecord: MessageBodyRecord?
        }

        let context: ReplyContext? = try? await environment.database.dbWriter.read { db -> ReplyContext? in
            guard let message = try MessageRecord.fetchOne(db, key: originalMessageId) else { return nil }
            guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { return nil }
            let referenceValues = try MessageReferenceRecord
                .filter(Column("messageId") == originalMessageId)
                .order(Column("position"))
                .fetchAll(db)
                .map(\.referenceValue)
            let bodyRecord = try MessageBodyRecord.fetchOne(db, key: originalMessageId)
            return ReplyContext(message: message, accountId: mailbox.accountId, referenceValues: referenceValues, bodyRecord: bodyRecord)
        }
        guard let context else { return }

        selectedAccountId = context.accountId
        subject = "Re: " + SubjectNormalizer.normalize(context.message.subject ?? "")
        inReplyToMessageId = context.message.messageId

        var chain = context.referenceValues
        if let ownMessageId = context.message.messageId, chain.last != ownMessageId {
            chain.append(ownMessageId)
        }
        references = chain

        let ownAddress = environment.accounts.first { $0.id == context.accountId }?.email.lowercased()
        if replyAll {
            var to = context.message.fromAddresses
            to.append(contentsOf: context.message.toAddresses.filter { $0.address.lowercased() != ownAddress })
            toText = to.map(\.description).joined(separator: ", ")
            ccText = context.message.ccAddresses
                .filter { $0.address.lowercased() != ownAddress }
                .map(\.description)
                .joined(separator: ", ")
        } else {
            toText = context.message.fromAddresses.map(\.description).joined(separator: ", ")
        }

        setPlainBody("\n\n" + quotedBody(from: context.bodyRecord))
    }

    /// Plain-text quoting (plan: "本文に`> `引用"). Falls back to
    /// `HTMLTextExtractor` for an HTML-only original body — the same
    /// dependency-free extractor `SyncEngine.BodyFetcher` already uses for
    /// its own plain-text derivation, so a reply never needs a WKWebView
    /// just to quote text.
    private func quotedBody(from bodyRecord: MessageBodyRecord?) -> String {
        let source: String
        if let plainText = bodyRecord?.plainText, !plainText.isEmpty {
            source = plainText
        } else if let html = bodyRecord?.html, !html.isEmpty {
            source = HTMLTextExtractor.plainText(fromHTML: html)
        } else {
            return ""
        }
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
    }

    /// 新画面構成 (3): メール本文画面フッターツールバーの「転送」。件名に `Fwd: `
    /// を付け、`quotedBody(from:)` (返信と同じ `> ` 引用) の前に転送元の
    /// From/Date/Subject/To を示すヘッダーブロックを差し込む。宛先 (To/Cc) は
    /// 空のまま — 転送は「誰に送るか」をユーザーが必ず選び直す操作なので、
    /// 元メールの宛先を引き継がない (`prefillReply`との一番の違い)。
    ///
    /// **添付ファイルの引き継ぎ**: `loadServerDraft(messageId:)`と全く同じ経路
    /// (`environment.syncCoordinator.fetchAttachment`) で、本文が未取得なら
    /// ネットワーク越しに取得してから引き継ぐ。取得できなかった添付が1つでも
    /// あれば (オフライン、認証エラー等)、本文の末尾にその旨を追記する —
    /// 指示の「引き継がないなら本文にその旨表示」を、"全く引き継がない"では
    /// なく "引き継げなかった分だけ明示する" 形で実装した (取得できる限りは
    /// 引き継ぐ方が実用的なため)。
    func prefillForward(originalMessageId: Int64) async {
        struct ForwardContext {
            var message: MessageRecord
            var accountId: String
            var mailboxPath: String
            var bodyRecord: MessageBodyRecord?
            var attachments: [AttachmentRecord]
        }

        let context: ForwardContext? = try? await environment.database.dbWriter.read { db -> ForwardContext? in
            guard let message = try MessageRecord.fetchOne(db, key: originalMessageId) else { return nil }
            guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { return nil }
            let bodyRecord = try MessageBodyRecord.fetchOne(db, key: originalMessageId)
            let attachments = try AttachmentRecord.filter(Column("messageId") == originalMessageId).order(Column("id")).fetchAll(db)
            return ForwardContext(message: message, accountId: mailbox.accountId, mailboxPath: mailbox.path, bodyRecord: bodyRecord, attachments: attachments)
        }
        guard var context else { return }

        selectedAccountId = context.accountId
        subject = "Fwd: " + SubjectNormalizer.normalize(context.message.subject ?? "")
        // Deliberately no `inReplyToMessageId`/`references` — see
        // `ComposerLaunchPayload.Kind.forward`'s doc comment.

        let account = environment.accounts.first { $0.id == context.accountId }
        var auth: MailAuth?
        if let account {
            auth = try? await environment.auth(for: account)
        }

        if context.message.bodyState != .fetched, let account, let auth {
            try? await environment.syncCoordinator.fetchBody(for: context.message, mailboxPath: context.mailboxPath, account: account, auth: auth)
            context.bodyRecord = try? await environment.database.dbWriter.read { db in try MessageBodyRecord.fetchOne(db, key: originalMessageId) }
            context.attachments = (try? await environment.database.dbWriter.read { db in
                try AttachmentRecord.filter(Column("messageId") == originalMessageId).order(Column("id")).fetchAll(db)
            }) ?? context.attachments
        }

        setPlainBody("\n\n" + forwardHeaderBlock(for: context.message) + "\n\n" + quotedBody(from: context.bodyRecord))

        var someAttachmentFailedToCarryOver = false
        if let account, let auth {
            for attachment in context.attachments {
                guard let fetched = try? await environment.syncCoordinator.fetchAttachment(
                    attachment, messageUID: context.message.uid, mailboxPath: context.mailboxPath, account: account, auth: auth
                ), let localPath = fetched.localPath, let data = FileManager.default.contents(atPath: localPath) else {
                    someAttachmentFailedToCarryOver = true
                    continue
                }
                pendingAttachments.append(
                    PendingAttachment(
                        filename: fetched.filename ?? "attachment",
                        mimeType: "\(fetched.mimeType)/\(fetched.mimeSubtype)",
                        data: data
                    )
                )
            }
        } else if !context.attachments.isEmpty {
            someAttachmentFailedToCarryOver = true
        }
        if someAttachmentFailedToCarryOver {
            appendPlainBody("\n\n(元メールの添付ファイルを一部引き継げませんでした。必要であれば改めて添付してください。)")
        }
    }

    /// 転送メールの本文冒頭に差し込む「---------- 転送されたメッセージ ----------」
    /// ブロック — 多くのメールクライアントが転送時に付ける慣習的な見出し。
    private func forwardHeaderBlock(for message: MessageRecord) -> String {
        var lines = ["---------- 転送されたメッセージ ----------"]
        if let from = message.fromAddresses.first {
            lines.append("From: \(from.description)")
        }
        lines.append("Date: \((message.date ?? message.internalDate).formatted(.dateTime.year().month().day().hour().minute()))")
        lines.append("Subject: \(message.subject ?? "")")
        if !message.toAddresses.isEmpty {
            lines.append("To: \(message.toAddresses.map(\.description).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}
