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
    /// anything (a single already-selected mailbox, or a unified inbox
    /// narrowed to one account) — decided by the caller
    /// (`MessageListView.isMultiAccountScope`), independent of
    /// `showsAccountAccent` since Task #87 (4) made the rail itself
    /// unconditional. See `showsAccountAccent`'s doc comment.
    let accountDisplayName: String?
    /// D「アカウントのラベル色を変更可能に」: `AccountRecord.labelColorKey` for
    /// `summary.thread.accountId`, forwarded to `AccountColorRail`/
    /// `SenderAvatar` as-is (`nil` when that account still uses the
    /// automatic assignment). See `OtegamiAccountColor.color(for:override:)`.
    var accountLabelColorKey: String?
    /// 1d: "統合受信トレイではアカウント色罫線が意味を持ち、単一メールボックス表示
    /// では不要（または控えめ）にする" — originally `true` only for the unified
    /// inbox/横断ビュー and `false` for a single specific mailbox, where every
    /// row already shares one account and the rail read as redundant color
    /// noise (see `MessageListView.showsAccountAccent`'s doc comment for
    /// that original reasoning).
    ///
    /// Task #87 (4), real-device feedback ("アカウント絞り込み時も色バー常時
    /// 表示"): `MessageListView.showsAccountAccent` now always returns
    /// `true`, so in practice this parameter is unconditional too — kept
    /// as its own parameter rather than deleted outright so this view
    /// doesn't hardcode that decision itself. The trailing account-name
    /// label is a *separate* decision now, made by the caller via
    /// `accountDisplayName` being `nil` or not — see that property's own
    /// doc comment.
    let showsAccountAccent: Bool
    /// 1h: true once long-press has entered bulk-selection mode — swaps the
    /// leading unread dot for a checkbox.
    var isSelecting: Bool = false
    var isSelected: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if showsAccountAccent {
                AccountColorRail(accountId: summary.thread.accountId, labelColorKey: accountLabelColorKey)
            }
            HStack(alignment: .top, spacing: OtegamiSpacing.sm) {
                leadingIndicator
                if showAvatar, !isSelecting {
                    SenderAvatar(
                        displayName: summary.latestMessage?.fromAddresses.first?.name,
                        address: summary.latestMessage?.fromAddresses.first?.address ?? "",
                        accountId: summary.thread.accountId,
                        labelColorKey: accountLabelColorKey,
                        diameter: 28
                    )
                }
                ThreadRowTextStack(summary: summary, previewLineCount: previewLineCount)
                Spacer(minLength: OtegamiSpacing.sm)
                ThreadRowTrailing(
                    summary: summary,
                    // `showsAccountAccent` is unconditional for
                    // `MessageListView`'s own rows since Task #87 (4) — that
                    // caller already passes `nil` for `accountDisplayName`
                    // itself where the label shouldn't show (see this
                    // property's own doc comment), so this `? :` is a no-op
                    // there. Left in place (rather than removed) because
                    // `SearchScreenView`'s own `showsAccountAccent` still
                    // *is* conditional and still relies on this exact line
                    // to hide the label — removing it would silently change
                    // that unrelated screen's behavior too.
                    accountDisplayName: showsAccountAccent ? accountDisplayName : nil
                )
            }
            .padding(.horizontal, OtegamiSpacing.md)
            .padding(.vertical, OtegamiSpacing.sm)
        }
        // 表示・操作改善バッチ「カード状表示」→ 実機フィードバック第2弾「C カード
        // デザインの変更」: each row reads as its own "面" (card) — no
        // outline, just `OtegamiColor.surface`/`.paleBaseStrong`
        // (`otegamiCardBackground(_:cornerRadius:)`'s doc comment covers the
        // removed-stroke decision). macOS keeps the original rounded corner
        // (`rowCornerRadius`) with the gap between cards coming from
        // `MessageListRow`'s `.listRowInsets` margin, unchanged.
        //
        // Task #67: iOS went full-width ("メール一覧のカードの幅を画面幅に
        // 広げて欲しい") — `MessageListRow`/`SearchScreenView` now zero out
        // `.listRowInsets` on iOS so the card (and `AccountColorRail`) reach
        // the screen's true left/right edges. A rounded corner sitting
        // flush against the screen edge reads as clipped/broken rather than
        // as a corner, so `rowCornerRadius` drops to `OtegamiRadius.none`
        // there — and since the inter-row *margin* that used to double as
        // the visual separator is gone too, `.otegamiRowDivider()` (a 1pt
        // `dividerSubtle` hairline, previously unused since the card layout
        // replaced it — see that function's own doc comment) comes back for
        // iOS only to keep rows visually distinct. See
        // `docs/design-system.md`'s list layout section for the full
        // decision record.
        .otegamiCardBackground(isSelected ? OtegamiColor.paleBaseStrong : OtegamiColor.surface, cornerRadius: rowCornerRadius)
        #if os(iOS)
        .otegamiRowDivider()
        #endif
        .contentShape(Rectangle())
    }

    /// See the `Task #67` doc comment on `body` above.
    private var rowCornerRadius: CGFloat {
        #if os(iOS)
        OtegamiRadius.none
        #else
        OtegamiRadius.card
        #endif
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

/// 右端の日付 + スレッド件数バッジ + ピン留めインジケータ + （統合受信トレイ
/// のみ）アカウント名ラベル。
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
                OtegamiDateFormat.listRowText(for: date)
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkTertiary)
            }
            // Task #136 (実機フィードバック「スレッド表示 ON の本文画面を
            // アコーディオンに戻してほしい」の一覧側の対): 件名の隣にあった
            // 数字だけのバッジ (画面構造改修バッチ以来) を、日時の下の
            // 「スレッドアイコン + 件数」に置き換えた — 本文画面が
            // アコーディオンに戻り複数通あることが本文側でも見えるように
            // なったので、一覧側も「これは複数通ある」ことをアイコンで
            // 明示する。`summary.thread.messageCount`はB3フラット表示
            // (`ThreadSummary.init(flatMessage:accountId:)`) だと常に1に
            // 固定されるので、フラットモードでは自然にこのバッジ自体が
            // 出ない (`ThreadQuery`側の変更は不要 — `ThreadRecord
            // .messageCount`はどちらのモードでも既に正しい値を持っている)。
            if summary.thread.messageCount > 1 {
                Label {
                    Text("\(summary.thread.messageCount)")
                } icon: {
                    Image(systemName: "square.stack")
                }
                .labelStyle(.otegamiThreadCount)
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkTertiary)
                .accessibilityIdentifier("messageList.row.\(summary.id).countBadge")
                .accessibilityLabel(Text("\(summary.thread.messageCount)通のスレッド"))
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

/// `ThreadRowTrailing`の件数バッジ専用の`LabelStyle`— 既定の`Label`は
/// アイコン→テキストの間隔がやや広く、他の`OtegamiSpacing`基準の詰まった
/// レイアウトの中で浮いて見えたため、間隔だけ`OtegamiSpacing.xs`に詰める。
private struct OtegamiThreadCountLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: OtegamiSpacing.xs) {
            configuration.icon
                .font(.caption2)
            configuration.title
        }
    }
}

private extension LabelStyle where Self == OtegamiThreadCountLabelStyle {
    static var otegamiThreadCount: OtegamiThreadCountLabelStyle { OtegamiThreadCountLabelStyle() }
}
