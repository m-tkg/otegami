import SwiftUI

/// 新画面構成 (3): メール本文画面 (`ThreadDetailView`) 下部の固定ツールバー。
/// 表示するアイコンの集合は常に5つ (`MessageToolbarAction.allCases`) —
/// ユーザーが変えられるのは `MessageToolbarSettingsStore` 経由の並び順だけ
/// (「ツールバーの編集」= `onCustomizeToolbar`、「…」メニュー内から開く)。
///
/// 「返信」は返信/全員に返信の2択を持つ `Menu` (design-phase-3 の「返信/
/// 全員に返信/英語で返信を下書き」ボタン群のうち、返信系2つをここに統合 —
/// 「英語で返信を下書き」は指示どおり「…」メニュー側に置いた)。「…」には
/// ミュート・削除・未読にする・アーカイブ・迷惑メールにする・ピン留め・
/// 英語で返信を下書き・ツールバーのカスタマイズを集約する。
///
/// `onSearch`/`onDraftEnglishReply` が `nil` のときはそのアイコン/メニュー
/// 項目自体を出さない (`onSearch` は macOS 側で配線していない — 新しい検索
/// 画面は iOS のみのインフラのため。`onDraftEnglishReply` は
/// `AppEnvironment.isTranslationAvailable` が `false` な端末では出さない、
/// design-phase-3 の既存方針を踏襲)。
struct MessageDetailFooterToolbar: View {
    var onReply: () -> Void
    var onReplyAll: () -> Void
    var onForward: () -> Void
    var onSearch: (() -> Void)?
    var onInfo: () -> Void
    var onDraftEnglishReply: (() -> Void)?
    var isMuted: Bool
    var onToggleMute: () -> Void
    var onMarkUnread: () -> Void
    var onArchive: () -> Void
    var onJunk: () -> Void
    var isPinned: Bool
    var onTogglePin: () -> Void
    var onDelete: () -> Void
    var onCustomizeToolbar: () -> Void

    @State private var order: [MessageToolbarAction] = MessageToolbarSettingsStore.loadOrder()

    var body: some View {
        HStack(spacing: 0) {
            ForEach(order) { action in
                toolbarButton(for: action)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, OtegamiSpacing.sm)
        .padding(.vertical, OtegamiSpacing.sm)
        .background(OtegamiColor.surface)
        .accessibilityIdentifier("messageDetail.footerToolbar")
        // ツールバーのカスタマイズ画面から戻ってきたときに並び順を反映する —
        // このビュー自身は設定変更を監視しない (`UserDefaults` の
        // `@AppStorage` にしていない理由は `MessageToolbarSettingsStore`
        // のドキュメント参照。頻繁に変わる値ではないので、再表示のたびに
        // 読み直せば十分)。
        .onAppear { order = MessageToolbarSettingsStore.loadOrder() }
    }

    @ViewBuilder
    private func toolbarButton(for action: MessageToolbarAction) -> some View {
        switch action {
        case .reply: replyMenuButton
        case .forward: forwardButton
        case .search: searchButton
        case .info: infoButton
        case .more: moreMenuButton
        }
    }

    private var replyMenuButton: some View {
        Menu {
            Button { onReply() } label: { Label("返信", systemImage: "arrowshape.turn.up.left") }
                .accessibilityIdentifier("messageDetail.toolbar.reply.single")
            Button { onReplyAll() } label: { Label("全員に返信", systemImage: "arrowshape.turn.up.left.2") }
                .accessibilityIdentifier("messageDetail.toolbar.reply.all")
        } label: {
            toolbarIcon(.reply)
        }
        .accessibilityIdentifier("messageDetail.toolbar.reply")
    }

    @ViewBuilder
    private var forwardButton: some View {
        Button(action: onForward) { toolbarIcon(.forward) }
            .accessibilityIdentifier("messageDetail.toolbar.forward")
    }

    @ViewBuilder
    private var searchButton: some View {
        if let onSearch {
            Button(action: onSearch) { toolbarIcon(.search) }
                .accessibilityIdentifier("messageDetail.toolbar.search")
        }
    }

    @ViewBuilder
    private var infoButton: some View {
        Button(action: onInfo) { toolbarIcon(.info) }
            .accessibilityIdentifier("messageDetail.toolbar.info")
    }

    private var moreMenuButton: some View {
        Menu {
            Button { onToggleMute() } label: {
                Label(isMuted ? "ミュート解除" : "スレッドをミュート", systemImage: isMuted ? "bell" : "bell.slash")
            }
            .accessibilityIdentifier("messageDetail.toolbar.more.mute")

            Button { onTogglePin() } label: {
                Label(isPinned ? "ピン留めを解除" : "ピン留め", systemImage: isPinned ? "pin.slash" : "pin")
            }
            .accessibilityIdentifier("messageDetail.toolbar.more.pin")

            Button { onMarkUnread() } label: { Label("未読にする", systemImage: "envelope.badge") }
                .accessibilityIdentifier("messageDetail.toolbar.more.markUnread")

            Button { onArchive() } label: { Label("アーカイブ", systemImage: "archivebox") }
                .accessibilityIdentifier("messageDetail.toolbar.more.archive")

            Button { onJunk() } label: { Label("迷惑メールにする", systemImage: "exclamationmark.octagon") }
                .accessibilityIdentifier("messageDetail.toolbar.more.junk")

            if let onDraftEnglishReply {
                Button { onDraftEnglishReply() } label: { Label("英語で返信を下書き", systemImage: "globe") }
                    .accessibilityIdentifier("messageDetail.toolbar.more.draftEnglishReply")
            }

            Divider()

            Button { onCustomizeToolbar() } label: { Label("ツールバーをカスタマイズ", systemImage: "slider.horizontal.3") }
                .accessibilityIdentifier("messageDetail.toolbar.more.customize")

            Divider()

            Button(role: .destructive) { onDelete() } label: { Label("削除", systemImage: "trash") }
                .accessibilityIdentifier("messageDetail.toolbar.more.delete")
        } label: {
            toolbarIcon(.more)
        }
        .accessibilityIdentifier("messageDetail.toolbar.more")
    }

    private func toolbarIcon(_ action: MessageToolbarAction) -> some View {
        VStack(spacing: 2) {
            Image(systemName: action.systemImage)
                .font(.system(size: 18))
            Text(action.title)
                .font(OtegamiFont.badge())
        }
        .foregroundStyle(OtegamiColor.accent)
        .otegamiMinimumTappable()
    }
}
