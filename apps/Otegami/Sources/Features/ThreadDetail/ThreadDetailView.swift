import SwiftUI
import GRDB
import OtegamiCore
import OtegamiStore
import SyncEngine
import MailTransport
import OtegamiTranslation
import os

/// M4's thread reading view: every message in the thread laid out
/// vertically, newest expanded, everything older collapsed to a one-line
/// summary (plan: "スレッド内メッセージを縦列挙、最新以外は折り畳み（ヘッダタップ
/// で展開）"). A thread with exactly one message degenerates naturally to
/// "one expanded row, nothing to collapse" — the same view handles both
/// cases with no special-casing.
///
/// Only marks a message read once it's actually expanded (plan: "スレッドの
/// 既読化は展開したメッセージのみ") — `MessageView` (embedded per expanded row)
/// is what triggers a read, and it's only ever instantiated for the
/// currently-expanded message id, so a collapsed row's body is never even
/// fetched, let alone marked read.
///
/// 新画面構成 (3): owns the screen-level footer toolbar
/// (`MessageDetailFooterToolbar`, `.safeAreaInset(edge: .bottom)`) that
/// replaced `MessageView`'s old per-message 返信/全員に返信/英語で返信を
/// 下書き row (「英語で返信を下書き」自体は Task #139 で撤去済み).
/// "返信"/"転送"/"検索" all act on **whichever message is
/// currently expanded** (`targetMessage`) — 実機フィードバック第2弾 (E)
/// made this unambiguous by turning message expansion into a strict
/// accordion (`expandedMessageId`, exactly one message expanded at a time),
/// so "the footer toolbar's target" and "the message you're currently
/// reading" are now always the same row. Before E, any collapsed message
/// could *also* be expanded independently (a Gmail/Apple-Mail-style
/// multi-expand thread view), so the footer toolbar's target was pinned to
/// the thread's newest message regardless of which row(s) were actually
/// open — `RootView`'s macOS ⇧⌘R shortcut still documents that older
/// "newest message" rule for its own, `ThreadDetailView`-independent
/// implementation (`RootView.replyToSelectedThread()`'s doc comment).
struct ThreadDetailView: View {
    @Environment(AppEnvironment.self) var environment
    @Environment(\.dismiss) var dismiss
    let threadId: Int64
    /// 実機フィードバック第3弾 (A): non-`nil` when this screen should show
    /// just one specific message rather than every message in `threadId` —
    /// restricts `load()` accordingly, so a real (possibly multi-message)
    /// conversation shows only that one tapped message, not the full
    /// accordion stack. A real-device report ("スレッドをオフにしても
    /// スレッドになる") traced to this screen always loading the whole
    /// underlying thread regardless of the flat/grouped display setting.
    ///
    /// Non-`nil` only for **a flat-mode row, or a flat search result**
    /// (`ListDisplaySettingsStore.threadingKey` OFF — `MessageListView`'s
    /// doc comment on why a flat row still carries its *real* underlying
    /// `threadId`) — `ThreadEntryView` forwards it straight through as
    /// `preselectedMessageId`. 画面構造改修バッチ (Task #33, 1) briefly had
    /// a second, grouped-mode reason too (a multi-message thread resolved
    /// to one message via the now-removed `ThreadSelectionView`); Task #136
    /// (実機フィードバック「アコーディオンに戻してほしい」) reverted that —
    /// `ThreadEntryView` no longer resolves a grouped-mode thread to any
    /// single message, so every grouped-mode open is `nil` again, letting
    /// this view's own full-thread accordion (below) render.
    ///
    /// `nil` also for macOS's 3-pane `detailColumn` (`OtegamiApp.swift`)
    /// showing a real grouped-mode thread directly, and for macOS's
    /// restored "last opened thread" (which only ever remembers a thread
    /// id, not a message id — see `RootView
    /// .lastOpenedThreadIdBySelectionKey`'s doc comment on that narrower,
    /// accepted gap).
    var singleMessageId: Int64?
    /// 画面構造改修バッチ (Task #33, 3の続きで発覚した回帰の修正): whether
    /// `singleMessageId` is non-`nil` *because this is fundamentally a
    /// flat-mode (one-message-per-row) entry* — a flat list row, or a flat
    /// search result. `notifyThreadRemoved()` reads this (not a plain
    /// `singleMessageId == nil` check) to decide whether "次のメールを開く"
    /// applies (see that method's doc comment for why). Task #136 reverted
    /// the brief period (画面構造改修バッチ Task #33, 1 → Task #136) where a
    /// **grouped**-mode thread could *also* carry a non-`nil`
    /// `singleMessageId` (resolved via the now-removed `ThreadSelectionView`)
    /// — every call site once again passes `isFlatModeEntry: singleMessageId
    /// != nil` (`ThreadEntryView`/`OtegamiApp.detailColumn`), so this flag is
    /// functionally redundant with that check again today. Kept as its own
    /// explicit parameter anyway (rather than collapsing back to reading
    /// `singleMessageId` directly at each use site) — it names the actual
    /// semantic distinction `notifyThreadRemoved()` cares about, and keeps
    /// that call site working unchanged if a future change ever reintroduces
    /// a grouped-mode single-message resolution the way Task #33 briefly
    /// did. Defaults to `true`, matching every existing call site.
    var isFlatModeEntry = true
    /// M5/design-phase-3: forwarded to each expanded `MessageView` — see
    /// its `onReply` doc comment. Task #139 dropped the third `Bool`
    /// (「英語で返信を下書き」フラグ、`ComposerLaunchPayload
    /// .translateToEnglish`へ連鎖していた) — この撤去に伴い削除。
    var onReply: (Int64, Bool) -> Void = { _, _ in }
    /// 新画面構成 (3): フッターツールバーの「転送」— see
    /// `ComposerLaunchPayload.Kind.forward`'s doc comment.
    var onForward: (Int64) -> Void = { _ in }
    /// 新画面構成 (3): フッターツールバーの「検索」— "そのメールの from で
    /// 絞り込まれた状態で開く"。`nil` だとアイコン自体を出さない
    /// (`MessageDetailFooterToolbar`'s doc comment — macOS では未配線)。
    var onSearchFromSender: ((String) -> Void)?
    /// Task #184: called every time `isThreadArchived` is (re)computed —
    /// lets a caller with its own macOS ⌘E menu label (`RootView
    /// .isSelectedThreadArchived`, `OtegamiApp.swift`'s `detailColumn`) stay
    /// in sync with this same thread's live archived state instead of
    /// running a second, independent query. `nil` (the default — every
    /// other call site, notably iOS's `ThreadEntryView`, which has no
    /// equivalent menu-bar surface to update) is a plain no-op.
    var onArchivedStateChanged: ((Bool) -> Void)?
    /// G「削除・アーカイブ時の挙動」: called (instead of always popping back)
    /// once `archiveThread()`/`junkThread()`/`deleteThread()` successfully
    /// removes this thread — the caller (whichever screen owns the
    /// currently-displayed thread order and the `selectedThreadId`/
    /// equivalent binding: `MailScreenView` on iOS, `RootView` on macOS)
    /// resolves `MessagePostActionSettingsStore`'s setting against that
    /// order and either opens the next thread or pops back, by mutating its
    /// own selection state — `ThreadDetailView` itself has no access to
    /// sibling `MessageListView`'s live thread order, so it can only ever
    /// report "this thread is gone now", never decide what comes next.
    /// `nil` (the default — `SearchScreenView`'s push, which doesn't wire
    /// this) falls back to the pre-existing unconditional `dismiss()`, so
    /// this setting simply doesn't apply to a thread opened from a search
    /// result (a separate, less central browsing order this batch didn't
    /// extend the setting to).
    var onThreadRemoved: ((Int64) -> Void)?

    @State var accountId: String?
    @State var messages: [MessageRecord] = []
    /// 実機フィードバック第2弾 (E): a strict accordion — at most one message
    /// expanded at a time, unlike the previous `Set<Int64>` (which let
    /// several rows stay independently expanded, Gmail/Apple-Mail-style).
    /// Tapping a collapsed message's header expands it and collapses
    /// whatever was expanded before (`toggleExpanded(_:)`).
    ///
    /// **実機報告 (2026-07-29、Task #140 と同時期の追加報告)**: 展開中
    /// メッセージ自身の「^」(上向きシェブロン、`ThreadMessageSummaryRow
    /// .chevronSystemImage`) をタップしても畳めなかった — 元は「tapping
    /// the already-expanded message's header is a no-op」設計で、
    /// `toggleExpanded(_:)`が同じidへのタップを弾いていたため。「全閉じは
    /// 到達しない状態」という前提を仕様変更し、`nil`(全メッセージ折り
    /// たたみ、ヘッダ行だけ並ぶ「見渡し」用の状態)を明示的に許可した —
    /// `load()`が初回に1通だけpinする挙動 (`hasPinnedInitialExpansion`)
    /// はそのまま(初回は必ず最新の1通が開く)、以降はユーザーが「^」で
    /// いつでも全閉じにでき、別の行をタップすればいつもどおりその1通だけ
    /// が開く(「常に最大1通」制約は維持)。`targetMessage`が`nil`のときは
    /// フッターツールバーの各アクションが安全にno-opする(そのdoc comment
    /// 参照、クラッシュしない)。
    @State private var expandedMessageId: Int64?
    /// Task #146 (実機フィードバック「下の方の折りたたみ行を展開したとき、
    /// 開いたことに気づきにくい」): `FolderListSheet.menuScrollTarget`と
    /// 同じ方式 — `toggleExpanded(_:)`が実際に展開した (collapse ではない)
    /// ときだけここへその`messageId`を入れ、`body`の`ScrollViewReader`の
    /// `.onChange`が拾って`scrollTo(_:anchor: .top)`する。展開行は画面外
    /// (下) に伸びるだけで、ユーザーが自分でスクロールしない限り何も動いて
    /// 見えない問題への対策 — `menuScrollTarget`のdoc comment参照。
    @State private var accordionScrollTarget: Int64?
    @State private var hasPinnedInitialExpansion = false
    @State var isThreadPinned = false
    @State var isThreadMuted = false
    /// Task #184 (「アーカイブ済みのメールの操作」): whether the footer
    /// toolbar's archive slot should act as "アーカイブ解除" instead of
    /// "アーカイブ" — grouped mode reads `ThreadQuery.isThreadArchived`
    /// (Task #151's OR-aggregate: *at least one* message in the thread
    /// already lives in an archived-counting mailbox), flat mode reads
    /// `ThreadQuery.isMessageArchived` for just `singleMessageId`. Computed
    /// at the same granularity `commitRemoval(_:)` actually acts on (the
    /// whole thread for grouped mode, one message for flat mode — see
    /// `threadSummary(threadId:singleMessageId:accountId:db:)`), and refreshed
    /// on every live delivery from `load()`/`loadSingleMessage(_:)`'s
    /// observations, not just once at open — an in-place edit elsewhere
    /// (e.g. another client archiving/unarchiving this same thread) should
    /// flip this screen's button the same way it already flips the list's
    /// `ThreadRowView` badge (`summary.isArchived`).
    ///
    /// **一部だけアーカイブ済みの判定 (根拠)**: intentionally an OR, not an
    /// AND, over the thread's messages — matching `ThreadSummary.isArchived`
    /// /`ThreadRowView`'s existing "アーカイブ済みの可視化" badge (Task #151)
    /// so this screen's button never disagrees with what the list already
    /// showed for the same thread before it was opened. This is also exactly
    /// the granularity `MessageRemoval.commit(.unarchive, ...)` itself
    /// tolerates: its per-message loop only unarchives messages that are
    /// actually sitting in an archived location and silently skips ones that
    /// aren't (`MessageRemoval.Kind.unarchive`'s doc comment), so tapping
    /// "アーカイブ解除" on a thread with, say, 1 archived + 2 still-active
    /// messages correctly restores only the archived one and leaves the
    /// other two exactly where they are — never a destructive "undo
    /// everything" op. The accepted tradeoff: for that same mixed thread,
    /// the two still-active messages can no longer be archived via this
    /// screen's single archive slot until the already-archived one is
    /// unarchived (or the thread splits) — a narrow edge case judged
    /// acceptable rather than adding a second, AND-based "is this thread
    /// *fully* archived" rule that would disagree with the list's own badge.
    @State var isThreadArchived = false
    @State private var showingInfo = false
    @State private var showingSource = false
    @State private var showingToolbarSettings = false
    /// Task #163 (実機フィードバック「ピン留めされたメールはアーカイブできない
    /// ようにしてほしい」): shown when `commitRemoval(.archive)` catches
    /// `MessageRemoval.ArchiveGuardError.pinned` — this screen otherwise has
    /// no toast/notice of any kind (`MARK: 新画面構成 (3): スレッド操作`'s doc
    /// comment: every other action just pops back to the list on success,
    /// which is its own confirmation), so a blocked archive needs one added
    /// specifically for this "nothing happened, and that's not obvious"
    /// case — see `showPinnedArchiveNotice()`.
    @State var pinnedArchiveNotice: String?
    @State var pinnedArchiveNoticeTask: Task<Void, Never>?
    static let pinnedArchiveNoticeWindow: Duration = .seconds(3)
    /// Task #59 (実機フィードバック「要約/翻訳のフローティングアイコンを
    /// 常に左下固定にしてほしい」), Task #88 (フッターツールバーへ移設):
    /// whatever `MessageDetailAIFeaturesState` the currently-expanded row's
    /// `MessageView` last reported (via `ThreadMessageRow
    /// .onAIFeaturesStateChange`, itself just forwarding `MessageView
    /// .onAIFeaturesStateChange`) — `nil` whenever nothing is expanded yet,
    /// or right after the accordion switches to a different message (the old
    /// row's `MessageView.onDisappear` reports `nil` before the
    /// newly-expanded row's `onAppear` reports its own state, so there's at
    /// most one frame with no buttons — matches "現在展開中の単一メッセージ
    /// 基準" from the same accordion invariant `targetMessage` already relies
    /// on). Forwarded straight into `footerToolbar`'s `aiFeaturesState:`
    /// parameter, which is what actually renders the 要約/翻訳 icons from it
    /// now — originally rendered by `body`'s own top-level `overlay`
    /// (removed by Task #88; see `MessageDetailAIFeaturesState`'s doc comment
    /// for the full history of why this state has to live up here at all).
    @State private var expandedAIFeaturesState: MessageDetailAIFeaturesState?
    /// Task #153 (スレッド全体のAI要約): `ThreadSummaryState`のdoc comment
    /// 参照 — このスレッド全体 (`messages`全件) を対象にしたAI要約の進行
    /// 状態。単一メッセージの`expandedAIFeaturesState.summaryState`とは
    /// 完全に独立 (別のツールバーボタン・別のシート・別の生成呼び出し)。
    @State var threadSummaryState: ThreadSummaryState = .none
    @State var isShowingThreadSummarySheet = false
    @State var threadSummaryTask: Task<Void, Never>?
    /// Task #160 (実機フィードバック「複数回 FoundationModel 実行していい
    /// から、時系列で経緯をまとめて欲しい」): `TranslationService
    /// .summarizeThread(_:targetLanguage:onProgress:)`がメッセージ単位で
    /// マップ段を回す (`TranslationService.swift`のdoc comment参照) 分、
    /// メッセージ数が多いスレッドほど生成に時間がかかる — `onProgress`が
    /// 拾う「今n通目/m通中」を保持し、`threadSummarySheet`の生成中表示に
    /// 出す。`threadSummaryState`とは別の`@State`にしているのは、
    /// `ThreadSummaryState`自体は`Equatable`な4状態の列挙 (`.none`/
    /// `.summarizing`/`.summarized`/`.failed`) のままにしておきたいため —
    /// 進捗という「同じ`.summarizing`状態の中で連続的に変わる値」を
    /// enumのケースに埋め込むと、その都度`ThreadSummaryState`ごと新しい
    /// 値になり比較・関連コードが煩雑になる。`requestThreadSummary()`が
    /// 生成開始時に`nil`へ戻す。
    ///
    /// Task #160フォローアップ3で一時`ThreadSummaryProgress`(「今n通目/m通
    /// 中」/「仕上げ中」の2ケース) へ拡張されたが、フォローアップ5
    /// (ユーザー指示「スレッド要約の最終形への簡素化」) で仕上げパス
    /// (`refineThreadEntries`) 自体が撤去されたため、「仕上げ中」の出番が
    /// 無くなり、Task #160時代の単純な`(current: Int, total: Int)`タプルに
    /// 戻した。
    @State var threadSummaryProgress: (current: Int, total: Int)?

    var body: some View {
        // `GeometryReader` here purely to hand `expandedMessageHeight(in:)`
        // a concrete size to compute off of — see its doc comment for why
        // an expanded row can't just say "fill available space" the way
        // `MessageView`/`HTMLMessageView` were originally designed to (M2,
        // before this view nested them inside a `ScrollView`).
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(messages) { message in
                            messageRow(for: message, containerSize: proxy.size)
                        }
                    }
                }
                // 実機フィードバック「Liquid Glass だと HTML メールで白背景の
                // ときにツールバーが見づらい」: 原因はガラスそのものではなく、
                // ガラスの下をスクロールしていく本文がぼけずに透けること —
                // 白背景 + 濃い大見出しの HTML メールでは、その見出しが
                // `MessageDetailFooterToolbar` のアイコン (`OtegamiColor
                // .accent` の水色) と重なってコントラストを食い潰す。
                // iOS 26 のスクロールエッジエフェクトはまさにこのための仕組み
                // で、バー直前でコンテンツを減衰させてガラス越しの可読性を
                // 確保する。既定の `.automatic` はバーの種類から強さを推測する
                // ため、アイコンが 15 個並ぶこのバーには弱すぎた — 明示的に
                // `.hard` (減衰しきる強い方) を指定する。実際にエフェクトを
                // 出すのはこの修飾子ではなく下の `.safeAreaBar` (旧
                // `.safeAreaInset` にはエッジエフェクトを起こす役割が無い) で、
                // ここはその強さの指定だけを担う。macOS はガラス化していない
                // ので対象外 (CLAUDE.md「macOS は現状維持」)。
                #if os(iOS)
                .scrollEdgeEffectStyle(.hard, for: .bottom)
                #endif
                // Bug fix: this view used to carry `.defaultScrollAnchor
                // (.bottom)` here instead of a normal top-anchored
                // `ScrollView` plus the one-shot `scrollProxy.scrollTo`
                // below. `.defaultScrollAnchor` doesn't only affect the
                // *initial* layout — SwiftUI re-applies it every time the
                // scrollable content's size changes, so it kept forcing the
                // view back to the bottom on every resize, not just once at
                // open. A plain (default top-anchored) `ScrollView` fixes
                // both — content shorter than the viewport now naturally
                // sits at the top — while `scrollProxy.scrollTo(newestId,
                // anchor: .top)` (fired exactly once per thread load, from
                // `.onChange(of: hasPinnedInitialExpansion)` below) still
                // brings a long thread's newest expanded message into view
                // on open without permanently pinning the view to the
                // bottom.
                .onChange(of: hasPinnedInitialExpansion) { _, pinned in
                    guard pinned, let newestId = messages.last?.id else { return }
                    scrollProxy.scrollTo(newestId, anchor: .top)
                }
                // Task #146: `accordionScrollTarget`のdoc comment参照 —
                // `toggleExpanded(_:)`が展開のたびここへ`messageId`を書き込み、
                // このハンドラが拾って展開行のヘッダを画面上部へスクロール
                // する。`.onChange`はForEach側の展開行insert (`isExpanded`
                // 反映によるMessageViewのマウント) が同じ更新サイクルで確定
                // した後に発火するため、`scrollTo`時点でその行のidが実在する
                // — `FolderListSheet.menuScrollTarget`と同じ前提。
                //
                // WKWebViewの高さ確定が非同期 (展開直後は`ThreadMessageRow
                // .measuredHTMLContentHeight`がまだ`nil`) な点は注意したが、
                // 展開直後から`ThreadDetailView.expandedMessageHeight(in:)`
                // のフォールバック固定高さ (Task #58) がすでにその行へ
                // 割り当たっているため、`anchor: .top`でヘッダを先頭に置いた
                // 後にWKWebViewの実測高さへ差し替わっても、変わるのはヘッダ
                // より*下*の高さだけ — ヘッダ自身の位置はずれない。
                // `scripts/verify-screen.sh thread-accordion-scroll`
                // (`-uitestsExpandOldestMessageDirectly`、下の`.onChange`
                // 参照) のスクリーンショットで確認済み。
                .onChange(of: accordionScrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.default) {
                        scrollProxy.scrollTo(target, anchor: .top)
                    }
                    accordionScrollTarget = nil
                }
                // Task #59 had this outer `ScrollView` reserve blank space at
                // its bottom (`.contentMargins(.bottom:)`) so its content
                // never rendered directly behind the floating 要約/翻訳
                // buttons that used to overlay it. Task #88 (「要約と翻訳の
                // ボタンをフローティングをやめてツールバーに入れて」) removed
                // both the overlay and this reservation together — the two
                // buttons now live inside `footerToolbar`'s
                // `.safeAreaInset(edge: .bottom)`, which SwiftUI already
                // accounts for like any other bottom safe-area content, so
                // there's nothing left here that would ever render behind
                // them.
            }
            .accessibilityIdentifier("threadDetail.scrollView")
            // Liquid Glass Phase 2 (`docs/design-system.md`「Liquid Glass
            // 方針」): iOS 側の独自`background`塗りも撤去し、システム標準の
            // 背景へ委譲した — 2026-08-07 の macOS ネイティブ化で macOS が
            // 先に同じ判断をしていた (このブロックはもともと macOS を除外
            // する iOS 専用の`#if`だった) のに揃える形。
            .overlay {
                if messages.isEmpty, accountId != nil {
                    ContentUnavailableView("メッセージが見つかりません", systemImage: "envelope.open")
                        .accessibilityIdentifier("threadDetail.emptyState")
                }
            }
        }
        // 表示・操作改善バッチ「ヘッダにメール件名を表示しない」: the subject
        // already renders inside each message's own header
        // (`ThreadMessageSummaryRow`/`MessageView.header(for:)`), so
        // repeating it in the navigation bar was pure duplication —
        // replaced with a generic screen title.
        .navigationTitle(navigationTitleText)
        // Task #153 (スレッド全体のAI要約): 見出しの隣に置くトグルボタン —
        // グループ化/アコーディオン表示 (`!isFlatModeEntry`) のときだけ出す。
        // `threadSummarizeToolbarButton`のdoc comment参照。
        .toolbar {
            if !isFlatModeEntry {
                ToolbarItem {
                    threadSummarizeToolbarButton
                }
            }
        }
        .sheet(isPresented: $isShowingThreadSummarySheet) { threadSummarySheet }
        .task(id: threadId) { await load() }
        .task(id: threadId) { await observeThreadPinState() }
        // Task #55/#59/#60/#85 had a top-level `.overlay(alignment:
        // .bottomTrailing)` here rendering `MessageDetailFloatingButtons` —
        // the whole history of *that* overlay's exact placement relative to
        // `.safeAreaInset(edge: .bottom)` below (Task #60's "被る" fix, in
        // particular) no longer applies to anything: Task #88 removed the
        // overlay entirely and moved the 要約/翻訳 buttons it rendered into
        // `footerToolbar` itself (`MessageDetailFooterToolbar`'s
        // `summarizeButton`/`translateButton`, fed by the same
        // `expandedAIFeaturesState` this view already tracked for the old
        // overlay). One fewer moving part: the toolbar is the only bottom-
        // anchored UI now, so there's no second layer to keep from
        // overlapping it.
        // Task #163: placed here (before the footer toolbar's own
        // `.safeAreaInset`), mirroring the now-removed `MessageDetailFloatingButtons`
        // overlay's old position (see the doc comment right above this
        // one) — an `.overlay(alignment: .bottom)` applied before a sibling
        // `.safeAreaInset(edge: .bottom)` renders inside the safe area that
        // inset carves out, i.e. right above `footerToolbar`, never
        // overlapping its buttons.
        .overlay(alignment: .bottom) {
            if let pinnedArchiveNotice {
                UndoToast(message: pinnedArchiveNotice)
                    .animation(.default, value: pinnedArchiveNotice)
            }
        }
        // 上の `.scrollEdgeEffectStyle` のコメント参照 — iOS だけ
        // `.safeAreaInset` から iOS 26 の `.safeAreaBar` へ移した。両者とも
        // セーフエリアを削って中身をそこへ置く点は同じだが、`.safeAreaBar` は
        // 「これはバーである」ことをシステムに伝えるため、その手前を通る
        // スクロールコンテンツにエッジエフェクトが適用される (`.safeAreaInset`
        // は素の余白扱いなので何も起きない)。背景は従来どおり中身
        // (`MessageDetailFooterToolbar` の `otegamiGlassChrome`) が持つ。
        #if os(iOS)
        .safeAreaBar(edge: .bottom) { footerToolbar }
        #else
        .safeAreaInset(edge: .bottom) { footerToolbar }
        #endif
        .sheet(isPresented: $showingInfo) { infoSheet }
        .sheet(isPresented: $showingSource) { sourceSheet }
        .sheet(isPresented: $showingToolbarSettings) {
            NavigationStack { MessageToolbarSettingsView(presentedAsSheet: true) }
                .tint(OtegamiColor.accent)
                #if os(macOS)
                // Task #205 と同じ既知パターン: macOS は `.sheet` の高さを
                // `NavigationStack { List }` の内在サイズから算出できず、
                // この 1 行が無いとタイトルバーだけのほぼ空のシートになる
                // (`MessageSourceView` / `AccountTypeSelectionView` の
                // doc comment 参照)。設定シート標準の 480x420 より縦に余裕を
                // 持たせ、トグル 7 行 + フッター 3 つが収まる高さにする。
                .frame(minWidth: 480, minHeight: 520)
                #endif
        }
        // Task #103 (シミュレータ検証基盤): 同じ「タップ不要の直接遷移」
        // パターン (`MailScreenView.body`の`.task`が読む各`-uitestsOpen...
        // Directly`引数群と同じ考え方) — `hasPinnedInitialExpansion`が
        // `true`になった時点で`targetMessage`が初めて確定するので、その
        // タイミングでこの引数を確認して`showingSource`を立てる。`scripts/
        // verify-screen.sh message-source`から、フッターツールバーの「その
        // 他」メニューをタップせずに`MessageSourceView`を直接screenshot
        // できる。
        .onChange(of: hasPinnedInitialExpansion) { _, pinned in
            guard pinned, ProcessInfo.processInfo.arguments.contains("-uitestsOpenMessageSourceDirectly") else { return }
            showingSource = true
        }
        // Task #146 (検証基盤): 上と同じ「タップ不要の直接遷移」パターン —
        // `scripts/verify-screen.sh thread-accordion-scroll`から、一番下
        // (最古) の折りたたみ行を`toggleExpanded(_:)`経由でタップ無しに
        // 展開し、`accordionScrollTarget`のスクロール確認用スクリーン
        // ショットを撮れるようにする。実機/通常起動ではこの引数が無いので
        // 常にno-op。
        .onChange(of: hasPinnedInitialExpansion) { _, pinned in
            guard pinned, ProcessInfo.processInfo.arguments.contains("-uitestsExpandOldestMessageDirectly"),
                  let oldestId = messages.first?.id else { return }
            toggleExpanded(oldestId)
        }
    }

    /// A real-device layout bug (observed on iPhone 17 Pro/iOS 26: the top
    /// ~2/3 of the screen rendering as empty background with every message
    /// row pressed to the bottom, the expanded message's body cut off at
    /// the bottom edge) traced back to `HTMLMessageView` giving its
    /// `WKWebView` `.frame(maxWidth: .infinity, maxHeight: .infinity)` — a
    /// request to "fill available space" that only means something when the
    /// immediate parent actually proposes a bounded height. Sizing directly
    /// off the container's own measured height (from the enclosing
    /// `GeometryReader`) fixes that: the web view gets a real, concrete
    /// budget to render and internally scroll within, and an expanded
    /// message reliably takes up most of the visible screen. `360` is a
    /// floor for pathologically short containers (e.g. a narrow macOS
    /// split); the `- 160` leaves room for the collapsed summary rows above
    /// an expanded message (and, 新画面構成 (3) 以降, the footer toolbar's
    /// `.safeAreaInset`, which is comfortably inside that existing margin)
    /// without the expanded row overflowing past the visible area on
    /// typical phone screens.
    private func expandedMessageHeight(in containerSize: CGSize) -> CGFloat {
        let height = max(360, containerSize.height - 160)
        // Task #58 diagnostic instrumentation (temporary): the fixed height
        // budget handed to the expanded row's `MessageView`/`HTMLMessageView`
        // — see `docs/design-system.md`'s Task #58 note for why this is
        // under suspicion as the real ceiling on rendered HTML content,
        // independent of anything `fitToWidthScript` does inside the
        // `WKWebView` itself.
        Self.diagnosticLogger.notice("expandedMessageHeight: containerSize=\(String(describing: containerSize), privacy: .public) -> height=\(height, privacy: .public)")
        return height
    }

    /// Task #58 diagnostic instrumentation (temporary) — see
    /// `expandedMessageHeight(in:)`'s doc comment.
    private static let diagnosticLogger = Logger(subsystem: "com.mtkg.otegami", category: "HTMLHeightDiagnostic")

    /// Builds one row for the `ForEach` in `body` — pulled into its own
    /// `@ViewBuilder` method, and the row's `Button`/summary/conditional
    /// `MessageView` content into `ThreadMessageRow` below, for the same
    /// reason `SidebarView`'s `mailboxRow(for:in:)`/`MailboxRow` split
    /// exists (`docs/ci.md`'s troubleshooting notes).
    @ViewBuilder
    private func messageRow(for message: MessageRecord, containerSize: CGSize) -> some View {
        if let messageId = message.id {
    ThreadMessageRow(
                message: message,
                messageId: messageId,
                isExpanded: expandedMessageId == messageId,
                // Task #64 (実機フィードバック「スレッド表示オフの本文画面で
                // 最上部のスレッドバーを出さないでほしい」): a genuinely
                // flat-mode entry (`isFlatModeEntry`'s doc comment) is always
                // exactly one message, always expanded (`loadSingleMessage`
                // pins it on first load and this screen never offers a way
                // to collapse it back) — its own header/summary row (sender
                // + time, `ThreadMessageSummaryRow`) is pure duplication of
                // the compressed header `MessageView`/`MessageHeaderCompactView`
                // renders directly underneath. A grouped-mode thread (`
                // isFlatModeEntry == false`, whether it has one message or
                // several) keeps every row's header unchanged — this only
                // ever hides it for the flat/no-choice case the request
                // scoped it to.
                showsHeader: !isFlatModeEntry,
                accountId: accountId,
                accountLabelColorKey: accountId.flatMap { id in environment.accounts.first(where: { $0.id == id })?.labelColorKey },
                expandedHeight: expandedMessageHeight(in: containerSize),
                onToggleExpanded: toggleExpanded,
                // Task #149 (実機報告「要約/翻訳ボタンが一瞬有効→無効に
                // 戻る」): `isToolbarTarget`(下)は`MessageView`側の1次防御
                // (非対象インスタンスがそもそも書きに来ない) に過ぎず、
                // SwiftUIのアコーディオン切替アニメーション中は「畳んだ側の
                // 残骸」インスタンスが構築時点の`let`値(まだ`true`だった頃)
                // を凍結したまま持ち続けるため、それ単体では
                // `onDisappear`/`#147`の遅延配信からの書き込みを確実には
                // 防げない — 唯一確実に「今の」正解を知っているのはこの
                // 受け手 (`ThreadDetailView`) 自身の`expandedMessageId`
                // (`@State`なので、このクロージャがいつ・どのインスタンス
                // 経由で呼ばれても読み取り時点の最新値を返す) なので、ここで
                // もう一段、呼び出し元の`messageId`(このクロージャが束縛して
                // いる行自身のid、行ごとに固定) と突き合わせて一致しない
                // 書き込みは黙って無視する。これが実質的な根本修正 —
                // `isToolbarTarget`はログ用途と「そもそも無駄な書き込みを
                // 減らす」防御の二段構え。
                onAIFeaturesStateChange: { newState in
                    guard messageId == expandedMessageId else { return }
                    expandedAIFeaturesState = newState
                },
                isToolbarTarget: expandedMessageId == messageId,
                // Task #165 (macOS 操作体系再設計): this row's macOS-only
                // context menu. Reply/forward target *this* row's own
                // `messageId` — unlike `footerToolbar`'s reply/forward
                // (always `targetMessage`, the currently-expanded message),
                // right-clicking a collapsed row here lets the user reply to
                // that specific message without expanding it first.
                // Archive/junk/delete/pin/mark-unread stay thread-scoped —
                // same "acts on the whole thread" convention every other
                // removal/pin/read-state path in this app already follows
                // (`MessageListView`'s flat-mode doc comment), reusing the
                // exact same methods `footerToolbar` already calls so there's
                // no second implementation to drift.
                onReply: onReply,
                onForward: onForward,
                onArchive: archiveThread,
                onJunk: junkThread,
                onDelete: deleteThread,
                isPinned: isThreadPinned,
                onTogglePin: togglePin,
                onMarkUnread: markUnread,
                // Task #184: same thread-scoped state `footerToolbar` reads —
                // see `isThreadArchived`'s doc comment.
                isArchived: isThreadArchived
            )
            // Task #146: `accordionScrollTarget`のスクロール先ターゲット —
            // ヘッダを含むこの行全体に付けておけば、`showsHeader`が`true`
            // の通常ケースでは行の先頭 = ヘッダの先頭と一致する
            // (`ThreadMessageRow.body`のVStackがヘッダから始まるため)。
            .id(messageId)
            // Design system: a 1pt dashed row separator (`OtegamiStroke
            // .secondary`/`OtegamiColor.dividerSubtle`), matching the
            // handoff's "行間 1px dashed" spacing spec.
            Rectangle()
                .fill(OtegamiColor.dividerSubtle)
                .frame(height: OtegamiStroke.secondary)
                .accessibilityHidden(true)
        }
    }

    /// `ThreadMessageRow.onToggleExpanded`'s target — 実機フィードバック第2弾
    /// (E)「アコーディオン化」: expanding a collapsed `messageId` always
    /// collapses whatever was expanded before (a plain assignment, not the
    /// previous insert-or-remove-from-a-`Set` toggle). Tapping the
    /// already-expanded row's own header (its "^" chevron) now collapses it
    /// to `nil` — see `expandedMessageId`'s doc comment for the 2026-07-29
    /// change from the original "always exactly one expanded" design.
    private func toggleExpanded(_ messageId: Int64) {
        withAnimation(.default) {
            expandedMessageId = (expandedMessageId == messageId) ? nil : messageId
        }
        // 実機フィードバック (iPad)「要約ボタンを押せない時がある」の全閉じ版:
        // 「^」で全部畳むと、畳まれた行の `MessageView.onDisappear` が送る
        // nil クリアは Task #149 のガード (`messageId == expandedMessageId`、
        // このとき `expandedMessageId` は既に `nil`) に弾かれ、破棄済み
        // インスタンスの handle がフッターに残る — 要約/翻訳ボタンが有効
        // 表示のまま無反応になる。別の行への切替 (非 nil → 非 nil) は新しい
        // 行の `.onAppear` が自分の state で上書きするので問題にならず、
        // 上書きする者がいない「nil へ畳む」ケースだけ受け手側で明示的に
        // 捨てる必要がある。`load()` 冒頭の同名リセットと同じ理屈。
        if expandedMessageId == nil {
            expandedAIFeaturesState = nil
        }
        // Task #146: 展開したとき (collapse ではない) だけ自動スクロールを
        // 起動する — `expandedMessageId`は直前の代入で*新しい*値になって
        // いるので、ここでの一致チェックは「(旧値と比べてではなく) 結果と
        // して今`messageId`が展開状態になったか」を素直に表す。
        if expandedMessageId == messageId {
            accordionScrollTarget = messageId
        }
    }

    /// Task #153: "スレッド" for grouped/accordion display (`!isFlatModeEntry`
    /// — every grouped-mode open, whether the thread currently has 1 or
    /// many messages), "メール" (unchanged, pre-existing literal) for a
    /// genuinely flat single-message entry point (`isFlatModeEntry`'s own
    /// doc comment). A computed `String` property with `String(localized:)`
    /// per branch, not a ternary of two string literals passed straight to
    /// `.navigationTitle(_:)` — mirrors `ComposerView.navigationTitle`'s own
    /// doc comment on this exact trap: a ternary of two literals resolves
    /// to the `String` overload of `.navigationTitle(_:)`, not
    /// `LocalizedStringKey`, so each branch needs its own explicit
    /// `String(localized:)` to still pick up its String Catalog entry
    /// rather than rendering the raw Japanese unconditionally regardless of
    /// the device's language.
    ///
    /// 実機フィードバック (2026-07-30):「スレッド」の後ろに件数を出してほしい
    /// — "スレッド (5)" 形式。`messages.count`は`ThreadQuery
    /// .messagesObservation(threadId:)`(= `ThreadQuery.messages(threadId:
    /// db:)`)の結果で、これは既に`ThreadQuery.deduplicate(_:db:)`を通した
    /// 後の件数 — 一覧の通数バッジ (Task #136、`ThreadRowView`が読む
    /// `summary.thread.messageCount`) も`ThreadAssigner
    /// .recomputeAggregates`内で同じ`ThreadQuery.deduplicate`を通して
    /// 計算しているので (Gmail INBOX+All Mail の二重カウントを同じ規則で
    /// 除外)、一覧のバッジと詳細のヘッダで数が食い違うことはない。新しい
    /// クエリを足さず、この画面が既にライブ観測している`messages`をそのまま
    /// 数えるだけなので、スレッドへメッセージが増減すれば自動で追従する。
    ///
    /// 1件のスレッドでは件数を出さない — 一覧側の通数バッジ自体
    /// (`ThreadRowView`の`summary.thread.messageCount > 1`) が1件のときは
    /// 表示しない既存ルールと揃え、「スレッド (1)」という冗長な表記を避ける。
    private var navigationTitleText: String {
        guard !isFlatModeEntry else { return String(localized: "メール") }
        guard messages.count > 1 else { return String(localized: "スレッド") }
        return String(localized: "スレッド (\(messages.count))")
    }

    /// 新画面構成 (3) → 実機フィードバック第2弾 (E): "返信"/"転送"/"検索"/「情報」
    /// が対象にするメッセージ — 常に**現在展開中の1通** (accordion なので曖昧
    /// さがない)。`expandedMessageId`が`nil`の`MessageRecord`が
    /// `messages`の読み込みタイミングの隙間でまだ見つからない場合だけ、
    /// スレッド内最新へフォールバックする (`RootView`'s macOS ⇧⌘R が使う規則
    /// と同じ — その doc comment 参照)。
    ///
    /// **2026-07-29 追記**: `expandedMessageId`自身が`nil`のとき
    /// (`toggleExpanded(_:)`のdoc comment参照 — ユーザーが「^」で全閉じ
    /// した状態、または`load()`の初回pinがまだ走っていない一瞬) は、
    /// このフォールバックを使わずそのまま`nil`を返す — 全閉じ中はツール
    /// バーの返信/転送/検索/情報/ソース表示アクションが安全に対象なし
    /// (no-op) になる。上記の「見つからない場合だけ」のフォールバックは
    /// `expandedMessageId`が非`nil`なのに一致する行が見つからない、別の
    /// (本当に一時的な) ケースのためのもの。
    private var targetMessage: MessageRecord? {
        guard let expandedMessageId else { return nil }
        return messages.first(where: { $0.id == expandedMessageId }) ?? messages.last
    }

    private func load() async {
        accountId = nil
        messages = []
        expandedMessageId = nil
        // 実機フィードバック (iPad)「要約ボタンを押せない時がある」: iPad の
        // regular 幅では `MailScreenView.detailColumn` が `ThreadEntryView` を
        // `.id` 無しで差し替えるため、一覧で別スレッドを選んでもこの View は
        // 同一 identity のまま `.task(id: threadId)` で `load()` だけが再走する
        // (compact 幅の `.navigationDestination` は毎回作り直すので起きない —
        // iPad のみで再現した理由)。ここで `expandedAIFeaturesState` を捨て
        // ないと、旧スレッドの破棄済み `MessageView` が握らせた handle が
        // フッターに残り続け、要約/翻訳ボタンが「有効に見えるのに押しても
        // 死んだ `@State` に書くだけで何も起きない」状態になる。旧
        // `MessageView` の `.onDisappear` による nil クリアは Task #149 の
        // ガード (`onAIFeaturesStateChange` の `messageId == expandedMessageId`
        // 照合) が弾いてしまうため、リセットはこの受け手側で行うしかない。
        expandedAIFeaturesState = nil
        hasPinnedInitialExpansion = false
        isThreadPinned = false
        isThreadMuted = false
        isThreadArchived = false

        let thread = try? await environment.database.dbWriter.read { db in
            try ThreadRecord.fetchOne(db, key: threadId)
        }
        accountId = thread?.accountId
        isThreadMuted = thread?.isMuted ?? false

        if let singleMessageId {
            await loadSingleMessage(singleMessageId)
            return
        }

        // `isThreadPinned`はここでは読まない — `observeThreadPinState()`が
        // ライブ購読する (そちらの doc comment 参照)。
        let observation = ThreadQuery.messagesObservation(threadId: threadId)
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                messages = fetched
                // Pin the newest message expanded exactly once, the first
                // time this thread's messages load — after that, expansion
                // is entirely up to the user's own header taps, even as
                // the live observation keeps delivering updates (e.g. a
                // flag change from opQueue replay).
                if !hasPinnedInitialExpansion, let newestId = fetched.last?.id {
                    expandedMessageId = newestId
                    hasPinnedInitialExpansion = true
                }
                await refreshIsThreadArchived(messageId: nil)
            }
        } catch {
            // A failing observation just stops the view from updating
            // further; it doesn't clear what's already shown.
        }
    }

    /// グループ表示のツールバーのピン状態を DB からライブ購読する。
    ///
    /// 実機報告 (2026-08-07)「メールの unpin が反映されない」の調査で、
    /// この画面が `load()` 時の一発読み + `togglePin()` の楽観更新だけで
    /// 動いていたことが分かった — DB 側で実際には解除されていない (同期が
    /// Gmail の重複行を戻した) ときでも**ツールバーだけ解除済みに見え**、
    /// 一覧へ戻るとピンが残っている、という食い違いになる。同期由来の
    /// 変化も拾えるよう購読に変えた。
    ///
    /// `singleMessageId` のとき (フラット表示) は何もしない —
    /// `loadSingleMessage(_:)` が既にその1通の `isPinnedLocal` を
    /// 購読していて、そちらの方が「画面に出ているメールのピン」という
    /// 意味に忠実 (そのメソッドの doc comment 参照)。
    private func observeThreadPinState() async {
        guard singleMessageId == nil else { return }
        let observation = ValueObservation.tracking { db in try ThreadRecord.fetchOne(db, key: threadId) }
        do {
            for try await thread in observation.values(in: environment.database.dbWriter) {
                isThreadPinned = thread?.isPinned ?? false
            }
        } catch {
            // 購読が落ちてもツールバーの表示が更新されなくなるだけ —
            // このファイルの他の observation ループと同じ扱い。
        }
    }

    /// `singleMessageId`'s load path (実機フィードバック第3弾 (A)): a live
    /// observation of just the one message, instead of `ThreadQuery
    /// .messagesObservation(threadId:)`'s whole-thread query — mirrors that
    /// method's shape (one `for try await` loop pinning expansion exactly
    /// once) so this degenerates to the exact same "one row, always
    /// expanded" rendering `messageRow(for:containerSize:)`/`ThreadMessageRow`
    /// already give a real one-message thread, no view-layer changes
    /// needed there. `isThreadPinned` reflects this one message's own
    /// `isPinnedLocal` (not the thread aggregate `ThreadRecord.isPinned` the
    /// grouped-mode path reads) — see `togglePin()`/`applyPinState(pinning:)`'s
    /// doc comment for why the toolbar's pin toggle should only ever speak
    /// for the message actually on screen here.
    private func loadSingleMessage(_ messageId: Int64) async {
        let observation = ValueObservation.tracking { db in try MessageRecord.fetchOne(db, key: messageId) }
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                guard let fetched else {
                    messages = []
                    continue
                }
                messages = [fetched]
                isThreadPinned = fetched.isPinnedLocal
                if !hasPinnedInitialExpansion {
                    expandedMessageId = fetched.id
                    hasPinnedInitialExpansion = true
                }
                await refreshIsThreadArchived(messageId: messageId)
            }
        } catch {
            // Same as the grouped-mode path: a failing observation just
            // stops updating, it doesn't clear what's already shown.
        }
    }

    /// Task #184: shared by `load()`'s grouped-mode loop (`messageId: nil`)
    /// and `loadSingleMessage(_:)`'s flat-mode loop (`messageId` set) —
    /// see `isThreadArchived`'s doc comment for why each mode reads a
    /// different `ThreadQuery` helper at a different granularity. Best-
    /// effort like every other observation-driven read in this file: a
    /// failing query just leaves `isThreadArchived` at its last known value
    /// rather than throwing.
    private func refreshIsThreadArchived(messageId: Int64?) async {
        let archived = (try? await environment.database.dbWriter.read { db -> Bool in
            if let messageId {
                return try ThreadQuery.isMessageArchived(messageId: messageId, db: db)
            }
            return try ThreadQuery.isThreadArchived(threadId: threadId, db: db)
        }) ?? isThreadArchived
        isThreadArchived = archived
        onArchivedStateChanged?(archived)
    }

    // MARK: - 新画面構成 (3): フッターツールバー

    private var footerToolbar: some View {
        MessageDetailFooterToolbar(
            onReply: { replyToTarget(replyAll: false) },
            onReplyAll: { replyToTarget(replyAll: true) },
            onForward: forwardTarget,
            onSearch: onSearchFromSender.map { callback in { openSearchFromTargetSender(callback) } },
            // 2026-07-29 (全閉じ許可の追記): `targetMessage == nil`(全閉じ
            // 中)なら開かない — 開けても`infoSheet`が`EmptyView`を返すだけの
            // 空シートになってしまうため。
            onInfo: { guard targetMessage != nil else { return }; showingInfo = true },
            isMuted: isThreadMuted,
            onToggleMute: toggleMute,
            onMarkUnread: markUnread,
            onArchive: archiveThread,
            // Task #184: state-dependent label/icon — see `isThreadArchived`'s
            // doc comment.
            isArchived: isThreadArchived,
            onJunk: junkThread,
            isPinned: isThreadPinned,
            onTogglePin: togglePin,
            onDelete: deleteThread,
            // 2026-07-29 (全閉じ許可の追記): 同上 — `sourceSheet`も対象なしの
            // 空シートを避ける。
            onViewSource: { guard targetMessage != nil else { return }; showingSource = true },
            onCustomizeToolbar: { showingToolbarSettings = true },
            aiFeaturesState: expandedAIFeaturesState
        )
    }

    @ViewBuilder
    private var infoSheet: some View {
        if let message = targetMessage {
            MessageHeaderInfoView(
                message: message, references: infoReferences, mailboxPath: infoMailboxPath,
                contentType: infoContentType
            )
            .task { await loadInfoDetails(for: message) }
        }
    }

    /// Task #103 ("ソースを表示"): unlike `infoSheet`, no separate async
    /// `mailboxPath` lookup needed here — `MessageSourceLoader` resolves
    /// the message's owning mailbox path (and `uid`) itself, straight from
    /// `environment.database`, only on an actual cache miss (see its
    /// `resolveMessageLocation` doc comment).
    @ViewBuilder
    private var sourceSheet: some View {
        if let message = targetMessage, let messageId = message.id, let accountId {
            MessageSourceView(messageId: messageId, accountId: accountId, subject: message.subject)
        }
    }

    private func replyToTarget(replyAll: Bool) {
        guard let id = targetMessage?.id else { return }
        onReply(id, replyAll)
    }

    private func forwardTarget() {
        guard let id = targetMessage?.id else { return }
        onForward(id)
    }

    /// Task #140 (実機報告「ツールバー検索の `from:` プリセットが不発になる
    /// ことがある」): この`guard`自体が無言で失敗するケースは無いはずだと
    /// 調査で確認した — `targetMessage`が読む`messages`は`ThreadQuery
    /// .messagesObservation`が`MessageRecord.fetchAll`で毎回*フルの行*を
    /// 取得したもの (部分プロジェクションではない) なので、`messages`が
    /// 一度でも読み込まれていれば`fromAddresses`は常に埋まっている。実際の
    /// 原因は`MailScreenView`側の`.sheet(isPresented:)` + 兄弟`@State`の
    /// 競合だった (`MailScreenView.searchRoute`のdoc comment参照、
    /// `.sheet(item:)`へ切り替えて解消) — この`guard`自体は変更していない
    /// が、万一実機で本当にここが原因なら`log stream --predicate 'category
    /// == "SearchFromSenderGate"'`で切り分けられるようログを足した。
    private func openSearchFromTargetSender(_ callback: (String) -> Void) {
        guard let address = targetMessage?.fromAddresses.first?.address else {
            Self.searchFromSenderGateLogger.notice("""
            openSearchFromTargetSender: no address — \
            targetMessageId=\(targetMessage?.id.map(String.init) ?? "nil", privacy: .public) \
            fromAddressesCount=\(targetMessage?.fromAddresses.count ?? -1, privacy: .public) \
            messagesCount=\(messages.count, privacy: .public) expandedMessageId=\(expandedMessageId.map(String.init) ?? "nil", privacy: .public)
            """)
            return
        }
        callback("from:\(address)")
    }

    /// Task #140 diagnostic instrumentation — see `openSearchFromTargetSender`'s
    /// doc comment.
    private static let searchFromSenderGateLogger = Logger(subsystem: "com.mtkg.otegami", category: "SearchFromSenderGate")

    // MARK: - 新画面構成 (3): 情報シート

    /// `MessageHeaderInfoView` の `references`/`contentType` を非同期で埋める
    /// — `infoSheet` は即座に (ネットワーク非依存の) `MessageRecord` だけで
    /// 描画してから、この `.task` で残りを補う。
    private func loadInfoDetails(for message: MessageRecord) async {
        guard let messageId = message.id else { return }
        let details = try? await environment.database.dbWriter.read { db -> (references: [String], mailboxPath: String?, isHTML: Bool) in
            let references = try MessageReferenceRecord
                .filter(Column("messageId") == messageId)
                .order(Column("position"))
                .fetchAll(db)
                .map(\.referenceValue)
            let mailboxPath = try MailboxRecord.fetchOne(db, key: message.mailboxId)?.path
            let bodyRecord = try MessageBodyRecord.fetchOne(db, key: messageId)
            let isHTML = bodyRecord?.html?.isEmpty == false
            return (references, mailboxPath, isHTML)
        }
        guard let details else { return }
        infoReferences = details.references
        infoMailboxPath = details.mailboxPath
        infoContentType = details.isHTML ? "text/html" : "text/plain"
    }

    @State private var infoReferences: [String] = []
    @State private var infoMailboxPath: String?
    @State private var infoContentType = "text/plain"
}

/// One message's row inside `ThreadDetailView`'s `LazyVStack` — the
/// `Button`/summary/conditional `MessageView` content pulled out of
/// `ThreadDetailView.body`'s `ForEach` closure (`messageRow(for:
/// containerSize:)`'s doc comment for why).
private struct ThreadMessageRow: View {
    let message: MessageRecord
    let messageId: Int64
    let isExpanded: Bool
    /// Task #64: `false` only for a genuinely flat-mode entry (see
    /// `ThreadDetailView.messageRow(for:containerSize:)`'s call-site doc
    /// comment) — suppresses the `Button`/`ThreadMessageSummaryRow` header
    /// entirely, since that screen's only message is always already
    /// expanded and its sender/time duplicate what `MessageView`'s own
    /// compressed header shows right underneath. `true` (unchanged, header
    /// shown) for every grouped-mode case, single-message or not.
    let showsHeader: Bool
    let accountId: String?
    /// Forwarded straight to `ThreadMessageSummaryRow` — see its own doc
    /// comment on `accountLabelColorKey`.
    let accountLabelColorKey: String?
    let expandedHeight: CGFloat
    let onToggleExpanded: (Int64) -> Void
    /// Task #59: forwarded straight to `MessageView.onAIFeaturesStateChange`
    /// — see that parameter's doc comment. This row is just a pass-through
    /// (it isn't itself the state's ultimate destination, `ThreadDetailView`
    /// is — see `body`'s own top-level `overlay`) because `MessageView` is
    /// nested one level deeper than where `ThreadDetailView.messageRow(for:
    /// containerSize:)` constructs this row.
    let onAIFeaturesStateChange: (MessageDetailAIFeaturesState?) -> Void
    /// Task #149: forwarded straight to `MessageView.isToolbarTarget` — see
    /// that parameter's doc comment. Computed by `ThreadDetailView.messageRow
    /// (for:containerSize:)` as `expandedMessageId == messageId`, the exact
    /// same condition `isExpanded` above already is; kept as its own,
    /// separately-named parameter (rather than just reusing `isExpanded`)
    /// because it names a different question ("should this instance be
    /// writing to the shared toolbar state right now") than `isExpanded`
    /// ("should this row currently render its `MessageView` at all") —
    /// today the two happen to always agree at construction time, but a
    /// residual instance mid-accordion-transition (`onAIFeaturesStateChange`'s
    /// call-site doc comment) is exactly the case where relying on that
    /// coincidence would be wrong.
    let isToolbarTarget: Bool

    /// Task #165 (macOS 操作体系再設計): this row's macOS-only `.contextMenu`
    /// — see `ThreadDetailView.messageRow(for:containerSize:)`'s call-site
    /// doc comment for why reply/forward target this row's own `messageId`
    /// while archive/junk/delete/pin/mark-unread stay thread-scoped.
    let onReply: (Int64, Bool) -> Void
    let onForward: (Int64) -> Void
    let onArchive: () -> Void
    let onJunk: () -> Void
    let onDelete: () -> Void
    let isPinned: Bool
    let onTogglePin: () -> Void
    let onMarkUnread: () -> Void
    /// Task #184: whether `onArchive` currently means "アーカイブ解除" —
    /// see `ThreadDetailView.isThreadArchived`'s doc comment. Swaps
    /// `contextMenuContent`'s archive row's label/icon the same way
    /// `isPinned` already swaps the pin row's.
    let isArchived: Bool

    /// Task #58 (根治): the real content height an HTML message's
    /// `WKWebView` measured — see `HTMLWebViewCoordinator.onHeightChange`'s
    /// doc comment for the whole chain this arrives through, and
    /// `MessageView.onHTMLContentHeightChange`'s for why this row (not
    /// `MessageView` itself) is where it has to land. `nil` until the first
    /// `otegamiHeight` message arrives, and for a plain-text message, which
    /// never reports one at all.
    ///
    /// Task #59 (「本文下の空白が過剰」): this used to feed
    /// `resolvedHeight`'s `measuredHTMLContentHeight + nonHTMLChromeAllowance`
    /// (a blind `+180pt` guess for "everything in `MessageView`'s `VStack`
    /// besides the HTML body itself") as the frame handed to the *entire*
    /// `MessageView`. That guess is gone now — see `body`'s `.frame(height:)`
    /// below for the replacement: once a real measurement exists, this row
    /// stops imposing a height on `MessageView` at all, letting its own
    /// `VStack` sum each element's actual intrinsic height (header,
    /// attachments, divider) plus the HTML body's own now-exact
    /// `.frame(height:)` (`MessageView.content`'s HTML branch) — no guessed
    /// constant, and (Task #59's root cause) no double-counting against the
    /// separate DOM-level spacer `HTMLMessageView`'s JS used to fold into
    /// this same measurement (`HTMLWebViewCoordinator.postHeight()`'s doc
    /// comment has that half of the fix).
    @State private var measuredHTMLContentHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                Button {
                    onToggleExpanded(messageId)
                } label: {
                    ThreadMessageSummaryRow(
                        message: message, accountId: accountId, accountLabelColorKey: accountLabelColorKey,
                        isExpanded: isExpanded
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("threadDetail.message.\(messageId).header")
            }

            if isExpanded, let accountId {
                MessageView(
                    accountId: accountId, messageId: messageId,
                    contentHeight: measuredHTMLContentHeight,
                    onHTMLContentHeightChange: { measuredHTMLContentHeight = $0 },
                    onAIFeaturesStateChange: onAIFeaturesStateChange,
                    isToolbarTarget: isToolbarTarget
                )
                    // Task #59: a real measurement (`measuredHTMLContentHeight
                    // != nil`) means `MessageView` itself now sizes its HTML
                    // body to an exact `.frame(height:)` internally
                    // (`contentHeight` above) — imposing *another* fixed
                    // height on the whole view here would just reintroduce
                    // the same "guessed total" problem this Task set out to
                    // remove, one level up. `nil` (no constraint) lets this
                    // row's `VStack` size to `MessageView`'s own natural
                    // total instead. Only the pre-measurement/plain-text
                    // fallback (`expandedHeight`, `GeometryReader`-derived —
                    // see that method's doc comment) still imposes a fixed
                    // budget, unchanged from before this task.
                    .frame(height: measuredHTMLContentHeight == nil ? expandedHeight : nil)
                    .accessibilityIdentifier("threadDetail.message.\(messageId).body")
            }
        }
        // Task #58: a different message expanding (accordion — only one
        // row is ever expanded at a time, `ThreadDetailView.toggleExpanded`)
        // must not carry a stale measurement forward onto *this* row the
        // next time it's the one that expands — without this, collapsing
        // and re-expanding the same tall message would still show the
        // correct (already-cached) height immediately, which is fine, but a
        // message that *shrank* (e.g. a translation toggled back to a
        // shorter original) would incorrectly keep the taller stale value
        // forever, since nothing else ever resets it back down.
        .onChange(of: isExpanded) { _, expanded in
            guard !expanded else { return }
            measuredHTMLContentHeight = nil
        }
        #if os(macOS)
        // Task #165: right-click anywhere on this message's row (header or
        // expanded body) — mirrors `MessageListRow`'s existing macOS
        // `.contextMenu` convention.
        .contextMenu {
            contextMenuContent
        }
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var contextMenuContent: some View {
        Button { onReply(messageId, false) } label: { Label("返信", systemImage: "arrowshape.turn.up.left") }
        Button { onReply(messageId, true) } label: { Label("全員に返信", systemImage: "arrowshape.turn.up.left.2") }
        Button { onForward(messageId) } label: { Label("転送", systemImage: "arrowshape.turn.up.right") }
        Divider()
        Button { onMarkUnread() } label: { Label("未読にする", systemImage: "envelope.badge") }
        Button { onTogglePin() } label: {
            if isPinned {
                Label("ピン留めを解除", systemImage: "pin.slash")
            } else {
                Label("ピン留め", systemImage: "pin")
            }
        }
        Button { onJunk() } label: { Label("迷惑メールにする", systemImage: "exclamationmark.octagon") }
        // Task #184: mirrors `pinLabel`'s state-dependent swap just above —
        // "アーカイブ解除" (`tray.and.arrow.up`, echoing "put it back", the
        // same icon `MessageListRow.archiveLabel` already uses for the same
        // reversed action) while `isArchived`, the normal "アーカイブ"
        // otherwise.
        Button { onArchive() } label: {
            if isArchived {
                Label("アーカイブ解除", systemImage: "tray.and.arrow.up")
            } else {
                Label("アーカイブ", systemImage: "archivebox")
            }
        }
        Button(role: .destructive) { onDelete() } label: { Label("削除", systemImage: "trash") }
    }
    #endif
}

// `ThreadMessageSummaryRow` (the row's actual visual content, above) lives
// in its own file, `ThreadMessageSummaryRow.swift` — split out during
// 画面構造改修バッチ (Task #33, 1) so the now-gone `ThreadSelectionView`
// could also reuse it (its `isExpanded: Bool` was briefly generalized into a
// `Mode` enum for that); Task #136 removed `ThreadSelectionView` and
// collapsed `Mode` back down to the plain `isExpanded: Bool` this accordion
// row always actually needed. See that file's doc comment.
