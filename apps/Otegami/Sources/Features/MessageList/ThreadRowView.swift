import SwiftUI
import OtegamiStore

/// The 1d list row: `AccountColorRail` + `UnreadDot` + three lines (差出人 /
/// 件名 / プレビュー) + a trailing account-name label, all through
/// `DesignSystem` tokens rather than bare SwiftUI styling. Replaces the
/// previous `ThreadRow` (plain `.headline`/`.subheadline`/`.caption`
/// system-font row with a bare `Circle` unread dot) — this type is the one
/// design-phase-2 file that both `MessageListView` (the mail list) and
/// `SearchTabView` (iOS's dedicated search tab) share, so a thread reads
/// identically in both places.
///
/// Split into this thin top-level view plus `ThreadRowTextStack`/
/// `ThreadRowTrailing` below — the same "keep each piece a small,
/// independently-type-checked `View`" discipline `docs/ci.md` documents for
/// every other row-shaped view in this app (`SidebarView`'s `MailboxRow`,
/// the pre-existing `MessageListRow`/`ThreadMessageRow`), applied
/// preemptively here rather than waiting for a CI timeout to prove it's
/// needed.
struct ThreadRowView: View {
    /// B4 「送信者のプロフィールアイコンの表示」/「本文プレビューの行数」— see
    /// `ListDisplaySettingsStore`'s doc comment on why these are read
    /// directly via `@AppStorage` rather than threaded in as parameters.
    @AppStorage(ListDisplaySettingsStore.showAvatarKey) private var showAvatar = ListDisplaySettingsStore.defaultShowAvatar
    @AppStorage(ListDisplaySettingsStore.previewLineCountKey) private var previewLineCountRaw = ListDisplaySettingsStore.defaultPreviewLineCount.rawValue
    private var previewLineCount: PreviewLineCount { PreviewLineCount(rawValue: previewLineCountRaw) ?? ListDisplaySettingsStore.defaultPreviewLineCount }

    let summary: ThreadSummary
    /// `nil` in a context where showing an account label wouldn't mean
    /// anything (a single already-selected mailbox) — see
    /// `showsAccountAccent`.
    let accountDisplayName: String?
    /// 1d: "統合受信トレイではアカウント色罫線が意味を持ち、単一メールボックス表示
    /// では不要（または控えめ）にする" — `true` for the unified inbox (every row
    /// can belong to a different account, so the rail/label disambiguate at
    /// a glance) and iOS's search tab (same reasoning: results can span
    /// accounts); `false` once a single specific mailbox is selected via
    /// the folder sheet, where every row already shares one account and
    /// the rail would be redundant color noise.
    let showsAccountAccent: Bool
    /// 1h: true once long-press has entered bulk-selection mode — swaps the
    /// leading unread dot for a checkbox.
    var isSelecting: Bool = false
    var isSelected: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if showsAccountAccent {
                AccountColorRail(accountId: summary.thread.accountId)
            }
            HStack(alignment: .top, spacing: OtegamiSpacing.sm) {
                leadingIndicator
                if showAvatar, !isSelecting {
                    SenderAvatar(
                        displayName: summary.latestMessage?.fromAddresses.first?.name,
                        address: summary.latestMessage?.fromAddresses.first?.address ?? "",
                        accountId: summary.thread.accountId,
                        diameter: 28
                    )
                }
                ThreadRowTextStack(summary: summary, previewLineCount: previewLineCount)
                Spacer(minLength: OtegamiSpacing.sm)
                ThreadRowTrailing(
                    summary: summary,
                    accountDisplayName: showsAccountAccent ? accountDisplayName : nil
                )
            }
            .padding(.horizontal, OtegamiSpacing.md)
            .padding(.vertical, OtegamiSpacing.sm)
        }
        .background(isSelected ? OtegamiColor.paleBaseStrong : OtegamiColor.surface)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        if isSelecting {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(isSelected ? OtegamiColor.accent : OtegamiColor.inkTertiary)
                .padding(.top, 2)
                .accessibilityHidden(true)
        } else {
            UnreadDot(isUnread: summary.thread.unreadCount > 0)
                .padding(.top, 6)
        }
    }
}

/// 差出人 / 件名 / プレビューの3行 — `ThreadRowView.body`から切り出した独立
/// `View`（`docs/ci.md`参照）。
private struct ThreadRowTextStack: View {
    let summary: ThreadSummary
    /// B4 「本文プレビューの行数」— `.none` (0) hides the preview line
    /// entirely; otherwise it's passed straight through as `.lineLimit(_:)`.
    let previewLineCount: PreviewLineCount

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(senderText)
                .font(OtegamiFont.headline())
                .foregroundStyle(OtegamiColor.ink)
                .lineLimit(1)
            HStack(spacing: OtegamiSpacing.xs) {
                Text(subjectText)
                    .font(OtegamiFont.subheadline())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .lineLimit(1)
                if summary.latestMessage?.hasAttachments == true {
                    Image(systemName: "paperclip")
                        .font(.caption)
                        .foregroundStyle(OtegamiColor.inkTertiary)
                        .accessibilityHidden(true)
                }
                if summary.thread.messageCount > 1 {
                    Text("\(summary.thread.messageCount)")
                        .font(OtegamiFont.badge())
                        .foregroundStyle(OtegamiColor.inkSecondary)
                        .padding(.horizontal, OtegamiSpacing.xs)
                        .background(OtegamiColor.paleBase)
                        .accessibilityIdentifier("messageList.row.\(summary.id).countBadge")
                }
            }
            if previewLineCount != .none, let snippet = summary.latestMessage?.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkTertiary)
                    .lineLimit(previewLineCount.rawValue)
            }
        }
    }

    private var senderText: String {
        guard let from = summary.latestMessage?.fromAddresses.first else { return "(unknown)" }
        return from.name?.isEmpty == false ? from.name! : from.address
    }

    private var subjectText: String {
        let subject = summary.latestMessage?.subject ?? summary.thread.normalizedSubject
        return subject?.isEmpty == false ? subject! : "(件名なし)"
    }
}

/// 右端の日付 + ピン留めインジケータ + （統合受信トレイのみ）アカウント名ラベル。
private struct ThreadRowTrailing: View {
    let summary: ThreadSummary
    let accountDisplayName: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: OtegamiSpacing.xs) {
            if summary.thread.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(OtegamiColor.accent)
                    .accessibilityIdentifier("messageList.row.\(summary.id).pinnedIndicator")
            }
            if let date = summary.thread.lastMessageDate {
                Text(date, style: .date)
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkTertiary)
            }
            if let accountDisplayName {
                Text(accountDisplayName)
                    .font(OtegamiFont.badge())
                    .foregroundStyle(OtegamiColor.inkTertiary)
                    .lineLimit(1)
                    .accessibilityIdentifier("messageList.row.\(summary.id).accountLabel")
            }
        }
    }
}
