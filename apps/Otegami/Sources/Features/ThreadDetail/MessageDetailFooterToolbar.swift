import SwiftUI
import OtegamiStore
import TranslationEngine

/// 新画面構成 (3): メール本文画面 (`ThreadDetailView`) 下部の固定ツールバー。
/// 表示するアイコンの集合は常に7つ (`MessageToolbarAction.allCases`、Task #88
/// で要約/翻訳の2つが5つから増えた) — ユーザーが変えられるのは
/// `MessageToolbarSettingsStore` 経由の並び順だけ (「ツールバーの編集」=
/// `onCustomizeToolbar`、「…」メニュー内から開く)。
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
///
/// Task #88 (「要約と翻訳のボタンをフローティングをやめてツールバーに入れて」):
/// `aiFeaturesState`が要約/翻訳の2アイコンの唯一の状態源 — `MessageView`が
/// 現在展開中のメッセージについて書き込み、この`nil`許容の`class`参照を
/// そのまま保持するだけで`@Observable`のプロパティ単位追跡により再描画され
/// る (`MessageDetailAIFeaturesState`のdoc comment、以前の
/// `MessageDetailFloatingButtons`と同じ仕組み)。`nil`(まだ何も展開されて
/// いない、アコーディオン切替の谷間)、または`showsSummaryButton`/
/// `showsTranslationButton`/`isTranslationAvailable`が偽の間は、アイコン
/// 自体を消さず**グレーアウト**して並びを安定させる (指示どおり)。
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
    var aiFeaturesState: MessageDetailAIFeaturesState?

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
        case .summarize: summarizeButton
        case .translate: translateButton
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

    // MARK: - Task #88: 要約/翻訳 (旧 `MessageDetailFloatingButtons`)

    /// `aiFeaturesState`が`nil`か、要約自体がこのメッセージで意味を持たない
    /// (本文未読込・「AI 機能」設定オフ) か、この端末で AI 機能が丸ごと
    /// 使えない — いずれかならグレーアウトして`disabled`にする。旧
    /// `AISummaryFloatingButton.isAvailable`と同じ2条件をここでまとめて
    /// 「表示するかどうか」ではなく「押せるかどうか」に読み替えている。
    private var isSummarizeEnabled: Bool {
        aiFeaturesState?.showsSummaryButton == true && aiFeaturesState?.isTranslationAvailable == true
    }

    private var isTranslateEnabled: Bool {
        aiFeaturesState?.showsTranslationButton == true && aiFeaturesState?.isTranslationAvailable == true
    }

    private var summarizeTone: AIToolbarTone {
        guard isSummarizeEnabled, let aiFeaturesState else { return .disabled }
        if aiFeaturesState.summaryState.isFailure { return .attention }
        if aiFeaturesState.summaryState.isSummarized { return .active }
        return .normal
    }

    /// 翻訳中/失敗はそのまま、翻訳済みは「今どちらを表示しているか」で
    /// トーンを切り替える — `showOriginal`(原文表示中) なら`.normal`に戻し、
    /// 訳文を表示している間だけ`.active`にする。旧`TranslationFloatingButton
    /// .tone`と同じ判定 (アイコン自体は変えず、色だけで「原文へ戻す」/
    /// 「訳文に戻す」のどちらが次のタップの結果かを示す)。
    private var translateTone: AIToolbarTone {
        guard isTranslateEnabled, let aiFeaturesState else { return .disabled }
        if aiFeaturesState.translationState.isFailure { return .attention }
        if case .translated = aiFeaturesState.translationState {
            return aiFeaturesState.translationShowOriginal ? .normal : .active
        }
        return .normal
    }

    @ViewBuilder
    private var summarizeButton: some View {
        Button(action: handleSummarizeTap) {
            toolbarAIIcon(
                .summarize,
                isLoading: aiFeaturesState?.summaryState.isSummarizing ?? false,
                tone: summarizeTone
            )
        }
        .disabled(!isSummarizeEnabled)
        .accessibilityIdentifier("messageDetail.toolbar.summarize")
        .accessibilityLabel(Text(summarizeAccessibilityLabel))
    }

    @ViewBuilder
    private var translateButton: some View {
        Button(action: handleTranslateTap) {
            toolbarAIIcon(
                .translate,
                isLoading: aiFeaturesState?.translationState.isTranslating ?? false,
                tone: translateTone
            )
        }
        .disabled(!isTranslateEnabled)
        .accessibilityIdentifier("messageDetail.toolbar.translate")
        .accessibilityLabel(Text(translateAccessibilityLabel))
        // Task #61 (ガードレール誤発動の寛容化)/Task #55: 部分ブロック注記・
        // 失敗理由は、旧フローティングボタンでは専用の縦積みレイアウトに
        // 表示していたが、等幅で並ぶツールバーの1アイコンにはその余地が
        // 無い — ボタン自身の真上に小さな吹き出しとして重ねることで、
        // 表示経路 (「一部の文は翻訳できませんでした」/「翻訳に失敗しま
        // した: …」) 自体は維持しつつ、隣のアイコンの幅には影響させない。
        .overlay(alignment: .top) {
            if let translateFootnote {
                translateFootnoteCaption(translateFootnote)
                    .fixedSize()
                    .offset(y: -(OtegamiSpacing.xl + OtegamiSpacing.xs))
            }
        }
    }

    /// `handleTap`のロジックは旧`AISummaryFloatingButton`/
    /// `TranslationFloatingButton`と同一 — 状態遷移そのものは変えず、器を
    /// ツールバーアイコンに差し替えただけ。
    private func handleSummarizeTap() {
        guard isSummarizeEnabled, let aiFeaturesState else { return }
        switch aiFeaturesState.summaryState {
        case .none, .failed:
            aiFeaturesState.onSummarize()
        case .summarizing, .summarized:
            break
        }
        aiFeaturesState.onShowSummary()
    }

    private func handleTranslateTap() {
        guard isTranslateEnabled, let aiFeaturesState else { return }
        switch aiFeaturesState.translationState {
        case .none, .failed:
            aiFeaturesState.onTranslate()
        case .translating:
            break
        case .translated:
            aiFeaturesState.translationShowOriginal.toggle()
        }
    }

    private var summarizeAccessibilityLabel: String {
        guard isSummarizeEnabled, let aiFeaturesState else { return String(localized: "この端末では要約を利用できません") }
        return switch aiFeaturesState.summaryState {
        case .none: String(localized: "要約")
        case .summarizing: String(localized: "要約中")
        case .summarized: String(localized: "要約を表示")
        case .failed: String(localized: "要約を再試行")
        }
    }

    private var translateAccessibilityLabel: String {
        guard isTranslateEnabled, let aiFeaturesState else { return String(localized: "この端末では翻訳を利用できません") }
        return switch aiFeaturesState.translationState {
        case .none: String(localized: "英語 → 日本語（端末内で翻訳）")
        case .translating: String(localized: "翻訳中")
        case .failed: String(localized: "翻訳を再試行")
        case .translated: aiFeaturesState.translationShowOriginal ? String(localized: "訳文に戻す") : String(localized: "原文に戻す")
        }
    }

    /// 旧`TranslationFloatingButton.footnote`と同一のロジック — `String
    /// (localized:)`を通さない理由もそのまま (`message`が実行時の値を
    /// 含むため)。
    private var translateFootnote: String? {
        guard let aiFeaturesState else { return nil }
        if case .failed(let message) = aiFeaturesState.translationState {
            return "翻訳に失敗しました: \(message)"
        }
        if case .translated(let record) = aiFeaturesState.translationState, record.hasPartiallyBlockedContent {
            return "一部の文は翻訳できませんでした"
        }
        return nil
    }

    private var translateFootnoteTone: Color {
        if let aiFeaturesState, case .failed = aiFeaturesState.translationState { return OtegamiColor.destructive }
        return OtegamiColor.inkSecondary
    }

    private func translateFootnoteCaption(_ text: String) -> some View {
        Text(text)
            .font(OtegamiFont.badge())
            .foregroundStyle(.white)
            .padding(.horizontal, OtegamiSpacing.sm)
            .padding(.vertical, OtegamiSpacing.xs)
            .background(translateFootnoteTone, in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 200, alignment: .center)
            .accessibilityIdentifier("messageDetail.toolbar.translate.footnote")
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

    /// Task #88: 要約/翻訳だけが取りうる4状態 — 他の5アイコン (`toolbarIcon`)
    /// は常に`OtegamiColor.accent`固定で状態を持たないのに対し、この2つは
    /// メッセージ次第で意味を持たなかったり (`.disabled`)、進行中/完了/失敗
    /// があったりする。旧`OtegamiFloatingButtonTone`(円形の塗りつぶし
    /// ボタン専用) とは別に、この等幅アイコン+ラベルという器に合わせた
    /// 色だけのトーンとして新設した — 円を塗りつぶす場所が無いツールバー
    /// アイコンには、その流用より前景色を変えるだけの方が素直。
    private enum AIToolbarTone {
        /// 通常の`accent`。
        case normal
        /// 結果が出ていて (要約済み/訳文表示中)、まだ効果があると分かる
        /// よう`accentText`(`accent`よりコントラストの強いステップ、既存
        /// トークン) を使う — `OtegamiFloatingButtonTone.active`と同じ
        /// 使い分け。
        case active
        /// 直前の試行が失敗、再試行を促す`destructive`(赤)。
        case attention
        /// このメッセージ/この端末では意味を持たない — `inkTertiary`
        /// (「薄」トークン) でグレーアウトしつつ、並び自体は崩さない
        /// (指示どおり非表示にしない)。
        case disabled

        var color: Color {
            switch self {
            case .normal: OtegamiColor.accent
            case .active: OtegamiColor.accentText
            case .attention: OtegamiColor.destructive
            case .disabled: OtegamiColor.inkTertiary
            }
        }
    }

    @ViewBuilder
    private func toolbarAIIcon(_ action: MessageToolbarAction, isLoading: Bool, tone: AIToolbarTone) -> some View {
        VStack(spacing: 2) {
            if isLoading {
                ProgressView()
                    .accessibilityIdentifier("messageDetail.toolbar.\(action.rawValue).loading")
            } else {
                Image(systemName: action.systemImage)
                    .font(.system(size: 18))
            }
            Text(action.title)
                .font(OtegamiFont.badge())
        }
        .foregroundStyle(tone.color)
        .otegamiMinimumTappable()
    }
}

/// Task #88: 旧`TranslationBar.swift`(`TranslationFloatingButton`) が持って
/// いた同名のprivate extensionをそのまま引き継いだ — 唯一の利用元が
/// `translateTone`に変わっただけ。
private extension MessageTranslationState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
