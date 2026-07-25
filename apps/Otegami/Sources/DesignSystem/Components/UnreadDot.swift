import SwiftUI

/// The unread indicator dot from list layout 1d ("未読ドット（左）"). A
/// small filled circle in `OtegamiColor.accent`; renders nothing (but
/// still reserves its layout space, so rows don't visually shift between
/// read/unread) when `isUnread` is `false`, so callers can use it
/// unconditionally in a row's leading `HStack` rather than branching.
public struct UnreadDot: View {
    /// 8pt — small enough to read as a status dot, not a bullet.
    public static let diameter: CGFloat = 8

    private let isUnread: Bool

    public init(isUnread: Bool) {
        self.isUnread = isUnread
    }

    public var body: some View {
        Circle()
            .fill(isUnread ? OtegamiColor.accent : Color.clear)
            .frame(width: Self.diameter, height: Self.diameter)
            .accessibilityHidden(true)
    }
}
