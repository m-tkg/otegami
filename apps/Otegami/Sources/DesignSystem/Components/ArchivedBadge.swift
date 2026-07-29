import SwiftUI

/// Task #151 (「アーカイブ済みの可視化」): a small, understated pill flagging
/// an archived message/thread in the message viewer's compressed header
/// (`MessageHeaderCompactView`) — mirrors `HTMLBadge`/`ENBadge`'s exact
/// shape (flat/square per the design system's corner-radius-0 rule) so it
/// reads as one more sibling badge in that header row rather than a
/// bespoke, differently-styled element. Kept separate from the one-line
/// list-row indicator (`ThreadRowView`'s `archivebox` icon,
/// `summary.isArchived`) — that one sits in a trailing icon cluster with no
/// room for label text, while this header row already hosts `HTMLBadge` as
/// plain text.
public struct ArchivedBadge: View {
    public init() {}

    public var body: some View {
        Text("アーカイブ済み")
            .font(OtegamiFont.badge())
            .foregroundStyle(OtegamiColor.inkSecondary)
            .padding(.horizontal, OtegamiSpacing.xs)
            .padding(.vertical, 2)
            .background(OtegamiColor.paleBase)
            .clipShape(Rectangle())
            .accessibilityIdentifier("messageDetail.archivedBadge")
            .accessibilityLabel(Text("アーカイブ済み"))
    }
}
