import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore

/// On-demand attachment/inline-image data fetch (M8): downloads one
/// `AttachmentRecord`'s bytes via an already-connected
/// `IMAPSessionProtocol` session, saves them under
/// `<Application Support>/otegami/Attachments/<accountId>/<messageId>/<filename>`
/// (mirrors `AppDatabase.makeShared()`'s own `.../otegami/...` nesting
/// rather than the plan's literal `Application Support/Attachments/...`
/// path, so every piece of this app's on-disk state lives under one
/// `otegami/` folder instead of scattering top-level directories in
/// Application Support), and updates `attachment.localPath`.
///
/// Mirrors `BodyFetcher`'s shape deliberately: same "caller hands in an
/// already-`connect`ed/`select`ed session" contract, same "owns no
/// persistent connection of its own" design, for the same reason — a
/// message-open attachment tap and a cid-image resolve during HTML render
/// both want a fresh short-lived connection, not a long-lived one this
/// actor would have to manage the lifecycle of.
public actor AttachmentFetcher {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Downloads and persists `attachment`'s bytes, returning the updated
    /// record (with `localPath` set). If `attachment` already has a
    /// `localPath` pointing at a file that still exists, returns it
    /// unchanged without touching the network — safe to call repeatedly
    /// (e.g. a cid `WKURLSchemeHandler` resolve racing a user's explicit
    /// attachment-row tap for the same inline image).
    @discardableResult
    public func fetchAndStore(
        attachment: AttachmentRecord,
        accountId: String,
        messageUID: Int64,
        mailboxPath: String,
        session: any IMAPSessionProtocol
    ) async throws -> AttachmentRecord {
        guard let attachmentId = attachment.id else { return attachment }

        if let existingPath = attachment.localPath, FileManager.default.fileExists(atPath: existingPath) {
            return attachment
        }

        let data = try await session.fetchMessageBody(
            mailboxPath: mailboxPath,
            uid: UInt32(messageUID),
            partId: attachment.partId
        )

        let destination = try Self.storageURL(
            accountId: accountId,
            messageId: attachment.messageId,
            attachmentId: attachmentId,
            filename: attachment.filename
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)

        var updated = attachment
        updated.localPath = destination.path
        if updated.size == 0 {
            updated.size = data.count
        }
        let toPersist = updated
        try await database.dbWriter.write { db in
            try toPersist.update(db)
        }
        return updated
    }

    /// `<Application Support>/otegami/Attachments/<accountId>/<messageId>/<attachmentId>-<sanitizedFilename>`.
    /// The attachment id is prefixed onto the filename (rather than nesting
    /// one more directory level per attachment) so two attachments on the
    /// same message that happen to share a filename (e.g. two
    /// `image.png` inline parts) can't collide.
    static func storageURL(accountId: String, messageId: Int64, attachmentId: Int64, filename: String?) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("otegami", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(accountId, isDirectory: true)
            .appendingPathComponent(String(messageId), isDirectory: true)
        let safeName = sanitizeFilename(filename ?? "attachment")
        return directory.appendingPathComponent("\(attachmentId)-\(safeName)")
    }

    /// Strips path separators and leading dots from an (untrusted, IMAP-
    /// server-supplied) filename so it can't escape `storageURL`'s intended
    /// directory (`"../../etc/passwd"`) or be hidden (a leading `.`).
    static func sanitizeFilename(_ filename: String) -> String {
        let stripped = filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let trimmed = stripped.drop { $0 == "." }
        return trimmed.isEmpty ? "attachment" : String(trimmed)
    }
}
