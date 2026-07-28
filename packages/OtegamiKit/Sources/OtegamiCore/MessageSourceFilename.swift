import Foundation

/// Task #103 ("ソースを表示" → シェアで `.eml` として書き出す): derives a
/// filesystem/`ShareLink`-safe filename from a message's subject line.
/// Pure function, kept in `OtegamiCore` ("Linux-compatible model & pure-
/// logic layer. No dependencies." per `Package.swift`) so it's covered by
/// `swift test` (`make test`) — `apps/Otegami` has no unit test target
/// (only XCUITest, which needs a simulator), the same reason
/// `MessageToolbarPreferencesCoding` lives here rather than alongside the
/// app-side view that actually calls it.
///
/// Distinct from `SyncEngine.AttachmentFetcher.sanitizeFilename`: that one
/// only strips path separators/leading dots to keep an untrusted IMAP-
/// server-supplied filename from escaping its intended storage directory,
/// preserving everything else (symbols, punctuation) verbatim. This one is
/// building a filename a user will actually *see* in a share sheet from
/// free-form subject text, so it strips symbols/punctuation outright
/// rather than just the handful that are actually dangerous.
public enum MessageSourceFilename {
    /// How many characters of the (sanitized) subject survive before
    /// truncation — generous enough for a real subject line, short enough
    /// to stay well clear of any filesystem's own path-length limit once
    /// combined with the rest of a temp-directory path.
    public static let maxLength = 80

    /// - Parameters:
    ///   - subject: the message's subject. `nil`, empty, or entirely
    ///     symbols/punctuation (nothing survives filtering) all fall back
    ///     to `"message"`.
    ///   - fileExtension: appended with a `.` separator; default `"eml"`
    ///     (the RFC822 raw-source case this type exists for).
    public static func sanitized(subject: String?, fileExtension: String = "eml") -> String {
        let base = subject ?? ""
        // Keep letters (any script — a Japanese subject is the common
        // case here, not just ASCII), digits, and whitespace (including
        // newlines/tabs — collapsed to single spaces below rather than
        // dropped outright, so e.g. a subject with an embedded line break
        // still reads as space-separated words); drop everything else
        // (path separators, punctuation, symbols, control characters, ...)
        // rather than trying to enumerate every character a filesystem or
        // `ShareLink` might choke on individually. `CharacterSet
        // .alphanumerics` covers Unicode general category L* (letters,
        // including Han/Hiragana/Katakana) + Nd (decimal digits).
        let filteredScalars = base.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        let collapsedWhitespace = String(String.UnicodeScalarView(filteredScalars))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let truncated = String(collapsedWhitespace.prefix(maxLength))
        let name = truncated.isEmpty ? "message" : truncated
        return "\(name).\(fileExtension)"
    }
}
