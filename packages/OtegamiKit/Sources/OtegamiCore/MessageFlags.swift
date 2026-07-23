/// IMAP message flags (RFC 3501 §2.3.2), represented as a bitset so they can
/// be stored as a single integer column and compared/merged cheaply.
public struct MessageFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// `\Seen`
    public static let seen = MessageFlags(rawValue: 1 << 0)
    /// `\Answered`
    public static let answered = MessageFlags(rawValue: 1 << 1)
    /// `\Flagged`
    public static let flagged = MessageFlags(rawValue: 1 << 2)
    /// `\Draft`
    public static let draft = MessageFlags(rawValue: 1 << 3)
    /// `\Deleted`
    public static let deleted = MessageFlags(rawValue: 1 << 4)
}
