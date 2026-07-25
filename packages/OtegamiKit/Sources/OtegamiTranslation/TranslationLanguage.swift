import Foundation

/// The two languages otegami's translation feature currently moves text
/// between. Deliberately not a free-form BCP-47 wrapper — every
/// `TranslationService` call site in this codebase asks for exactly one of
/// these two directions (English mail read in Japanese, a Japanese reply
/// drafted in English), and keeping the type closed lets a switch over it
/// stay exhaustive instead of needing a `default:` that could silently
/// accept an unsupported pair. `MessageLanguageDetector`, which *does* need
/// to recognize languages outside this pair (to decide whether a message
/// counts as "English" at all), reports its own result as a plain BCP-47
/// string rather than this type.
public enum TranslationLanguage: String, Sendable, Codable, Equatable, CaseIterable {
    case english = "en"
    case japanese = "ja"

    /// A short human-readable label, for log lines and doc-comment-adjacent
    /// debugging — not user-facing copy (that belongs to the UI phase, in
    /// whatever localization mechanism it settles on).
    public var displayName: String {
        switch self {
        case .english: "English"
        case .japanese: "Japanese"
        }
    }
}
