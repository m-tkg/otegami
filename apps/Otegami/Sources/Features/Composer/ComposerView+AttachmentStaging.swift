import Foundation
import OtegamiCore

extension ComposerView {
    /// Copies each pending attachment's in-memory bytes to
    /// `<Application Support>/otegami/<subdirectory>/<UUID>/<filename>` —
    /// one fresh, randomly-named directory per attachment (rather than
    /// nesting under the not-yet-known outbox/draft message id, since these
    /// files are written *before* that row's `db.write` transaction even
    /// starts; `OutboxAttachmentRecord`/`DraftAttachmentRecord.localPath` is
    /// what associates the file back to its message afterward, not its
    /// position in this directory tree). `subdirectory` is `"Outbox"` for
    /// `send()`, `"Drafts"` for `saveDraft()` — two separate trees under one
    /// `otegami/` folder (mirrors `AttachmentFetcher.storageURL`'s "everything
    /// under one `otegami/` folder in Application Support" convention on the
    /// received side) so a draft's staged files are never mistaken for (or
    /// cleaned up alongside) an outbox message's.
    static func stageAttachments(_ pending: [PendingAttachment], subdirectory: String) throws -> [StagedAttachment] {
        guard !pending.isEmpty else { return [] }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let root = base.appendingPathComponent("otegami/\(subdirectory)", isDirectory: true)

        return try pending.map { attachment in
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Task #166 (SEC-A, F1/F10): `attachment.filename` may be a raw
            // MIME `Content-Disposition` filename carried over from a
            // received message (forward/reply-with-attachment), which is
            // fully attacker-controlled and was previously used here
            // unsanitized — a `filename="../../../../Users/x/.zshrc"` on a
            // forwarded message escaped this staging directory entirely
            // (macOS has no app-sandbox entitlement, so that write lands
            // anywhere the app process's user account can reach). Sanitize
            // it with the same logic `SyncEngine.AttachmentFetcher` uses
            // for the receive-side download cache...
            let safeName = AttachmentFilename.sanitize(attachment.filename)
            let url = directory.appendingPathComponent(safeName)
            // ...and, as defense in depth in case the sanitizer above ever
            // has a gap (or a future edit removes the call), refuse to
            // write anywhere the resolved URL isn't actually a child of
            // the directory we just created — this is the check that
            // fails closed no matter what a filename looks like.
            guard FileSystemPathContainment.isDescendant(of: directory, url: url) else {
                throw ComposerAttachmentStagingError.pathEscapesStagingDirectory(filename: attachment.filename)
            }
            try attachment.data.write(to: url, options: .atomic)
            return StagedAttachment(filename: attachment.filename, mimeType: attachment.mimeType, url: url, size: attachment.data.count)
        }
    }

    struct StagedAttachment {
        var filename: String
        var mimeType: String
        var url: URL
        var size: Int
    }
}

/// Thrown by `ComposerView.stageAttachments` when a (sanitized) attachment
/// filename still somehow resolves outside its intended staging directory
/// — the defense-in-depth containment check from Task #166 (SEC-A, F1/
/// F10). Should never actually fire given `AttachmentFilename.sanitize`,
/// but staging refuses to write rather than silently trust the URL if it
/// ever does.
enum ComposerAttachmentStagingError: LocalizedError {
    case pathEscapesStagingDirectory(filename: String)

    var errorDescription: String? {
        switch self {
        case .pathEscapesStagingDirectory:
            return String(localized: "添付ファイルの保存に失敗しました。ファイル名が無効です。")
        }
    }
}
