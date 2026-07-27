import SwiftUI
import OtegamiStore

/// The one-line summary for a single message: sender (+ avatar), a snippet,
/// date, and a disclosure/forward chevron. Originally `ThreadDetailView`'s
/// private `ThreadMessageSummaryRow` (the collapsed/about-to-collapse row
/// inside its accordion); pulled into its own shared file and generalized
/// via `Mode` — 画面構造改修バッチ (Task #33, 1) reuses the exact same row
/// look for `ThreadSelectionView`'s "which message do you want to open"
/// list (指示: 「スレッド選択画面の行は一覧と同等の情報 — アイコン・プレビュー・
/// 時刻」), rather than hand-rolling a second, visually-diverging row for
/// what is fundamentally the same "one message, one line" content.
///
/// `mode` drives the three things that differ between the two call sites:
/// - the leading accent rail + background tint (`ThreadDetailView`'s
///   accordion highlights whichever message is currently expanded; a
///   selection-list row has no such "currently open" concept, so it's
///   always neutral)
/// - whether the snippet shows (accordion: only while collapsed, since the
///   expanded `MessageView` right below already shows the real body;
///   selection list: always, since there's no expanded body to make it
///   redundant)
/// - the trailing chevron's direction (accordion: up/down, matching
///   expand/collapse; selection list: `chevron.right`, matching "tap to
///   push a new screen" the same way every other list row in this app
///   does)
struct ThreadMessageSummaryRow: View {
    let message: MessageRecord
    let accountId: String?
    /// D「アカウントのラベル色を変更可能に」: `AccountRecord.labelColorKey` for
    /// `accountId`, forwarded to `SenderAvatar` as-is.
    let accountLabelColorKey: String?
    let mode: Mode

    enum Mode {
        /// `ThreadDetailView`'s accordion row — `isExpanded` mirrors
        /// exactly what that view's `expandedMessageId == messageId` check
        /// already computed before this type existed.
        case accordion(isExpanded: Bool)
        /// `ThreadSelectionView`'s plain "pick a message" list — no
        /// expand/collapse state at all, so every row renders the same way
        /// regardless of its neighbors.
        case list
    }

    @AppStorage(ListDisplaySettingsStore.showAvatarInDetailKey) private var showAvatar = ListDisplaySettingsStore.defaultShowAvatarInDetail

    private var isExpanded: Bool {
        if case .accordion(let expanded) = mode { return expanded }
        return false
    }

    private var showsSnippet: Bool {
        if case .accordion(let expanded) = mode { return !expanded }
        return true
    }

    private var chevronSystemImage: String {
        switch mode {
        case .accordion(let expanded): expanded ? "chevron.up" : "chevron.down"
        case .list: "chevron.right"
        }
    }

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
            // content horizontally when it appears/disappears. Always
            // clear for `.list` — a selection-list row never has a
            // "currently open" state to highlight.
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
        // siblings. A `.list` row is never "expanded", so it always gets
        // the plain `paleBase` tint.
        .background(isExpanded ? OtegamiColor.paleBaseStrong : OtegamiColor.paleBase)
        .contentShape(Rectangle())
    }

    private var senderText: String {
        guard let from = message.fromAddresses.first else { return "(unknown)" }
        return from.name?.isEmpty == false ? from.name! : from.address
    }
}
