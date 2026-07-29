import Foundation

/// Verifies that a file URL actually resolves inside an intended parent
/// directory — a `standardizedFileURL` path-prefix check.
///
/// Task #166 (SEC-A, findings F1/F10): `ComposerView.stageAttachments`
/// builds a destination URL by appending an (now-sanitized, see
/// `AttachmentFilename`) attachment filename to a staging directory.
/// Sanitizing the filename is the primary fix, but per the finding's own
/// recommendation this containment check is the fix that "fails closed"
/// regardless of what the filename looks like — it's checked immediately
/// before the write, on the fully-resolved URL, rather than trusting that
/// every filename-producing code path upstream got sanitization right
/// (today, and in any future change). See `docs/qa-findings.md`.
public enum FileSystemPathContainment {
    /// `true` iff `url`, once standardized, is a strict descendant of
    /// `directory` (also standardized) — i.e. `directory`'s path is a
    /// prefix of `url`'s path at a path-component boundary, so
    /// `/a/b` is *not* considered a descendant of `/a/bc` (a naive
    /// `hasPrefix` on the unadorned paths would wrongly accept that).
    /// `url == directory` itself is not a descendant (there'd be no
    /// filename left).
    public static func isDescendant(of directory: URL, url: URL) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        let boundary = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return urlPath.hasPrefix(boundary) && urlPath != boundary
    }
}
