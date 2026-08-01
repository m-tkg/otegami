import Foundation

/// Task #42「アバター診断」: displays a raw HTTP error body snippet
/// (`GooglePeopleFetchDiagnostics.errorBodySnippet`) on-screen so a single
/// screenshot is enough to diagnose a failure. Google's error bodies
/// occasionally echo back the caller's own email address (e.g. some 403
/// bodies include the authenticated user's address in a "reason" string);
/// this masks anything that looks like an email address before display so a
/// screenshot the user sends along with a bug report doesn't leak it.
public enum GooglePeopleDiagnosticsFormatting {
    /// Replaces the local part of every email-address-shaped substring in
    /// `text` with `***`, keeping the `@domain` (useful for spotting *which*
    /// service an error body is complaining about without exposing whose
    /// address it is). Not a full RFC 5322 validator — a conservative
    /// `local@domain.tld`-shaped pattern is enough for this diagnostic
    /// display purpose; false negatives (an unusual address shape slipping
    /// through unmasked) are more likely than false positives here, which is
    /// the safer direction to err in for a masking function.
    public static func maskEmailAddresses(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#) else {
            return text
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        var result = text
        let matches = regex.matches(in: text, range: fullRange).reversed()
        for match in matches {
            guard let range = Range(match.range, in: result) else { continue }
            let matched = String(result[range])
            guard let atIndex = matched.firstIndex(of: "@") else { continue }
            let domain = matched[atIndex...]
            result.replaceSubrange(range, with: "***\(domain)")
        }
        return result
    }
}
