import SwiftUI
import OtegamiStore

/// Task #92 (アカウントダイジェスト画面): one row of `AccountDigestView` —
/// `AccountColorRail` (1d の3pxアカウント色罫線、既存トークンをそのまま
/// 再利用) + アカウント表示名 + 未読/件数バッジ、続けて直近2-3件の「差出人・
/// 件名」プレビュー行。タップでそのアカウントに絞り込んだ一覧へ
/// (`AccountDigestView.onSelect`、1a のアカウント絞り込みチップと同じ
/// `MailScreenView.accountFilter`機構を再利用)。
///
/// スワイプは`MessageListRow`と同じ`SwipeActionSettingsStore`の4スロット
/// (leading/trailing × short/long) を読むが、あの行の自前`DragGesture`
/// (しきい値を超えた瞬間に確認無しで発火) はここでは採用していない —
/// この行のスワイプは「表示中フォルダの全メールを一括処理」という重い操作
/// で、`AccountDigestView`側が必ず確認ダイアログを挟む(仕様「件数が多い
/// 操作なので確認ダイアログを出し」)以上、SwiftUI標準の`.swipeActions`
/// (ボタンが現れてタップで実行) で十分——むしろこの画面専用にもう一つ
/// カスタムドラッグジェスチャーを書く方が無駄になる。macOS には
/// `.swipeActions`が無いため、`MessageListRow`のmacOS分岐と同じ理由で
/// コンテキストメニューに同じアクションを並べる。
struct AccountDigestRow: View {
    /// `MessageListRow`と全く同じ4キー — 「スワイプ割り当て設定に従う」
    /// という仕様どおり、単一スレッド用の設定をこの一括操作にもそのまま
    /// 転用する(この画面専用の別設定は増やさない)。
    @AppStorage(SwipeActionSettingsStore.leadingShortActionKey) private var leadingShortRaw = SwipeActionSettingsStore.defaultLeadingShort.rawValue
    @AppStorage(SwipeActionSettingsStore.leadingLongActionKey) private var leadingLongRaw = SwipeActionSettingsStore.defaultLeadingLong.rawValue
    @AppStorage(SwipeActionSettingsStore.trailingShortActionKey) private var trailingShortRaw = SwipeActionSettingsStore.defaultTrailingShort.rawValue
    @AppStorage(SwipeActionSettingsStore.trailingLongActionKey) private var trailingLongRaw = SwipeActionSettingsStore.defaultTrailingLong.rawValue

    let digest: AccountDigest
    /// `AccountFilterChip.label`/`AccountGroupSectionHeader.accountDisplayName`
    /// (廃止済み) と同じ理由で`Text(verbatim:)`のみで扱う — 表示名がメール
    /// アドレスそのものの場合、`LocalizedStringKey`経由だとSwiftUIが自動
    /// リンク化し、タップで`mailto:`が開く実機バグを踏む。
    let accountDisplayName: String
    let labelColorKey: String?
    let onSelect: () -> Void
    /// 実行前の確認ダイアログは`AccountDigestView`側が持つ(複数行から
    /// 一箇所にまとめるほうが`.confirmationDialog`の状態管理が単純になる
    /// ため) — このボタン/コンテキストメニュー行は要求するだけ。
    let onRequestBulkAction: (SwipeAction) -> Void

    var body: some View {
        Button(action: onSelect) {
            content
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        #if os(iOS)
        .swipeActions(edge: .leading) {
            ForEach(leadingActions) { action in swipeButton(for: action) }
        }
        .swipeActions(edge: .trailing) {
            ForEach(trailingActions) { action in swipeButton(for: action) }
        }
        #else
        .contextMenu {
            ForEach(SwipeAction.allCases) { action in
                Button {
                    onRequestBulkAction(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
            }
        }
        #endif
        .accessibilityIdentifier("accountDigest.row.\(digest.accountId)")
    }

    #if os(iOS)
    /// 短い/長い が同じアクションに設定されている場合はボタンを1個に
    /// まとめる(`MessageListRow`と違い、ここはドラッグ距離で切り替える
    /// 仕組みが無いので、同じボタンを2つ並べても意味が無い)。
    private var leadingActions: [SwipeAction] { orderedActions(shortRaw: leadingShortRaw, longRaw: leadingLongRaw) }
    private var trailingActions: [SwipeAction] { orderedActions(shortRaw: trailingShortRaw, longRaw: trailingLongRaw) }

    private func orderedActions(shortRaw: String, longRaw: String) -> [SwipeAction] {
        let short = SwipeAction(rawValue: shortRaw) ?? SwipeActionSettingsStore.defaultLeadingShort
        let long = SwipeAction(rawValue: longRaw) ?? SwipeActionSettingsStore.defaultLeadingLong
        return short == long ? [short] : [short, long]
    }

    @ViewBuilder
    private func swipeButton(for action: SwipeAction) -> some View {
        Button(role: action == .delete ? .destructive : nil) {
            onRequestBulkAction(action)
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
        .tint(action == .delete || action == .junk ? OtegamiColor.destructive : OtegamiColor.accent)
    }
    #endif

    private var content: some View {
        HStack(spacing: 0) {
            AccountColorRail(accountId: digest.accountId, labelColorKey: labelColorKey)
            VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
                header
                ForEach(digest.recentSummaries) { summary in
                    AccountDigestPreviewLine(summary: summary)
                }
            }
            .padding(.leading, OtegamiSpacing.sm)
            .padding(.vertical, OtegamiSpacing.sm)
            .padding(.trailing, OtegamiSpacing.md)
        }
        .otegamiCardBackground(OtegamiColor.surface, cornerRadius: rowCornerRadius)
        #if os(iOS)
        .otegamiRowDivider()
        #endif
        .contentShape(Rectangle())
    }

    /// `ThreadRowView.rowCornerRadius`と同じ判断 (iOSは画面幅いっぱいの
    /// 角丸0、macOSは既存の丸角カード) — 詳細はそちらのdoc comment参照。
    private var rowCornerRadius: CGFloat {
        #if os(iOS)
        OtegamiRadius.none
        #else
        OtegamiRadius.card
        #endif
    }

    private var header: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            Text(verbatim: accountDisplayName)
                .font(OtegamiFont.headline())
                .foregroundStyle(OtegamiColor.ink)
                .lineLimit(1)
            if digest.unreadCount > 0 {
                Text("\(digest.unreadCount)")
                    .font(OtegamiFont.badge())
                    .foregroundStyle(OtegamiColor.surface)
                    .padding(.horizontal, OtegamiSpacing.xs)
                    .padding(.vertical, 2)
                    .background(OtegamiColor.accent)
                    .accessibilityIdentifier("accountDigest.row.\(digest.accountId).unreadBadge")
            }
            Spacer(minLength: OtegamiSpacing.sm)
            Text("\(digest.totalCount)")
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkSecondary)
                .padding(.horizontal, OtegamiSpacing.xs)
                .padding(.vertical, 2)
                .background(OtegamiColor.paleBase)
                .accessibilityIdentifier("accountDigest.row.\(digest.accountId).countBadge")
        }
    }
}

/// 直近メールの「差出人・件名」プレビュー1行 — `ThreadRowTextStack.senderText`/
/// `.subjectText`と同じ導出ロジック(そちらのdoc comment参照)を、独立した
/// `View`として持つ(`docs/ci.md`の「`ForEach`の中身は独立した`View`に切り
/// 出す」方針、`AccountDigestRow.body`をこれ以上長くしないため)。
private struct AccountDigestPreviewLine: View {
    let summary: ThreadSummary

    var body: some View {
        HStack(spacing: OtegamiSpacing.xs) {
            Text(verbatim: senderText)
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkSecondary)
                .lineLimit(1)
                .layoutPriority(1)
            Text(verbatim: subjectText)
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkTertiary)
                .lineLimit(1)
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
