import SwiftUI
import OtegamiStore
import TranslationEngine

/// 新画面構成 (3): メール本文画面 (`ThreadDetailView`) 下部の固定ツールバー。
/// アクションの全体集合は常に15個 (`MessageToolbarAction.allCases`、Task #88
/// で要約/翻訳が加わり5→7、2026-07-29の追加仕様で旧「その他」メニュー
/// ネイティブの7操作 — ミュート・ピン留め・未読にする・アーカイブ・
/// 迷惑メールにする・英語で返信を下書き・削除 — を一級アクションへ昇格し
/// 7→14、Task #103 で「ソースを表示」が加わり14→15) —
/// `MessageToolbarSettingsStore` 経由で並び順に加え、Task #100
/// (「フッターツールバーのカスタマイズ」) 以降は表示/非表示も変更できる。
/// 設定画面自体 (`MessageToolbarSettingsView`) への入口は2つ — 「…」
/// メニュー内の `onCustomizeToolbar` (この画面を見ながらすぐ調整したい、
/// という近さ優先) と、設定 → メールビューア →「ツールバーのカスタマイズ」
/// (`MailViewerSettingsView`、他の表示設定と同じ場所にまとまっている
/// 一貫性優先) — どちらも同じ画面を開くだけで、状態は
/// `MessageToolbarSettingsStore`に一本化されている。表示オフのアクション
/// はこのツールバーには描画せず、`moreMenuButton`の「その他」メニュー内に
/// 項目として追加表示する (`hiddenActionMenuItems`) — つまり「その他」の
/// 中身は「ユーザーが非表示にしたアクション」で完全に説明できる。「その他」
/// 自身と、この画面自体を開く「ツールバーをカスタマイズ」ショートカット
/// (`onCustomizeToolbar`、メッセージへの操作ではないためアクション化して
/// いない) は非表示にできず常に最後尾・末尾固定。表示オンのアクションが
/// 画面幅に収まらない場合 (大きな文字サイズ設定・狭い端末幅・多くの
/// アクションを表示オンにした場合等) は、既定の均等配置 (`fixedRow`) の
/// 代わりにインジケータ非表示・左端起点の横スクロール (`scrollableRow`)
/// にフォールバックする — `body`の`ViewThatFits`のdoc comment参照。
///
/// 「返信」は返信/全員に返信の2択を持つ `Menu` (design-phase-3 の「返信/
/// 全員に返信/英語で返信を下書き」ボタン群のうち、返信系2つをここに統合)。
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
    /// Task #103 (「ソースを表示」): 生RFC822ソースのシート
    /// (`MessageSourceView`) を開く — `onInfo`と同様、対象は常に現在展開中の
    /// 1通 (`ThreadDetailView.targetMessage`)。
    var onViewSource: () -> Void
    var onCustomizeToolbar: () -> Void
    var aiFeaturesState: MessageDetailAIFeaturesState?

    // 実機報告 (2026-07-29):「ツールバーをカスタマイズ」で設定を変えても
    // 画面遷移するまで反映されなかった — 元は`@State`に一度だけ読み込み、
    // `.onAppear`で読み直すだけだったため、カスタマイズ画面をシートで
    // 開いたまま裏のこの画面が変更を検知する手段が無かった (`@State`は
    // `UserDefaults`を購読しない)。`@AppStorage`は`UserDefaults`の
    // 同じキーへの書き込みを購読して自動的に再描画を起こす — 他の
    // `*SettingsStore`群 (`ListDisplaySettingsStore`等) が設定画面側で
    // 使っているのと同じ仕組みで、こちら側 (読み取り専用の購読者) にも
    // 適用した。`items`は`rawOrder`が変わるたびに再計算される computed
    // property にしたので、`MessageToolbarSettingsView`が
    // `MessageToolbarSettingsStore.saveItems(_:)`で同じキーに書き込んだ
    // 瞬間、シートを閉じずともこのツールバーが即座に切り替わる。
    @AppStorage(MessageToolbarSettingsStore.orderKey) private var rawOrder: String = ""

    private var items: [MessageToolbarItemSetting] { MessageToolbarSettingsStore.items(fromRawValue: rawOrder) }

    /// アイコンとして描画する、表示オンのアクションだけの並び。
    private var visibleOrder: [MessageToolbarAction] { MessageToolbarSettingsStore.visibleOrder(items) }

    /// Task #100: 非表示にしたアクション (`more`自身は含まれない) —
    /// `moreMenuButton`が末尾に項目として追加表示する。
    private var hiddenActions: [MessageToolbarAction] { MessageToolbarSettingsStore.hiddenOrder(items) }

    var body: some View {
        // ユーザー指示 (2026-07-29 追加仕様): 表示オンのアクションが画面幅を
        // 超える場合は横スクロールできるようにする。`ViewThatFits`は候補を
        // 先頭から順に試し、その*理想サイズ*(親から幅の提案が無いときの
        // 自然な幅) が利用可能な幅に収まる最初の候補を採用する — `fixedRow`
        // 側の各アイコンに付けている`.frame(maxWidth: .infinity)`は「親が
        // 幅を提案してきたときに目一杯広がる」指定であって理想サイズ自体を
        // 無限大にはしない (理想サイズは中身の内在幅のまま) ので、7アイコン
        // 分の内在幅の合計が画面幅以下なら`fixedRow`(既存の均等配置、
        // 見た目は完全に不変) が選ばれ、収まらなければ最後の候補
        // `scrollableRow`にフォールバックする。最後の候補は「収まるか」の
        // 判定自体をスキップされる (無条件フォールバック) ので、
        // `ScrollView`の理想サイズが何であっても問題にならない。
        ViewThatFits(in: .horizontal) {
            fixedRow
            scrollableRow
        }
        .padding(.horizontal, OtegamiSpacing.sm)
        .padding(.vertical, OtegamiSpacing.sm)
        .background(OtegamiColor.surface)
        .accessibilityIdentifier("messageDetail.footerToolbar")
    }

    /// 全項目が画面幅に収まる場合の既存レイアウト — 変更前と1文字も違わない
    /// (`ViewThatFits`に切り出しただけ)。均等配置 (各アイコンが
    /// `.frame(maxWidth: .infinity)`で余った幅を均等に分け合う)。
    private var fixedRow: some View {
        HStack(spacing: 0) {
            ForEach(visibleOrder) { action in
                toolbarButton(for: action)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// 収まりきらないときのフォールバック — インジケータ非表示の横スクロール。
    /// `ScrollView(.horizontal)`は既定で左端 (先頭) 起点なので、開始位置を
    /// 明示的に設定する必要は無い。アイコン間は`OtegamiSpacing.md`固定
    /// (均等配置のように余白を伸縮させない — 内在幅どおりに詰めて並べる、
    /// スクロール可能な列としては自然な見た目)。各アイコン自体の最小幅は
    /// `toolbarIcon`/`toolbarAIIcon`が使う`.otegamiMinimumTappable()`
    /// (44pt) がそのまま保証する。
    private var scrollableRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OtegamiSpacing.md) {
                ForEach(visibleOrder) { action in
                    toolbarButton(for: action)
                }
            }
        }
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
        case .mute: muteButton
        case .pin: pinButton
        case .markUnread: markUnreadButton
        case .archive: archiveButton
        case .junk: junkButton
        case .draftEnglishReply: draftEnglishReplyButton
        case .delete: deleteButton
        case .viewSource: viewSourceButton
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

    // MARK: - 2026-07-29 追加仕様: 旧「その他」ネイティブ項目のツールバー
    // 直接表示バリアント。表示オンにするとここが使われ、非表示 (既定) の
    // 間は`hiddenActionMenuItem(for:)`の同名ケースが「その他」メニューの
    // 中に同じラベル/アイコンで描画する — ハンドラ (`onToggleMute`等) も
    // 完全に共有しているので、表示/非表示を切り替えても押した結果は
    // 変わらない。

    /// ミュート/ピン留めは状態でラベル・アイコンが変わるトグル — 静的な
    /// `MessageToolbarAction.title`/`.systemImage`をそのまま使わず、
    /// `toolbarIcon(_:title:systemImage:)`のオーバーライド引数で
    /// `moreMenuButton`の旧実装と同じ2状態の文言/アイコンを再現する。
    @ViewBuilder
    private var muteButton: some View {
        Button(action: onToggleMute) {
            toolbarIcon(.mute, title: isMuted ? "ミュート解除" : "スレッドをミュート", systemImage: isMuted ? "bell" : "bell.slash")
        }
        .accessibilityIdentifier("messageDetail.toolbar.mute")
    }

    @ViewBuilder
    private var pinButton: some View {
        Button(action: onTogglePin) {
            toolbarIcon(.pin, title: isPinned ? "ピン留めを解除" : "ピン留め", systemImage: isPinned ? "pin.slash" : "pin")
        }
        .accessibilityIdentifier("messageDetail.toolbar.pin")
    }

    @ViewBuilder
    private var markUnreadButton: some View {
        Button(action: onMarkUnread) { toolbarIcon(.markUnread) }
            .accessibilityIdentifier("messageDetail.toolbar.markUnread")
    }

    @ViewBuilder
    private var archiveButton: some View {
        Button(action: onArchive) { toolbarIcon(.archive) }
            .accessibilityIdentifier("messageDetail.toolbar.archive")
    }

    @ViewBuilder
    private var junkButton: some View {
        Button(action: onJunk) { toolbarIcon(.junk) }
            .accessibilityIdentifier("messageDetail.toolbar.junk")
    }

    @ViewBuilder
    private var draftEnglishReplyButton: some View {
        if let onDraftEnglishReply {
            Button(action: onDraftEnglishReply) { toolbarIcon(.draftEnglishReply) }
                .accessibilityIdentifier("messageDetail.toolbar.draftEnglishReply")
        }
    }

    /// 削除だけは`role: .destructive`＋`OtegamiColor.destructive`で赤く
    /// する — 「その他」メニュー内での旧表示 (Menu が`role: .destructive`
    /// のラベルを自動的に赤くする) と同じ破壊的操作の見た目をツールバー
    /// 直接表示でも踏襲する (指示どおり「その他」実装の挙動を踏襲)。
    @ViewBuilder
    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            toolbarIcon(.delete, tint: OtegamiColor.destructive)
        }
        .accessibilityIdentifier("messageDetail.toolbar.delete")
    }

    /// Task #103: 静的なアイコン/ラベル (`toolbarIcon(.viewSource)`) だけの
    /// 単純なボタン — `mute`/`pin`のような状態依存の見た目は無い。
    @ViewBuilder
    private var viewSourceButton: some View {
        Button(action: onViewSource) { toolbarIcon(.viewSource) }
            .accessibilityIdentifier("messageDetail.toolbar.viewSource")
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

    // MARK: - Task #100: 非表示にしたアクションを「その他」メニューへ移動

    /// `hiddenActions`それぞれをメニュー項目として並べ、1件以上あれば末尾に
    /// 区切り線を足す (唯一残った固定項目「ツールバーをカスタマイズ」と
    /// 視覚的に分ける — `moreMenuButton`参照)。`.reply`は元がサブメニュー
    /// (返信/全員に返信の2択) なので、非表示時は2つのフラットな項目に
    /// 展開する。
    @ViewBuilder
    private var hiddenActionMenuItems: some View {
        ForEach(hiddenActions) { action in
            hiddenActionMenuItem(for: action)
        }
        if !hiddenActions.isEmpty {
            Divider()
        }
    }

    @ViewBuilder
    private func hiddenActionMenuItem(for action: MessageToolbarAction) -> some View {
        switch action {
        case .reply:
            Button { onReply() } label: { Label(action.title, systemImage: action.systemImage) }
                .accessibilityIdentifier("messageDetail.toolbar.more.hidden.reply")
            Button { onReplyAll() } label: { Label("全員に返信", systemImage: "arrowshape.turn.up.left.2") }
                .accessibilityIdentifier("messageDetail.toolbar.more.hidden.replyAll")
        case .forward:
            Button { onForward() } label: { Label(action.title, systemImage: action.systemImage) }
                .accessibilityIdentifier("messageDetail.toolbar.more.hidden.forward")
        case .search:
            if let onSearch {
                Button(action: onSearch) { Label(action.title, systemImage: action.systemImage) }
                    .accessibilityIdentifier("messageDetail.toolbar.more.hidden.search")
            }
        case .info:
            Button { onInfo() } label: { Label(action.title, systemImage: action.systemImage) }
                .accessibilityIdentifier("messageDetail.toolbar.more.hidden.info")
        case .summarize:
            Button(action: handleSummarizeTap) { Label(summarizeAccessibilityLabel, systemImage: action.systemImage) }
                .disabled(!isSummarizeEnabled)
                .accessibilityIdentifier("messageDetail.toolbar.more.hidden.summarize")
        case .translate:
            Button(action: handleTranslateTap) { Label(translateAccessibilityLabel, systemImage: action.systemImage) }
                .disabled(!isTranslateEnabled)
                .accessibilityIdentifier("messageDetail.toolbar.more.hidden.translate")
        case .mute:
            Button { onToggleMute() } label: {
                Label(isMuted ? "ミュート解除" : "スレッドをミュート", systemImage: isMuted ? "bell" : "bell.slash")
            }
            .accessibilityIdentifier("messageDetail.toolbar.more.hidden.mute")
        case .pin:
            Button { onTogglePin() } label: {
                Label(isPinned ? "ピン留めを解除" : "ピン留め", systemImage: isPinned ? "pin.slash" : "pin")
            }
            .accessibilityIdentifier("messageDetail.toolbar.more.hidden.pin")
        case .markUnread:
            Button { onMarkUnread() } label: { Label(action.title, systemImage: action.systemImage) }
                .accessibilityIdentifier("messageDetail.toolbar.more.hidden.markUnread")
        case .archive:
            Button { onArchive() } label: { Label(action.title, systemImage: action.systemImage) }
                .accessibilityIdentifier("messageDetail.toolbar.more.hidden.archive")
        case .junk:
            Button { onJunk() } label: { Label(action.title, systemImage: action.systemImage) }
                .accessibilityIdentifier("messageDetail.toolbar.more.hidden.junk")
        case .draftEnglishReply:
            if let onDraftEnglishReply {
                Button { onDraftEnglishReply() } label: { Label(action.title, systemImage: action.systemImage) }
                    .accessibilityIdentifier("messageDetail.toolbar.more.hidden.draftEnglishReply")
            }
        case .delete:
            Button(role: .destructive) { onDelete() } label: { Label(action.title, systemImage: action.systemImage) }
                .accessibilityIdentifier("messageDetail.toolbar.more.hidden.delete")
        case .viewSource:
            Button { onViewSource() } label: { Label(action.title, systemImage: action.systemImage) }
                .accessibilityIdentifier("messageDetail.toolbar.more.hidden.viewSource")
        case .more:
            // `more`自身は非表示にできない (`MessageToolbarSettingsStore`の
            // 不変条件) — `hiddenActions`にこの値が来ることはない。
            EmptyView()
        }
    }

    /// 「その他」メニューの中身は、もう固定項目をほとんど持たない —
    /// 非表示にした13アクションすべてが`hiddenActionMenuItems`経由で動的に
    /// 並ぶ。唯一の固定項目「ツールバーをカスタマイズ」はメッセージへの
    /// 操作ではなく設定画面へのショートカットなので、
    /// `MessageToolbarAction`化せずここに直書きしたまま (指示どおり)。
    private var moreMenuButton: some View {
        Menu {
            hiddenActionMenuItems

            Button { onCustomizeToolbar() } label: { Label("ツールバーをカスタマイズ", systemImage: "slider.horizontal.3") }
                .accessibilityIdentifier("messageDetail.toolbar.more.customize")
        } label: {
            toolbarIcon(.more)
        }
        .accessibilityIdentifier("messageDetail.toolbar.more")
    }

    /// - Parameters:
    ///   - title/systemImage: 既定は`action`自身の静的な値だが、状態で
    ///     見た目が変わるトグル (`muteButton`/`pinButton`) が上書きできる。
    ///   - tint: 既定は`OtegamiColor.accent`。`deleteButton`だけが
    ///     `OtegamiColor.destructive`で上書きする。
    private func toolbarIcon(
        _ action: MessageToolbarAction,
        title: String? = nil,
        systemImage: String? = nil,
        tint: Color = OtegamiColor.accent
    ) -> some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage ?? action.systemImage)
                .font(.system(size: 18))
            // `.lineLimit(1)`: 横スクロールへのフォールバック
            // (`body`の`ViewThatFits`) は各ボタンの理想幅の合計で判定される
            // — ラベルの折り返しを許すと、大きな文字サイズ設定下では横に
            // あふれる代わりに縦に折り返して(最悪1文字ずつ改行して)理想幅
            // 自体は小さいまま収まってしまい、スクロールへ切り替わるべき
            // 場面でも切り替わらず、崩れた見た目のまま`fixedRow`が選ばれ
            // 続ける。1行固定にすることで理想幅がラベルの実サイズを正しく
            // 反映するようになり、収まらない場合に`scrollableRow`へ確実に
            // フォールバックする。
            Text(title ?? action.title)
                .font(OtegamiFont.badge())
                .lineLimit(1)
        }
        .foregroundStyle(tint)
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
            // `.lineLimit(1)`: `toolbarIcon(_:title:systemImage:tint:)`の
            // 同名の doc comment と同じ理由 — 要約/翻訳も`fixedRow`/
            // `scrollableRow`の判定対象なので、ここだけラベルの折り返しを
            // 許すと横スクロールへ切り替わるべき場面を見逃す。
            Text(action.title)
                .font(OtegamiFont.badge())
                .lineLimit(1)
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
