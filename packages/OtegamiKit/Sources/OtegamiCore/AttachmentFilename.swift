import Foundation

/// Sanitizes an untrusted, attacker-controlled attachment filename (MIME
/// `Content-Disposition`/`Content-Type` `filename`, as decoded from a
/// remote message's headers — see `RFC2231FilenameDecoder` — and stored
/// verbatim in `AttachmentRecord.filename`) so it is safe to use as a
/// single filesystem path component.
///
/// Task #166 (SEC-A, findings F1/F10 of `CLAUDE-SECURITY-RESULTS.md`)
/// found that while `SyncEngine.AttachmentFetcher`'s received-attachment
/// download cache already sanitized filenames this way, `ComposerView
/// .stageAttachments` (outbox/draft staging when forwarding/replying with
/// an attachment carried over from a received message) used the raw
/// filename directly in `appendingPathComponent` before `Data.write(to:)`.
/// The macOS target has no `com.apple.security.app-sandbox` entitlement,
/// so a crafted `Content-Disposition: filename="../../../../Users/x/
/// .zshrc"` on a message the victim later forwards could write attacker
/// bytes anywhere the app process's user account can reach. Pulled out
/// here (rather than left duplicated, or left only in `SyncEngine`) so
/// both call sites share one implementation — see `docs/qa-findings.md`
/// for the finding and fix writeup.
///
/// This alone is defense-in-depth, not the whole fix: callers that write
/// to disk using a sanitized name should *also* verify the resolved URL
/// is still a descendant of the intended directory before writing (see
/// `ComposerView.stageAttachments`) — sanitization is easy to get subtly
/// wrong (a future edge case, a second caller that forgets to call it),
/// while a containment check at the write site fails closed regardless.
///
/// Distinct from `MessageSourceFilename`: that one builds a filename a
/// user will actually *see* in a share sheet from free-form subject text,
/// so it strips symbols/punctuation outright. This one only neutralizes
/// the handful of characters that are actually dangerous for path
/// traversal, preserving everything else (symbols, non-ASCII, spaces)
/// verbatim so a legitimate attachment keeps a recognizable name.
public enum AttachmentFilename {
    /// Filesystem path-component length limits (255 bytes on APFS and
    /// most other filesystems) make anything past a few hundred
    /// characters pointless risk surface; this is generous headroom for a
    /// legitimate long filename while still bounding worst-case input.
    public static let maxLength = 255

    /// - Parameters:
    ///   - filename: the untrusted filename, as read from MIME headers.
    ///     `nil`, empty, or entirely path separators/leading dots all
    ///     collapse to `fallback`.
    ///   - fallback: name to use when nothing safe survives sanitization.
    public static func sanitize(_ filename: String?, fallback: String = "attachment") -> String {
        let raw = filename ?? ""
        // Neutralize path separators outright (rather than trying to
        // `lastPathComponent` our way past them) so the result can never
        // contain a "/" that `appendingPathComponent` — or any later
        // consumer — could reinterpret as introducing another path level.
        // macOS/iOS use "/" exclusively as the filesystem separator, so a
        // backslash isn't itself dangerous there, but it's stripped too
        // for defense in depth (a Windows-authored sender, or a future
        // consumer on another platform). NUL truncates C-string paths in
        // some APIs, so it's stripped as well.
        let stripped = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\0", with: "_")
        // Drop leading dots: with no surviving separator a bare ".." can't
        // actually traverse, but stripping it keeps the result from
        // reading as a parent-dir reference, and prevents an attacker (or
        // an innocent sender) from landing a hidden dotfile.
        let trimmed = String(stripped.drop { $0 == "." })
        let truncated = String(trimmed.prefix(maxLength))
        return truncated.isEmpty ? fallback : truncated
    }
}
