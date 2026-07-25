#if DEBUG
import SwiftUI

/// Live instances of every basic component in `Components/`, including a
/// mock message row that combines several of them the way a real 1d row
/// would (`AccountColorRail` + `UnreadDot` + subject/preview text +
/// `ENBadge` + `.otegamiRowDivider()`).
struct CatalogComponentSection: View {
    @State private var selectedChip = "全部"
    private let chipTitles = ["全部", "仕事", "個人"]

    var body: some View {
        CatalogSection(title: "Components") {
            chipRow
            Divider().opacity(0)
            HStack(spacing: OtegamiSpacing.lg) {
                labeledUnreadDot(isUnread: true, label: "unread")
                labeledUnreadDot(isUnread: false, label: "read")
                ENBadge()
            }
            CatalogMockMessageRow(accountId: "work@example.com", isUnread: true, isEnglish: true)
            CatalogMockMessageRow(accountId: "personal@example.com", isUnread: false, isEnglish: false)
        }
    }

    private var chipRow: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            ForEach(chipTitles, id: \.self, content: chip)
        }
    }

    private func chip(title: String) -> some View {
        AccountFilterChip(title: title, isSelected: selectedChip == title) {
            selectedChip = title
        }
    }

    private func labeledUnreadDot(isUnread: Bool, label: String) -> some View {
        HStack(spacing: OtegamiSpacing.xs) {
            UnreadDot(isUnread: isUnread)
            Text(label)
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkSecondary)
        }
    }
}

private struct CatalogMockMessageRow: View {
    let accountId: String
    let isUnread: Bool
    let isEnglish: Bool

    var body: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            AccountColorRail(accountId: accountId)
            UnreadDot(isUnread: isUnread)
            VStack(alignment: .leading, spacing: 2) {
                subjectLine
                Text("本文プレビューがここに入ります。")
                    .font(OtegamiFont.subheadline())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, OtegamiSpacing.sm)
        .otegamiRowDivider()
    }

    private var subjectLine: some View {
        HStack(spacing: OtegamiSpacing.xs) {
            Text("件名のサンプル Sample Subject")
                .font(OtegamiFont.headline())
                .foregroundStyle(OtegamiColor.ink)
                .lineLimit(1)
            if isEnglish {
                ENBadge()
            }
        }
    }
}
#endif
