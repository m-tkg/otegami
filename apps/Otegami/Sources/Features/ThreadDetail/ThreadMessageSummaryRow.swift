import SwiftUI
import OtegamiStore

/// The one-line summary for a single message: sender (+ avatar), a snippet,
/// date, and a disclosure chevron. Originally `ThreadDetailView`'s private
/// `ThreadMessageSummaryRow` (the collapsed/about-to-collapse row inside its
/// accordion); pulled into its own shared file so both `ThreadDetailView`
/// and (画面構造改修バッチ Task #33, 1 → Task #136 で削除) the now-gone
/// `ThreadSelectionView` could reuse it. Task #136 (実機フィードバック
/// 「アコーディオンに戻してほしい」) removed `ThreadSelectionView` and, with
/// it, this row's only other caller — collapsing the `Mode` enum
/// (`.accordion(isExpanded:)`/`.list`) that used to switch between them back
/// down to a plain `isExpanded: Bool`, `ThreadDetailView`'s own accordion
/// row shape. See `docs/design-system.md`'s Task #136 節 for the full
/// history.
struct ThreadMessageSummaryRow: View {
    let message: MessageRecord
    let accountId: String?
    /// D「アカウントのラベル色を変更可能に」: `AccountRecord.labelColorKey` for
    /// `accountId`, forwarded to `SenderAvatar` as-is.
    let accountLabelColorKey: String?
    /// `ThreadDetailView`'s `expandedMessageId == messageId` check, forwarded
    /// straight through — drives three things: the leading accent rail +
    /// background tint, whether the snippet shows (only while collapsed,
    /// since the expanded `MessageView` right below already shows the real
    /// body), and the trailing chevron's direction (up/down, matching
    /// expand/collapse).
    let isExpanded: Bool

    @AppStorage(ListDisplaySettingsStore.showAvatarInDetailKey) private var showAvatar = ListDisplaySettingsStore.defaultShowAvatarInDetail

    private var showsSnippet: Bool { !isExpanded }

    private var chevronSystemImage: String { isExpanded ? "chevron.up" : "chevron.down" }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 実機フィードバック第2弾 (E)「展開中メッセージの視覚的強調」: a 3pt
            // `OtegamiColor.accent` leading rail, present only on the
            // expanded accordion row — the same width/treatment
            // `AccountColorRail` uses for its own "this row means something
            // specific" signal, reused here for "this is the one row the
            // footer toolbar acts on" instead of "this row's account".
            // Laid out as a real (if empty-when-collapsed) leading element
            // rather than an `.overlay`, so it never shifts this row's own
            // content horizontally when it appears/disappears.
            Rectangle()
                .fill(isExpanded ? OtegamiColor.accent : Color.clear)
                .frame(width: AccountColorRail.width)
                .accessibilityHidden(true)
            HStack(alignment: .top, spacing: OtegamiSpacing.sm) {
                UnreadDot(isUnread: !message.flags.contains(.seen))
                    .padding(.top, 6)
                if showAvatar, let accountId {
                    SenderAvatar(
                        displayName: message.fromAddresses.first?.name,
                        address: message.fromAddresses.first?.address ?? "",
                        accountId: accountId,
                        labelColorKey: accountLabelColorKey,
                        diameter: 24
                    )
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(senderText)
                        .font(OtegamiFont.headline())
                        .foregroundStyle(OtegamiColor.ink)
                        .lineLimit(1)
                    if showsSnippet, let snippet = message.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(OtegamiFont.caption())
                            .foregroundStyle(OtegamiColor.inkSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: OtegamiSpacing.sm)
                OtegamiDateFormat.listRowText(for: message.date ?? message.internalDate)
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkTertiary)
                Image(systemName: chevronSystemImage)
                    .font(.caption)
                    .foregroundStyle(OtegamiColor.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, OtegamiSpacing.sm)
            // `.sm` here, not `.lg` — the leading accent rail
            // (`AccountColorRail.width`, 3pt) accounts for part of the
            // "extra indent vs. the top-level list row" visual language
            // (rail width + `.sm` ≈ `.lg`), so the total indent reads about
            // the same regardless of mode/state (the rail's *width* is
            // always reserved; only its *color* toggles).
            .padding(.leading, OtegamiSpacing.sm)
            .padding(.trailing, OtegamiSpacing.md)
        }
        // 実機フィードバック第2弾 (E): `paleBaseStrong` (the same "強い強調地"
        // token `ThreadRowView`'s selected-row state uses) instead of the
        // collapsed default `paleBase` — see the accent rail comment above
        // for why the expanded accordion row specifically needs to read as
        // visually distinct from its (also `paleBase`-tinted) collapsed
        // siblings.
        .background(isExpanded ? OtegamiColor.paleBaseStrong : OtegamiColor.paleBase)
        .contentShape(Rectangle())
    }

    private var senderText: String {
        guard let from = message.fromAddresses.first else { return "(unknown)" }
        return from.name?.isEmpty == false ? from.name! : from.address
    }
}
