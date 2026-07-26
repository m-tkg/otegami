import SwiftUI

/// B4/B5 「送信者のプロフィールアイコン」: a circular avatar showing the sender's
/// initials on a per-account-colored background (`OtegamiAccountColor`) —
/// deliberately **never** fetches an image from any external service (this
/// task's explicit privacy constraint: a mail client shouldn't leak "this
/// address was opened" to a third-party avatar/gravatar host just by
/// rendering a list row). Used by `ThreadRowView` (B4, the message list) and
/// `MessageView`'s per-message header (B5, the thread detail screen).
public struct SenderAvatar: View {
    private let displayName: String?
    private let address: String
    private let accountId: String
    private let diameter: CGFloat

    /// - Parameters:
    ///   - displayName: the sender's display name if the message had one
    ///     (`EmailAddress.name`); initials are derived from this when
    ///     present, falling back to `address` otherwise.
    ///   - address: the sender's email address — always used for the
    ///     background color's stability (`OtegamiAccountColor.color(for:)`
    ///     keys off the *account* this message belongs to, not the sender,
    ///     so every avatar for messages in the same account reads
    ///     consistently even though the initials differ per sender) and as
    ///     the initials fallback.
    ///   - accountId: which account this message belongs to — the avatar's
    ///     background color, not the sender's own identity, so a user
    ///     visually associates "this row/header is in account X" the same
    ///     way `AccountColorRail`/`AccountFilterChip` already do.
    ///   - diameter: 28pt in the list row (`ThreadRowView`, close to a
    ///     typical Mail-app avatar size at this app's row density), 36pt in
    ///     the detail header (`MessageView`, given more room next to the
    ///     larger headline-weight sender name there).
    public init(displayName: String?, address: String, accountId: String, diameter: CGFloat) {
        self.displayName = displayName
        self.address = address
        self.accountId = accountId
        self.diameter = diameter
    }

    public var body: some View {
        Circle()
            .fill(OtegamiAccountColor.color(for: accountId))
            .frame(width: diameter, height: diameter)
            .overlay {
                Text(initials)
                    .font(.system(size: diameter * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    /// Up to 2 characters: the first letter of each of the first two
    /// whitespace-separated words in `displayName` (matches how "First
    /// Last" style display names read as "FL"), or just the first
    /// character of a single-word name/the address's local part when
    /// there's nothing to split — always uppercased, and always at least
    /// one character unless both `displayName` and `address` are somehow
    /// empty (a defensive fallback, not expected in practice: every synced
    /// message has a non-empty `from` address).
    private var initials: String {
        let source = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? displayName!
            : String(address.split(separator: "@").first ?? Substring(address))
        let words = source.split(separator: " ").filter { !$0.isEmpty }
        if words.count >= 2, let first = words[0].first, let second = words[1].first {
            return String([first, second]).uppercased()
        }
        if let first = source.first {
            return String(first).uppercased()
        }
        return "?"
    }
}
