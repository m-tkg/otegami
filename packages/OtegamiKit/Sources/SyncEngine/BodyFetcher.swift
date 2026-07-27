import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore
import OtegamiTranslation

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

    /// Tracks a fetch currently in progress for a given `MessageRecord.id`
    /// — Task #31 (launch/foreground background prefetch): once that
    /// prefetch pass and the on-open lazy fetch (`SyncCoordinator.fetchBody
    /// (for:mailboxPath:account:auth:)`) can both race to fetch the same
    /// message, actor reentrancy alone isn't enough to prevent a duplicate
    /// network fetch — `fetchBody` below can suspend at `await session
    /// .fetchBody(...)`, and a second call for the same `messageId` could
    /// otherwise enter the actor and start its own independent fetch during
    /// that suspension. A second caller for a `messageId` already in this
    /// dictionary awaits the *same* `Task` instead of starting a new one.
    private var inFlightFetches: [Int64: Task<Void, Error>] = [:]

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
    ///
    /// Always (re-)fetches over the network, even if `message.bodyState`
    /// is already `.fetched` — `prefetchRecent`'s own re-fetch contract
    /// (a message's body/attachments get *replaced*, not skipped, on a
    /// second call) and `SyncCoordinator`'s on-open/compose-quote paths
    /// both rely on this to force a refresh on demand. Callers that want
    /// an "already fetched? skip" check (Task #31's launch/foreground
    /// prefetch — see `SyncCoordinator
    /// .prefetchUnifiedInboxBodiesIfNeeded`) do that themselves, re-reading
    /// fresh state right before calling in, rather than this shared entry
    /// point silently no-op'ing for every caller.
    public func fetchBody(
        message: MessageRecord,
        mailboxPath: String,
        session: any IMAPSessionProtocol
    ) async throws {
        guard let messageId = message.id else { return }

        if let existing = inFlightFetches[messageId] {
            try await existing.value
            return
        }

        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.performFetch(message: message, mailboxPath: mailboxPath, session: session, messageId: messageId)
        }
        inFlightFetches[messageId] = task
        defer { inFlightFetches[messageId] = nil }
        try await task.value
    }

    private func performFetch(
        message: MessageRecord,
        mailboxPath: String,
        session: any IMAPSessionProtocol,
        messageId: Int64
    ) async throws {
        try await database.dbWriter.write { db in
            var record = message
            record.bodyState = .fetching
            try record.update(db)
        }

        do {
            let content = try await session.fetchBody(mailboxPath: mailboxPath, uid: UInt32(message.uid))
            let plainText = Self.resolvePlainText(from: content)
            let snippet = SnippetBuilder.make(from: plainText)
            // M12 (docs/translation.md): detected once, right here, rather
            // than lazily when a list row or detail view first asks —
            // `MessageLanguageDetector` is cheap (`NLLanguageRecognizer`,
            // no LLM) so doing it inline with the body fetch that already
            // just happened doesn't meaningfully slow this down, and means
            // "is this an English message" is always already known by the
            // time any UI needs it.
            let detectedLanguage = plainText.flatMap(Self.detectLanguage)

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
                record.detectedLanguage = detectedLanguage
                record.hasAttachments = record.hasAttachments || content.parts.contains { $0.isAttachment }
                record.updatedAt = Date()
                try record.update(db)

                // M7: the body just arrived, so this is exactly when
                // `messageSearchIndex.plainText` needs to catch up —
                // `AccountSyncer.upsert`'s envelope-time index write ran
                // with no body yet (subject/fromText only).
                try FTSIndexer.reindex(messageId: messageId, db: db)
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

    /// `MessageLanguageDetector.detect`, wrapped: that type's whole API is
    /// itself `#if canImport(NaturalLanguage)`-gated (see its doc comment),
    /// so this call site needs the same guard to keep compiling on a
    /// hypothetical `NaturalLanguage`-less platform — `nil` there, same as
    /// "the recognizer wasn't confident enough to commit to a language".
    static func detectLanguage(_ plainText: String) -> String? {
        #if canImport(NaturalLanguage)
        MessageLanguageDetector.detect(plainText)
        #else
        nil
        #endif
    }
}
