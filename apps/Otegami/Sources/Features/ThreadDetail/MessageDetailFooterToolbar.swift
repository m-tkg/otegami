import SwiftUI
import OtegamiCore
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
/// はこのツールバーには描画せず、`moreMenuButton`の「その他」メニュー内の
/// サブメニュー`hiddenActionsMenu`に項目として追加表示する
/// (`hiddenActionMenuItems`) — つまり「その他」の中身は「ユーザーが非表示に
/// したアクション」で完全に説明できる。「その他」自身と、この画面自体を
/// 開く「ツールバーをカスタマイズ」ショートカット (`onCustomizeToolbar`、
/// メッセージへの操作ではないためアクション化していない) は非表示にできず
/// 常に最後尾・末尾固定 — Task #188 以降「ツールバーをカスタマイズ」は
/// 可変長になり得る`hiddenActionsMenu`とは別階層のトップレベル項目になって
/// おり、その分離自体が位置安定化の実装 (`moreMenuButton`のdoc comment
/// 参照)。表示オンのアクションが
/// 画面幅に収まらない場合 (大きな文字サイズ設定・狭い端末幅・多くの
/// アクションを表示オンにした場合等) は、既定の均等配置 (`fixedRow`) の
/// 代わりにインジケータ非表示・左端起点の横スクロール (`scrollableRow`)
/// にフォールバックする — `body`の`ViewThatFits`のdoc comment参照。
///
/// 「返信」は返信/全員に返信の2択を持つ `Menu` (design-phase-3 の「返信/
/// 全員に返信/英語で返信を下書き」ボタン群のうち、返信系2つをここに統合。
/// 「英語で返信を下書き」自体は Task #139 で撤去済み — 翻訳ボタンの
/// 常時有効化 (#138) もあり冗長と判断された)。
///
/// `onSearch` が `nil` のときはそのアイコン自体を出さない (macOS 側で
/// 配線していない — 新しい検索画面は iOS のみのインフラのため)。
///
/// Task #88 (「要約と翻訳のボタンをフローティングをやめてツールバーに入れて」):
/// `aiFeaturesState`が要約/翻訳の2アイコンの唯一の状態源 — `MessageView`が
/// 現在展開中のメッセージについて書き込み、この`nil`許容の`class`参照を
/// そのまま保持するだけで`@Observable`のプロパティ単位追跡により再描画され
/// る (`MessageDetailAIFeaturesState`のdoc comment、以前の
/// `MessageDetailFloatingButtons`と同じ仕組み)。`nil`(まだ何も展開されて
/// いない、アコーディオン切替の谷間)、または`showsSummaryButton`/
/// `showsTranslationButton`/`isSummarizationAvailable`/`isTranslationAvailable`
/// (Task #159 で要約と翻訳が別エンジンになったため availability も2つに分離
/// — `isSummarizeEnabled`/`isTranslateEnabled`参照) が偽の間は、アイコン
/// 自体を消さず**グレーアウト**して並びを安定させる (指示どおり)。
struct MessageDetailFooterToolbar: View {
    var onReply: () -> Void
    var onReplyAll: () -> Void
    var onForward: () -> Void
    var onSearch: (() -> Void)?
    var onInfo: () -> Void
    var isMuted: Bool
    var onToggleMute: () -> Void
    var onMarkUnread: () -> Void
    var onArchive: () -> Void
    /// Task #184 (「アーカイブ済みのメールの操作」実機フィードバック「アーカイブ
    /// ボタンはアーカイブ解除ボタンにして欲しい」): `true` while the currently
    /// displayed thread/message is already archived (`ThreadDetailView
    /// .isThreadArchived`'s doc comment covers exactly how that's decided,
    /// including the partially-archived-thread call). Swaps `archiveButton`'s
    /// and its "その他"-menu counterpart's label/icon to "アーカイブ解除" the
    /// same way `isMuted`/`isPinned` already swap `muteButton`/`pinButton` —
    /// `onArchive` itself stays a single callback either way
    /// (`ThreadDetailView.archiveThread()` is what actually decides
    /// `.archive` vs. `.unarchive`), matching how `onToggleMute`/
    /// `onTogglePin` already work.
    var isArchived: Bool
    var onJunk: () -> Void
    /// 「迷惑メール解除」: `isArchived` の迷惑メール版 — `true` の間だけ
    /// `junkButton` と「その他」メニューの対応項目が「迷惑メール解除」に
    /// なる。`onJunk` はどちらでも同じ 1 コールバックのまま
    /// (`ThreadDetailView.junkThread()` が `.junk`/`.unjunk` を決める)。
    var isJunk: Bool
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

    // Task #113 (2) (実機フィードバック「ボタンのラベルを表示」トグル):
    // `rawOrder`と同じ理由で`@AppStorage` — `MessageToolbarSettingsView`が
    // このキーへ書き込んだ瞬間、シートを閉じずともこのツールバーが即座に
    // アイコンのみ/アイコン+ラベルを切り替える。
    @AppStorage(MessageToolbarSettingsStore.showsLabelsKey) private var showsLabels = MessageToolbarSettingsStore.defaultShowsLabels

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
        toolbarBar
            .accessibilityIdentifier("messageDetail.footerToolbar")
    }

    /// Liquid Glass Phase 2 準備リファクタリング (見た目は変えない):
    /// 旧`body`が1つの式の中に持っていた「行の組み立て
    /// (`ViewThatFits`)」と「クローム側の修飾子チェーン (ボタン
    /// スタイル・パディング・背景)」を、それぞれ独立した computed
    /// property (`toolbarRow`/`toolbarBar`) に分割した。Glass化
    /// (プラットフォーム分岐の追加) はこの2つのうち`toolbarBar`だけを
    /// 触れば済むようにするための準備 — CI の型チェックタイムアウト
    /// 前例 (`docs/ci.md`) を踏まえ、長い modifier チェーンを`body`
    /// 直下の1つの式に積み上げ続けないための切り出し。
    private var toolbarRow: some View {
        ViewThatFits(in: .horizontal) {
            fixedRow
            scrollableRow
        }
    }

    private var toolbarBar: some View {
        toolbarRow
        // Task #198 (実機フィードバック「メールビューでのアイコンが大きすぎる
        // しバランスがおかしい。もっとコンパクトなアイコンにして」):
        // 大きさの出どころは明示サイズでもパディングでもなく**ボタン
        // スタイル**だった — このツールバーはどのボタン/`Menu`にも
        // `.buttonStyle`/`.menuStyle`を指定していなかったため、macOS既定の
        // bordered風スタイル (各アイコンごとに濃い角丸の背景を描く) が
        // 適用されていた。実機スクリーンショットで確認: `toolbarIcon`
        // 自体のサイズ指定 (アイコン18pt+`.otegamiMinimumTappable()`の
        // 44×44) は iOS と共通で以前から変わっておらず、大きな角丸の
        // 背景こそが macOS だけで見えていた"想定外の追加分"だった。
        // `.buttonStyle(.plain)`(プレーンな`Button`用)+`.menuStyle
        // (.borderlessButton)`(`replyMenuButton`/`moreMenuButton`の`Menu`
        // 用、`.buttonStyle`は`Menu`には効かないため別指定が要る) を
        // ここ1箇所に集約して環境経由で全ボタン/`Menu`へカスケードさせ、
        // このアプリの他の場所と同じ「背景なし、素のアイコン」という
        // ボーダーレスな見た目に揃えた。**iOS は無条件に無変更**
        // (`#if os(macOS)`の外)。
        #if os(macOS)
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        #endif
        .padding(.horizontal, OtegamiSpacing.sm)
        .padding(.vertical, OtegamiSpacing.sm)
        // Liquid Glass Phase 2 (`docs/design-system.md`「Liquid Glass 方針」):
        // クローム層 (このツールバー自体) の不透明な`surface`塗りを、15個の
        // アイコンが密集して並ぶ密度を踏まえてバー全体1枚の Glass カプセル
        // へ置き換えた — アイコンごとに`.buttonStyle(.glass)`を配ると密集時
        // に個々のカプセルが重なり合ってしまうため、`AccountFilterChip`
        // (チップ単体) とは違いバー単位でまとめる方を選んだ。`GlassEffectContainer`
        // は使っていない — あれは`SpeedDialFAB`のように複数の`glassEffect`
        // シェイプを共有`Namespace`でモーフィングさせる用途で、このバーは
        // 単一シェイプなので不要 (`otegamiGlassChrome`と同じ理屈)。
        // `Capsule()`は端まで半円になるため、画面端に接したまま (旧`surface`
        // 塗りと同じフルブリード) だと丸い端が画面外で切れて見える —
        // それを避けるため外側に水平/下マージンを足し、フローティングする
        // ピル型として画面内に収める。macOS はこの節すべて対象外 (`#if
        // os(macOS)`で従来どおり`surface`塗りのまま、CLAUDE.md の「macOS
        // は現状維持」)。
        #if os(iOS)
        .otegamiGlassChrome(shape: Capsule())
        .padding(.horizontal, OtegamiSpacing.md)
        .padding(.bottom, OtegamiSpacing.xs)
        #else
        .background(OtegamiColor.surface)
        #endif
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

    /// Task #184: state-dependent the same way `muteButton`/`pinButton` are —
    /// see `isArchived`'s doc comment. "アーカイブ解除" uses `tray.and.arrow.up`
    /// (a tray with an upward arrow, echoing "put it back"), the same icon
    /// `MessageListRow.archiveLabel`'s already-shipped list-swipe equivalent
    /// (Task #87 (1)) uses for the identical reversed action — so a user
    /// who's already learned that icon from the list sees the same one here.
    @ViewBuilder
    private var archiveButton: some View {
        Button(action: onArchive) {
            toolbarIcon(.archive, title: isArchived ? "アーカイブ解除" : nil, systemImage: isArchived ? "tray.and.arrow.up" : nil)
        }
        .accessibilityIdentifier("messageDetail.toolbar.archive")
    }

    /// 「迷惑メール解除」: `archiveButton` と同じ状態依存の差し替え — see
    /// `isJunk`'s doc comment. アイコンは `checkmark.shield`(「迷惑メール
    /// ではない」)、`MessageListRow` のスワイププレビューと同じもの。
    @ViewBuilder
    private var junkButton: some View {
        Button(action: onJunk) {
            toolbarIcon(.junk, title: isJunk ? "迷惑メール解除" : nil, systemImage: isJunk ? "checkmark.shield" : nil)
        }
        .accessibilityIdentifier("messageDetail.toolbar.junk")
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
    /// Task #159: reads `isSummarizationAvailable` (Foundation Models'
    /// own availability), not `isTranslationAvailable` — before this task,
    /// one `TranslationService` backed both translate and summarize, so a
    /// single availability flag correctly gated both buttons; now that
    /// they're two different engines (`FoundationModelsTranslationService`/
    /// `AppleTranslationService`) with two different availability stories,
    /// this button needs the summarization-specific one.
    private var isSummarizeEnabled: Bool {
        aiFeaturesState?.showsSummaryButton == true && aiFeaturesState?.isSummarizationAvailable == true
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
        //
        // Task #202 (実機フィードバック: 長いエラー文言の帯が画面右外へ
        // はみ出し、末尾の数文字しか見えない): この場所にあった裸の
        // `.fixedSize()` (両軸ともideal sizeを使う指定) が原因だった —
        // `translateFootnoteCaption`内部の`.fixedSize(horizontal: false,
        // vertical: true)`+`.frame(maxWidth: 200)`は「幅200ptで折り返す」
        // つもりだったが、`.overlay`はデフォルトで中身に対して土台の
        // ボタン (44pt) と同じ提案幅しか渡さないため、それを避けようと
        // 追加されたこの外側の裸`.fixedSize()`が「提案幅を一切受け取らず
        // 単一行の自然な幅で自己主張しろ」という指定になってしまい、
        // 200ptでの折り返しを無効化していた — 結果、長文だとボタンの
        // 位置 (並び替え可能なツールバーのため画面端に来ることがある)
        // を中心に数百ptの帯ができ、画面外へ大きくはみ出していた。
        // 削除して`translateFootnoteCaption`内部の指定 (折り返しは許可
        // ・幅は200ptで頭打ち) だけに委ねる。
        .overlay(alignment: .top) {
            if let translateFootnote {
                translateFootnoteCaption(translateFootnote)
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
        case .none, .failed, .insufficientInput:
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
        case .failed, .insufficientInput: String(localized: "翻訳を再試行")
        case .translated: aiFeaturesState.translationShowOriginal ? String(localized: "訳文に戻す") : String(localized: "原文に戻す")
        }
    }

    /// 旧`TranslationFloatingButton.footnote`と同一のロジック — `String
    /// (localized:)`を通さない理由もそのまま (`message`が実行時の値を
    /// 含むため)。2026-07-30 (Phase 5続報): `.failed`/`.insufficientInput`
    /// を`MessageTranslationState.failureMessage`という共通アクセサ経由で
    /// 同列に扱う — 呼び出し側 (このView) がケースを2つ書き分ける必要が
    /// なくなり、将来ケースが増えてもここを直し忘れるリスクを減らす。
    private var translateFootnote: String? {
        guard let aiFeaturesState else { return nil }
        if let message = aiFeaturesState.translationState.failureMessage {
            return "翻訳に失敗しました: \(message)"
        }
        if case .translated(let record) = aiFeaturesState.translationState, record.hasPartiallyBlockedContent {
            return "一部の文は翻訳できませんでした"
        }
        return nil
    }

    private var translateFootnoteTone: Color {
        if let aiFeaturesState, aiFeaturesState.translationState.failureMessage != nil { return OtegamiColor.destructive }
        return OtegamiColor.inkSecondary
    }

    /// Task #202 (実機フィードバック: 帯が画面右外へはみ出し末尾しか見えない
    /// — 根本原因は呼び出し元にあった裸`.fixedSize()`で、そちらは削除済み
    /// (`translateButton`のdoc comment参照)。ここでの指定はそれを前提に、
    /// 実際に「幅140〜190ptに収まる・それを超える分は折り返す」を成立
    /// させるための組み合わせ — レンダリング比較用の一時スクリプト
    /// (`ImageRenderer`で実際にPNG出力して確認、コミットはしていない)
    /// で複数の幅/行数の組み合わせを試した上で決めた:
    /// - `.fixedSize(horizontal: false, vertical: true)`: 横方向は「親から
    ///   提案された幅を受け入れる」(=縮められる・折り返せる)、縦方向は
    ///   「中身の折り返し後の行数ぶんだけ縦に伸びる」。
    /// - `.frame(minWidth:maxWidth:alignment:)`: `.overlay(alignment: .top)`
    ///   は既定でこの吹き出しに土台のアイコン (44pt) 相当の**狭い**幅しか
    ///   提案してこない — `maxWidth`だけでは提案がそもそも140pt未満なら
    ///   頭打ちが一度も効かず、`Text`は行あたり2〜3文字の縦に長い列に
    ///   なってしまう (実機/レンダリング比較で確認済み)。`minWidth: 140`
    ///   がこの狭い提案を底上げし、`maxWidth: 190`が逆に長い文言を
    ///   頭打ちして折り返させる — 実際の利用者向け文言
    ///   (`TranslationServiceError.userFacingMessage`、診断カウンタを
    ///   含まない短い定型文に統一済み) はこの範囲で2〜3行に収まる。
    /// - `.multilineTextAlignment(.center)`: 折り返して複数行になった
    ///   場合に左詰めではなく中央揃えで読みやすくする。
    /// - `.lineLimit(4)`: 保険 — 何らかの理由で極端に長い文言が来ても
    ///   帯が縦に際限なく伸びず、超過分は`Text`既定の`.truncationMode
    ///   (.tail)`で省略される。
    ///
    /// **既知の残存リスク**: ボタン中心アンカー方式のまま (アイコンの
    /// 真上に表示する、という既存の設計意図を維持) のため、翻訳ボタンが
    /// カスタマイズで画面の最も端 (先頭/末尾) に来た状態で失敗した場合、
    /// 帯の左右の吹き出し部分 (中心から片側最大95pt) が画面端ぎりぎりで
    /// わずかに切れる可能性はまだ理論上残る — ただし文言を短い定型文に
    /// 揃えたことと合わせ、以前の「裸`.fixedSize()`で数百pt単位に膨張し
    /// 画面の大半を覆う」規模の実害とは質的に別物 (数十pt程度の残存
    /// リスク)。アイコン位置を検知して吹き出しの寄せ方向を動的に変える
    /// (GeometryReader + PreferenceKeyでボタンの画面上位置を取得) までは
    /// 本タスクではやらなかった — この吹き出しはエラー発生時のみ一時的に
    /// 出る注記であり、常時表示のUIほど厳密な位置保証を要求しないと
    /// 判断したため。今後さらに気になる実機報告があれば、その時点で
    /// 動的アンカーへ拡張する。
    private func translateFootnoteCaption(_ text: String) -> some View {
        Text(text)
            .font(OtegamiFont.badge())
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .padding(.horizontal, OtegamiSpacing.sm)
            .padding(.vertical, OtegamiSpacing.xs)
            // Liquid Glass Phase 2: この吹き出しはトースト/バナー相当の
            // クローム要素なので、不透明な`translateFootnoteTone`塗りから
            // 同じ色を`.tint`したガラス (`SpeedDialFAB`の compose ボタンが
            // `.regular.tint(OtegamiColor.accent)`で強調色を乗せているのと
            // 同じ手法) へ — 意味を持つ色 (失敗=destructive/通常=inkSecondary)
            // 自体は変えず、塗りの質感だけガラスに揃える。macOS は対象外
            // (`otegamiGlassChrome`と同じ理屈、CLAUDE.md「macOS は現状維持」)。
            #if os(iOS)
            .glassEffect(.regular.tint(translateFootnoteTone), in: Capsule())
            #else
            .background(translateFootnoteTone, in: Capsule())
            #endif
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 140, maxWidth: 190, alignment: .center)
            .accessibilityIdentifier("messageDetail.toolbar.translate.footnote")
    }

    // MARK: - Task #100: 非表示にしたアクションを「その他」メニューへ移動

    /// `hiddenActions`それぞれをメニュー項目として並べる。`.reply`は元が
    /// サブメニュー (返信/全員に返信の2択) なので、非表示時は2つのフラット
    /// な項目に展開する。`moreMenuButton`直下に並び、その末尾で
    /// 「ツールバーをカスタマイズ」と区切り線で分かれる。
    @ViewBuilder
    private var hiddenActionMenuItems: some View {
        ForEach(hiddenActions) { action in
            hiddenActionMenuItem(for: action)
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
            // Task #184: same state-dependent swap as `.mute`/`.pin` above.
            Button { onArchive() } label: {
                Label(isArchived ? "アーカイブ解除" : action.title, systemImage: isArchived ? "tray.and.arrow.up" : action.systemImage)
            }
            .accessibilityIdentifier("messageDetail.toolbar.more.hidden.archive")
        case .junk:
            // 「迷惑メール解除」: same state-dependent swap as `.archive` above.
            Button { onJunk() } label: {
                Label(isJunk ? "迷惑メール解除" : action.title, systemImage: isJunk ? "checkmark.shield" : action.systemImage)
            }
            .accessibilityIdentifier("messageDetail.toolbar.more.hidden.junk")
        case .delete:
            // 実機フィードバック (Task #113 (1)):「ツールバーをカスタマイズ」
            // ショートカット (`moreMenuButton`末尾固定) が、状態によって
            // メニュー内の位置がずれる報告があった。原因は`role:
            // .destructive`— iOS は`Menu`内の破壊的操作ボタンをコード上の
            // 位置に関わらず自動的に他の項目より下 (メニュー本当の最後尾)
            // へ移動する。「削除」がここ (「その他」入り、既定でここに
            // いる) に来ると、コード上その後ろにある「ツールバーを
            // カスタマイズ」ボタンより「削除」の方が下に描画されてしまい
            // (「オフ項目数」= ここに「削除」を含むかどうかで発生有無が
            // 変わる、というのがまさに実機報告の「状態で順序が変わる」の
            // 実体)、「カスタマイズ」が最下部でなくなる。`role:
            // .destructive`を外し、赤い見た目だけを`.tint`で再現すること
            // で、この自動並び替えの対象から外し、コード上の並び (=常に
            // `hiddenActionMenuItems`の末尾) がそのまま最終的な見た目の
            // 順序になるようにした。
            Button { onDelete() } label: { Label(action.title, systemImage: action.systemImage) }
                .tint(OtegamiColor.destructive)
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

    /// Task #188 (実機報告「『ツールバーをカスタマイズ』の位置が一番下に
    /// なることがある」): 原因は`.menuOrder`の既定値`.automatic`。
    ///
    /// iOS の`.automatic`は**メニューが開く向きに合わせて項目順を反転
    /// させる** — ボタンに近い側を先頭にするための挙動で、下向きに開けば
    /// ソース順、上向きに開けば逆順に描画される。このメニューはフッター
    /// ツールバー (画面最下部) から開くので通常は上向きだが、詳細画面の
    /// スクロール位置や項目数によって実際の開く向きは変わり、そのたびに
    /// 並びが丸ごとひっくり返る。実機のスクリーンショット2枚で、
    /// 「Search→…→区切り線→ツールバーをカスタマイズ」と
    /// 「ツールバーをカスタマイズ→区切り線→…→Search」の**完全な逆順**が
    /// 確認されている (「ツールバーをカスタマイズ」だけが動くのではなく
    /// メニュー全体が反転する、というのが症状の実体)。
    ///
    /// `.menuOrder(.fixed)`は、この自動反転を止めてソース順を常に維持
    /// する。項目数にも開く向きにも依存しなくなる。
    ///
    /// なお Task #113 (1) の「削除が最後尾へ飛ぶ」は`role: .destructive`
    /// による別の並べ替え (`hiddenActionMenuItem(for:)`の`.delete`ケース
    /// のdoc comment参照)。そちらは対処済みで、今回のとは別の仕組み。
    private var moreMenuButton: some View {
        Menu {
            hiddenActionMenuItems
            if !hiddenActions.isEmpty {
                Divider()
            }
            Button { onCustomizeToolbar() } label: { Label("ツールバーをカスタマイズ", systemImage: "slider.horizontal.3") }
                .accessibilityIdentifier("messageDetail.toolbar.more.customize")
        } label: {
            toolbarIcon(.more)
        }
        .menuOrder(.fixed)
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
        // Task #113 (2): `showsLabels`が off の間は`Text`自体を出さない
        // (アイコンのみ) — `VStack`の`spacing`も`MessageToolbarIconLayout
        // .iconLabelSpacing`経由で0に詰め、ラベルが無くなった分の余白が
        // 残らないようにする (`OtegamiCore`側のdoc comment「高さも詰める」
        // 参照)。
        VStack(spacing: CGFloat(MessageToolbarIconLayout.iconLabelSpacing(showsLabels: showsLabels))) {
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
            if showsLabels {
                Text(title ?? action.title)
                    .font(OtegamiFont.badge())
                    .lineLimit(1)
            }
        }
        .foregroundStyle(tint)
        .otegamiMinimumTappable()
        // 実機フィードバック (iPad)「要約ボタンを押せない時がある」: ヒット
        // 領域は`.otegamiMinimumTappable()`の 44pt (下限のみ) で決まる一方、
        // `fixedRow`のスロットは`.frame(maxWidth: .infinity)`で等幅に広がる —
        // iPhone ではスロット≈54pt で差は片側 5pt 程度だが、iPad の広い
        // detail ペインではスロットが 100pt 超になり、アイコンの見た目の
        // 「持ち分」の中に片側 30pt 以上のタップ不能地帯ができていた。
        // ラベル側 (Buttonの内側) をスロット幅まで広げて`.contentShape`を
        // 張り直すことで、スロット全域をヒット領域にする。`scrollableRow`
        // では`ScrollView`が幅を提案しない (ideal で並べる) ため
        // `maxWidth: .infinity`は効かず 44pt のまま — `ViewThatFits`の
        // 判定基準である理想幅も変わらない (`body`のdoc comment参照)。
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
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
        // Task #113 (2): `toolbarIcon(_:title:systemImage:tint:)`と同じ
        // ラベル表示/非表示の扱い。
        VStack(spacing: CGFloat(MessageToolbarIconLayout.iconLabelSpacing(showsLabels: showsLabels))) {
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
            if showsLabels {
                Text(action.title)
                    .font(OtegamiFont.badge())
                    .lineLimit(1)
            }
        }
        .foregroundStyle(tone.color)
        .otegamiMinimumTappable()
        // `toolbarIcon(_:title:systemImage:tint:)`末尾の同名修正と同じ —
        // iPad の広いスロットでのタップ不能地帯を無くす (そちらのdoc
        // comment参照)。
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// Task #88: 旧`TranslationBar.swift`(`TranslationFloatingButton`) が持って
/// いた同名のprivate extensionをそのまま引き継いだ — 唯一の利用元が
/// `translateTone`に変わっただけ。
private extension MessageTranslationState {
    /// 2026-07-30 (Phase 5続報): `.insufficientInput`も`.failed`と同じ
    /// 「失敗」トーンとして扱う — `failureMessage`(共通アクセサ) が
    /// `nil`でないかどうかで判定するので、将来ケースが増えても書き忘れ
    /// にくい。
    var isFailure: Bool {
        failureMessage != nil
    }
}
