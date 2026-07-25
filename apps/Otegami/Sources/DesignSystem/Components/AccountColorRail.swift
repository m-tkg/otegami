import SwiftUI

/// The 3px account-color left rail from list layout 1d ("標準3行＋アカウ
/// ント色の左罫（3px）"). A thin filled rectangle meant to sit at the
/// leading edge of a message row, colored via `OtegamiAccountColor`.
///
/// A plain `View`, not a `.overlay`/border modifier, so callers can lay it
/// out explicitly in an `HStack` alongside the row's own content — a
/// border-style modifier would tie its thickness to the row's own frame
/// insets, which message rows (with their own internal padding) don't
/// want.
public struct AccountColorRail: View {
    /// 3pt, per the handoff's list-layout spec (1d). Not `OtegamiStroke`
    /// (that enum is for 1–2pt dividers) since this is a distinct,
    /// slightly wider "swatch" stroke used nowhere else.
    public static let width: CGFloat = 3

    private let accountId: String

    public init(accountId: String) {
        self.accountId = accountId
    }

    public var body: some View {
        Rectangle()
            .fill(OtegamiAccountColor.color(for: accountId))
            .frame(width: Self.width)
            .accessibilityHidden(true)
    }
}
