import Foundation

/// Strips reply/forward prefixes ("Re:", "Fwd:", "返信:", full-width variants,
/// counters like "Re[2]:") from a subject line so threading logic can compare
/// subjects for equivalence regardless of how many times a message bounced
/// back and forth.
public enum SubjectNormalizer {
    /// Returns `subject` with all leading reply/forward prefixes removed and
    /// full-width Latin letters/punctuation folded to their half-width form.
    public static func normalize(_ subject: String) -> String {
        // Fold full-width forms ("Ｒｅ：", "Ｆｗｄ：") to half-width ("Re:",
        // "Fwd:") first, so a single prefix pattern matches both. This only
        // affects Latin letters/digits/ASCII punctuation in the Halfwidth and
        // Fullwidth Forms block; CJK text is untouched.
        var current = subject.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? subject

        while true {
            let stripped = stripLeadingPrefix(from: current)
            if stripped == current {
                break
            }
            current = stripped
        }

        return current.trimmingCharacters(in: .whitespaces)
    }

    /// Matches one leading reply/forward marker, an optional counter
    /// (`[2]` / `(2)`), a colon (half-width or full-width, already folded
    /// above), and any surrounding whitespace.
    private static let prefixRegex: NSRegularExpression = {
        let pattern = #"^\s*(?:re|fwd?|返信|転送)(?:\s*[\[(]\d+[\])])?\s*[:：]\s*"#
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func stripLeadingPrefix(from subject: String) -> String {
        let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
        guard let match = prefixRegex.firstMatch(in: subject, options: [], range: range),
              match.range.location == 0,
              let matchRange = Range(match.range, in: subject)
        else {
            return subject
        }
        return String(subject[matchRange.upperBound...])
    }
}
