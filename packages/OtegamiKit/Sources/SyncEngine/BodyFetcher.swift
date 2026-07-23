import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore

/// Lazy body fetch (M2): downloads and persists one message's body via an
/// already-connected `IMAPSessionProtocol` session, and prioritizes which
/// messages get fetched first (recent-first prefetch after initial sync,
/// on-open fetch when a message is actually read).
///
/// Unlike `AccountSyncer`, `BodyFetcher` owns no IMAP connection of its
/// own — callers (`AccountSyncer`'s post-initial-sync prefetch,
/// `SyncCoordinator`'s on-open fetch) hand it a session that's already
/// `connect`ed and has the right mailbox `select`ed, so a batch of fetches
/// (e.g. the 50-message prefetch) reuses one connection instead of paying
/// a fresh IMAP handshake per message.
public actor BodyFetcher {
    /// How many of a mailbox's most-recently-received not-yet-fetched
    /// messages `AccountSyncer` prefetches right after initial sync (plan:
    /// "直近50件を優先度順に先読み").
    public static let defaultPrefetchLimit = 50

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Fetches and persists `message`'s body: upserts `messageBody`
    /// (`plainText`/`html`), replaces its `attachment` rows, and updates
    /// `message.bodyState`/`snippet`. Sets `bodyState` to `.fetching`
    /// before the network call so a concurrent viewer (on-open fetch
    /// racing the prefetch pass for the same message) can tell a fetch is
    /// already underway; on failure, reverts to `.notFetched` and rethrows
    /// so the caller can surface the error.
    public func fetchBody(
        message: MessageRecord,
        mailboxPath: String,
        session: any IMAPSessionProtocol
    ) async throws {
        guard let messageId = message.id else { return }

        try await database.dbWriter.write { db in
            var record = message
            record.bodyState = .fetching
            try record.update(db)
        }

        do {
            let content = try await session.fetchBody(mailboxPath: mailboxPath, uid: UInt32(message.uid))
            let plainText = Self.resolvePlainText(from: content)
            let snippet = SnippetBuilder.make(from: plainText)

            try await database.dbWriter.write { db in
                try MessageBodyRecord.deleteOne(db, key: messageId)
                let body = MessageBodyRecord(
                    messageId: messageId,
                    plainText: plainText,
                    html: content.html,
                    fetchedAt: Date()
                )
                try body.insert(db)

                try AttachmentRecord.filter(Column("messageId") == messageId).deleteAll(db)
                for part in content.parts {
                    var attachment = AttachmentRecord(
                        messageId: messageId,
                        partId: part.partId,
                        filename: part.filename,
                        mimeType: part.mimeType,
                        mimeSubtype: part.mimeSubtype,
                        contentId: part.contentId,
                        isInline: part.contentId != nil && !part.isAttachment,
                        size: part.size
                    )
                    try attachment.insert(db)
                }

                var record = message
                record.bodyState = .fetched
                record.snippet = snippet
                record.hasAttachments = record.hasAttachments || content.parts.contains { $0.isAttachment }
                record.updatedAt = Date()
                try record.update(db)
            }
        } catch {
            try? await database.dbWriter.write { db in
                var record = message
                record.bodyState = .notFetched
                try record.update(db)
            }
            throw error
        }
    }

    /// Fetches bodies for up to `limit` of `mailboxId`'s most-recently-
    /// received messages that don't have one yet, newest first, via
    /// `session` (already connected, with `mailboxPath` selected).
    /// Best-effort: one message's fetch failing (deleted server-side,
    /// transient error, ...) doesn't stop the rest of the batch. Returns
    /// the number successfully fetched.
    @discardableResult
    public func prefetchRecent(
        mailboxId: Int64,
        mailboxPath: String,
        limit: Int = BodyFetcher.defaultPrefetchLimit,
        session: any IMAPSessionProtocol
    ) async throws -> Int {
        let candidates = try await database.dbWriter.read { db in
            try MessageRecord
                .filter(Column("mailboxId") == mailboxId)
                .filter(Column("bodyState") == MessageBodyState.notFetched.rawValue)
                .order(Column("internalDate").desc, Column("uid").desc)
                .limit(limit)
                .fetchAll(db)
        }

        var successCount = 0
        for message in candidates {
            do {
                try await fetchBody(message: message, mailboxPath: mailboxPath, session: session)
                successCount += 1
            } catch {
                continue
            }
        }
        return successCount
    }

    /// `messageBody.plainText`: the backend's own plain-text rendering
    /// when it has one, otherwise a plain-text extraction of the HTML body
    /// (plan: "html しか無い場合は HTML からテキスト抽出してplainTextに").
    static func resolvePlainText(from content: MessageBodyContent) -> String? {
        if let plainText = content.plainText, !plainText.isEmpty {
            return plainText
        }
        if let html = content.html, !html.isEmpty {
            let extracted = HTMLTextExtractor.plainText(fromHTML: html)
            return extracted.isEmpty ? nil : extracted
        }
        return nil
    }
}
