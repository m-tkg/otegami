import SwiftUI
import OtegamiStore

/// A digest row always applies one absolute operation to the whole account.
/// The configurable single-row swipe action remains a toggle, but its digest
/// counterpart cannot represent "mark unread" or "unarchive".
///
/// ユーザー要望 (2026-08-07「グループに対してのピン留め・ピン解除は
/// できないようにしてほしい」): `.pin` は**意図的に持たない** — ピン留めは
/// 「この1通を後で見る」という個別のメールに対する意思表示で、アカウントの
/// 全メールにまとめて付ける操作としては意味を成さないうえ、ピン留めした
/// メールはアーカイブから保護される (`MessageRemoval.ArchiveGuardError
/// .pinned`) ので、誤爆すると以降の一括アーカイブが丸ごと効かなくなる。
/// `init?(_:)` がスワイプ設定の `.pin` に対して `nil` を返し、呼び出し側
/// (スワイプボタン/コンテキストメニュー) がその項目自体を出さない。
///
/// ユーザー要望 (2026-08-08「グループでのアーカイブ処理は、受信箱でのみ
/// 使える機能にして」): `.archive` は表示中フォルダが受信トレイのときだけ
/// — 判定は `AccountDigestPresentation.isBulkActionAvailable(_:role:)`。
enum AccountDigestBulkAction: String, Identifiable {
    case markRead
    case archive
    case junk
    case delete

    /// `nil` = このスワイプ設定はグループ操作として提供しない (`.pin`)。
    init?(_ swipeAction: SwipeAction) {
        switch swipeAction {
        case .toggleRead: self = .markRead
        case .archive: self = .archive
        case .junk: self = .junk
        case .delete: self = .delete
        case .pin: return nil
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markRead: String(localized: "既読にする")
        case .archive: String(localized: "アーカイブ")
        case .junk: String(localized: "迷惑メールにする")
        case .delete: String(localized: "削除")
        }
    }

    var systemImage: String {
        switch self {
        case .markRead: "envelope.open"
        case .archive: "archivebox"
        case .junk: "exclamationmark.octagon"
        case .delete: "trash"
        }
    }

    var isDestructive: Bool { self == .delete }
}

/// Task #92 (アカウントダイジェスト画面): one row of `AccountDigestView` —
/// `AccountColorRail` (1d の3pxアカウント色罫線、既存トークンをそのまま
/// 再利用) + Task #130 で追加したこのアカウント自身の`SenderAvatar` +
/// アカウント表示名 + 未読/件数バッジ、続けて直近2-3件の「差出人・件名」
/// プレビュー行。タップでそのアカウントに絞り込んだ一覧へ
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
    /// 表示中のフォルダ (`AccountDigestView.role`) — アーカイブを受信箱
    /// でのみ出すため (`AccountDigestPresentation.isBulkActionAvailable`)。
    let role: MailboxRoleRecord
    /// `AccountFilterChip.label`/`AccountGroupSectionHeader.accountDisplayName`
    /// (廃止済み) と同じ理由で`Text(verbatim:)`のみで扱う — 表示名がメール
    /// アドレスそのものの場合、`LocalizedStringKey`経由だとSwiftUIが自動
    /// リンク化し、タップで`mailto:`が開く実機バグを踏む。
    let accountDisplayName: String
    /// Task #130, 1「アカウント別のアバターを表示」: `SenderAvatar`に渡す
    /// このアカウント自身のアドレス — `AccountSettingsCategoryView
    /// .accountRow(for:)` (Task #117) と全く同じ経路 (`account.email`を
    /// `address`としてそのまま渡すだけで、連絡先写真→Googleプロフィール
    /// 写真→Gravatar→企業ロゴ→イニシャルの既存優先順位チェーンに乗る) を
    /// このダイジェスト行にも再利用する。
    let accountEmail: String
    let labelColorKey: String?
    let onSelect: () -> Void
    /// 実行前の確認ダイアログは`AccountDigestView`側が持つ(複数行から
    /// 一箇所にまとめるほうが`.confirmationDialog`の状態管理が単純になる
    /// ため) — このボタン/コンテキストメニュー行は要求するだけ。
    let onRequestBulkAction: (AccountDigestBulkAction) -> Void

    var body: some View {
        Button(action: onSelect) {
            content
        }
        .buttonStyle(.plain)
        // Task #130, 2「アカウント行(カード)の間に縦の隙間」: 元は
        // `EdgeInsets()`(ゼロ)で行が隙間なく連続し、`otegamiCardBackground`
        // の角丸/背景だけがカードの境目を示していた (特にiOS — 角丸0で
        // 完全に地続き) — 上下だけ`OtegamiSpacing.xs`(4pt、既存トークンの
        // 中で最小) の余白を入れてカード間に隙間を作る。左右は`0`のまま
        // (iOSの全幅カード表示は維持)。
        // 2026-08-07 macOS ネイティブ化: カード廃止に伴い macOS は上下
        // マージンもゼロ (区切りはヘアラインが担う)。iOS はカード間の
        // 隙間 (Task #130, 2) を維持。
        //
        // 実機報告 (2026-08-12)「行をタップしても無反応」対策: iOS の上下
        // 4pt は `listRowInsets` = **行の外側**なので、その帯はタップが
        // どこにも届かない不感帯になっていた。隙間そのものは Task #130, 2
        // の意図なので残し、行の外側ではなく行と行の *間* に出す
        // `AccountDigestView` 側の `.listRowSpacing(OtegamiSpacing.xs)` へ
        // 移した。
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
            // `.pin`はグループ操作として提供しない (`AccountDigestBulkAction`
            // の doc comment) ので、`compactMap`で落ちた分は項目自体が
            // 出ない。受信箱以外の`.archive`も同様に落ちる
            // (`AccountDigestPresentation.isBulkActionAvailable`)。
            ForEach(availableBulkActions) { action in
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

    /// このフォルダでグループ操作として提供する一括アクション —
    /// `.pin` (グループ操作を持たない) と、受信箱以外での `.archive` が
    /// ここで落ちる。
    private var availableBulkActions: [AccountDigestBulkAction] {
        SwipeAction.allCases
            .compactMap(AccountDigestBulkAction.init)
            .filter { AccountDigestPresentation.isBulkActionAvailable($0, role: role) }
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

    /// `.pin`に割り当てられているスロットはボタンごと出さない
    /// (`AccountDigestBulkAction`の doc comment) — `MessageListRow`の
    /// 個別行スワイプでは今までどおりピン留めできる。受信箱以外での
    /// `.archive` も同じ扱い (`availableBulkActions`)。
    @ViewBuilder
    private func swipeButton(for swipeAction: SwipeAction) -> some View {
        if let action = AccountDigestBulkAction(swipeAction),
           AccountDigestPresentation.isBulkActionAvailable(action, role: role) {
            Button(role: action.isDestructive ? .destructive : nil) {
                onRequestBulkAction(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .tint(action == .delete || action == .junk ? OtegamiColor.destructive : OtegamiColor.accent)
        }
    }
    #endif

    private var content: some View {
        HStack(spacing: 0) {
            AccountColorRail(accountId: digest.accountId, labelColorKey: labelColorKey)
            // Task #130, 1: 色罫線の隣にこのアカウント自身のアバター —
            // `AccountSettingsCategoryView.accountRow(for:)` (Task #117) と
            // 同じ`diameter: 36`を使い、アプリ内で「アカウント自身の
            // アバター」の見た目を揃える。
            SenderAvatar(
                displayName: accountDisplayName, address: accountEmail, accountId: digest.accountId,
                labelColorKey: labelColorKey, diameter: 36
            )
            .padding(.leading, OtegamiSpacing.sm)
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
        // 2026-08-07 (メイン UI の macOS ネイティブ化): macOS の角丸カード
        // を廃止しフラットな全幅行 + ヘアライン区切りへ (`ThreadRowView` の
        // 同日 doc comment 参照)。
        // Liquid Glass Phase 1 (同日、docs/design-system.md「Liquid Glass
        // 方針」): iOS 側の`surface`塗りカード表現もこの移行で廃止し、
        // macOS と同じ「塗りなし + ヘアライン区切り」に揃えた — `#if os`
        // 分岐は不要になったので畳んだ。
        //
        // 実機報告 (2026-08-12)「行をタップしても無反応」対策の下2行。
        // `dfed039` (上記 Phase 1) は `ThreadRowView` からは塗りの *色* を
        // 抜いただけ (`.otegamiCardBackground(isSelected ? … : .clear, …)`
        // が残り、透明でも `.background().clipShape()` のレイヤーは1枚ある)
        // のに対し、この行からは `otegamiCardBackground` の呼び出しごと
        // 消していた — アプリ内で背景レイヤーを1枚も持たない唯一の行行。
        // `.buttonStyle(.plain)` のヒットテストは描画内容の形にそのまま
        // 従うので (FAB で踏んだ `020ca83` / `docs/architecture.md`「n.」)、
        // 下地となるフレームと背景レイヤーを明示して `ThreadRowView` と
        // 同じ形に揃える。`Color.clear` なので見た目は一切変わらず、
        // Liquid Glass 方針 (独自の塗りを持たない) にも反しない。
        .frame(maxWidth: .infinity, alignment: .leading)
        .otegamiCardBackground(Color.clear, cornerRadius: OtegamiRadius.none)
        .otegamiRowDivider()
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            Text(verbatim: accountDisplayName)
                .font(OtegamiFont.headline())
                .foregroundStyle(OtegamiColor.ink)
                .lineLimit(1)
            Spacer(minLength: OtegamiSpacing.sm)
            // 実機フィードバック第4弾 (2026-07-29「右端のメールの件数は
            // 未読のみ表示して」): 右端の総件数バッジを廃止し、未読バッジ
            // だけを右端に出す (0 件なら何も出さない)。
            if digest.unreadCount > 0 {
                // 2026-08-07 (メイン UI の macOS ネイティブ化): macOS は
                // サイドバーの `UnreadCountBadge` と同じ素の数字テキスト —
                // 青い塗りのバッジは iOS だけに残す。
                #if os(macOS)
                Text("\(digest.unreadCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("accountDigest.row.\(digest.accountId).unreadBadge")
                #else
                Text("\(digest.unreadCount)")
                    .font(OtegamiFont.badge())
                    .foregroundStyle(OtegamiColor.surface)
                    .padding(.horizontal, OtegamiSpacing.xs)
                    .padding(.vertical, 2)
                    .background(OtegamiColor.accent)
                    .accessibilityIdentifier("accountDigest.row.\(digest.accountId).unreadBadge")
                #endif
            }
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
