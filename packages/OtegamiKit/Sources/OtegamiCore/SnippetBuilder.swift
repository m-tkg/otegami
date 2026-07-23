import Foundation

/// Builds `message.snippet` (M2): a short, whitespace-normalized preview
/// of a message's plain-text body, for the message list row. Pure/static
/// so it's trivially unit-testable without touching `SyncEngine`/GRDB.
public enum SnippetBuilder {
    /// Collapses all runs of whitespace (including newlines) in `plainText`
    /// to single spaces, trims, and truncates to `maxLength` characters.
    /// `nil`/empty input yields `nil` rather than an empty string, so
    /// callers can tell "no snippet" apart from "snippet happens to be
    /// empty".
    public static func make(from plainText: String?, maxLength: Int = 120) -> String? {
        guard let plainText else { return nil }
        let collapsed = plainText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxLength else { return collapsed }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        return String(collapsed[..<cutoff])
    }
}
