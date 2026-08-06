import SwiftUI
import OtegamiCore
import OtegamiStore
import SyncEngine

@main
struct OtegamiApp: App {
    @State private var environment = AppEnvironment()
    #if os(iOS)
    // M9: only reason this app has a UIApplicationDelegate at all — see
    // PushTokenCenter.swift.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                // アバター強化バッチ: `SenderAvatar` (in `DesignSystem`, which
                // can't import `AppEnvironment`) reads this custom
                // `EnvironmentValues` key instead — see
                // `AvatarImageResolving.swift`'s doc comment.
                .environment(\.avatarImageResolver, environment.avatarImageResolver)
                .environment(\.avatarImageRevision, environment.avatarImageRevision)
                // 2026-07-30 (実機フィードバック: 「テスト翻訳を実行」が
                // スピナーのまま無反応・メール本文画面でも翻訳できなく
                // なった、というb24876d適用後の退行): 以前は
                // `ThreadDetailView`だけに`.background`でマウントしていた
                // — `.translationTask`のセッション供給元がその画面にしか
                // 無いため、設定内の「翻訳の診断」画面など別画面から
                // `TranslationSessionCoordinator.translate`/
                // `prepareTranslation`を呼ぶと供給元が存在せず、
                // `attach(_:)`が永遠に呼ばれない (=`performInSession`の
                // continuationが永遠に解決されない) 構造的な穴だった。
                // アプリの主ウィンドウの`WindowGroup`直下 (このルート) へ
                // 1箇所だけマウントする — iOS の設定画面はこの同じ
                // ウィンドウ内のシートなので届く。macOS の`Settings`シーン
                // (⌘,) は別ウィンドウだが、この主ウィンドウ自体は裏で
                // 開いたまま生き続ける (閉じられない) ので、ここにマウント
                // した`.translationTask`は`Settings`ウィンドウでの呼び出し
                // にも引き続き反応する。
                .background(TranslationSessionHostView(coordinator: environment.translationSessionCoordinator))
        }
        #if os(macOS)
        // Task #209 (実機フィードバック「mac で起動した時、ウインドウや各カラム
        // のサイズを覚えるようにして欲しい。特に、初回起動時のメールビューが
        // 狭すぎる」): AppKit/SwiftUI はこの `WindowGroup` のウインドウ位置・
        // サイズも、下の `splitView`の `NavigationSplitView`のカラム幅も、
        // **2回目以降の起動では既に自動で覚えている** — 実機で
        // `defaults read <bundle id>`を見ると、この `WindowGroup`の中身の
        // 型名をキーにした`NSWindow Frame ...`と`NSSplitView Subview Frames
        // ...`が`~/Library/Preferences`に書かれており、ウインドウ移動・
        // カラム幅ドラッグ直後に quit → 再起動しても復元されることを実機
        // ビルド (`make mac-app`) で確認済み。つまり「記憶する」側は自前の
        // 保存コードを書く必要が無い (`docs/design-system.md`のTask #209
        // 節に検証手順の詳細)。
        //
        // 残る本当の問題は**初回起動時の既定値そのもの**: この
        // `.defaultSize`が無いと初回はここが指定されておらず初期状態は
        // 900×450 という実測値だった (`splitView`直下の3カラムに収めるには
        // 明らかに狭い — ユーザー報告の「メールビューが狭すぎる」の直接
        // 原因)。1200×800 は「サイドバー(min180/ideal220/max300) + 一覧
        // (min260/ideal340/max460、`splitView`参照) を差し引いても本文側に
        // 400pt 超が残る」を実機で目視確認して選んだ値 — 2回目以降の起動は
        // この既定値ではなく上記の自動復元が優先されるので、ここは「復元
        // すべき保存状態が無い最初の1回」だけに効く。
        .defaultSize(width: 1200, height: 800)
        #endif
        #if os(macOS)
        // M10: menu bar (⌘N/⌘R/⌘⌫/⌘⇧F/⌘]/⌘[) — `OtegamiCommands` reads its
        // actions via `@FocusedValue` (`AppFocusedValues.swift`), published
        // by `RootView`/`MessageListView` below. Attached to this scene
        // (not the "composer" `WindowGroup`) since Commands apply
        // app-wide regardless of which scene declares them; a composer
        // window intentionally doesn't publish any of these focused values
        // itself, so e.g. ⇧⌘R inside a composer window just stays disabled
        // rather than trying to "reply to a reply."
        .commands { OtegamiCommands() }
        #endif
        #if os(macOS)
        // M5 (plan: "macOS は別ウィンドウ (WindowGroup id \"composer\")"):
        // each compose/reply action opens its own window rather than a
        // sheet — `ComposerLaunchPayload` is `Codable`/`Hashable` so
        // `openWindow(id:value:)` (called from `RootView`) can pass it
        // straight through as this scene's launch value.
        WindowGroup("作成", id: "composer", for: ComposerLaunchPayload.self) { $payload in
            ComposerView(payload: payload ?? .new)
                .environment(environment)
                // アバター強化バッチ: `SenderAvatar` (in `DesignSystem`, which
                // can't import `AppEnvironment`) reads this custom
                // `EnvironmentValues` key instead — see
                // `AvatarImageResolving.swift`'s doc comment.
                .environment(\.avatarImageResolver, environment.avatarImageResolver)
                .environment(\.avatarImageRevision, environment.avatarImageRevision)
        }
        .defaultSize(width: 560, height: 520)
        #endif
        #if os(macOS)
        // Task #182 (macOS アプリ内アップデート、実機フィードバック「update
        // のチェックができる画面は About に移動してほしい」): replaces the
        // standard "Otegamiについて" About panel — `OtegamiCommands`'s
        // `CommandGroup(replacing: .appInfo)` calls `openWindow(id:
        // "about")` rather than presenting a sheet, since a `Commands` menu
        // item has no specific window to attach a sheet to. Supersedes
        // Task #158's `updateCheck` `WindowGroup` (deleted along with
        // `UpdateCheckView`/`UpdateCheckRequest` — their functionality now
        // lives inside `AboutUpdateSection`, folded into this same window).
        // `WindowGroup(id:)` with no `for:` payload behaves as a singleton,
        // matching a native About panel: reopening while already open just
        // brings the existing window forward instead of spawning a second
        // one.
        WindowGroup("Otegamiについて", id: "about") {
            AboutView()
        }
        .defaultSize(width: 460, height: 620)
        .windowResizability(.contentSize)
        #endif
        #if os(macOS)
        // M10 → macOS ネイティブ化 (2026-08-07 実機フィードバック「いかにも
        // iOS 版から移植した感じ」): 以前は標準の `Settings` シーンだったが、
        // `Settings` シーンは `.toolbar` の内容をウィンドウの実タイトルバーへ
        // マージしない (旧 `MacSettingsBackButton` の doc comment に実測記録) —
        // その結果、detail 上部に巨大な空白 + 中央浮きタイトルが出続け、
        // プッシュ画面の戻るボタンも自前の丸ボタンで代替するしかなかった。
        // 通常の `Window` シーンならツールバーが正しくタイトルバーへ
        // マージされ、`NavigationStack` の自動生成の戻るボタンもタイトル
        // バー内の標準位置に出る。⌘,/「設定…」メニューは `Settings`
        // シーンを外すと消えるため、`OtegamiCommands` の
        // `CommandGroup(replacing: .appSettings)` が同じ見た目・同じ
        // ショートカットで `openWindow(id: "settings")` を呼んで代替する。
        // `Window` (not `WindowGroup`) なのでシングルトン — 再度 ⌘, しても
        // 既存ウィンドウが前面に来るだけ、という標準の設定ウィンドウの
        // 挙動そのまま。
        Window("設定", id: "settings") {
            OtegamiSettingsView()
                .environment(environment)
                // アバター強化バッチ: `SenderAvatar` (in `DesignSystem`, which
                // can't import `AppEnvironment`) reads this custom
                // `EnvironmentValues` key instead — see
                // `AvatarImageResolving.swift`'s doc comment.
                .environment(\.avatarImageResolver, environment.avatarImageResolver)
                .environment(\.avatarImageRevision, environment.avatarImageRevision)
        }
        // `OtegamiSettingsView` 側の `.frame(minWidth:minHeight:)` が最小
        // サイズを担い、ここは初回起動時の既定サイズだけを与える (主
        // ウィンドウの `.defaultSize` と同じ理屈 — 2回目以降は AppKit の
        // フレーム自動復元が優先される)。
        .defaultSize(width: 780, height: 560)
        #endif
    }
}

/// Three-pane scaffold: account/mailbox sidebar, the selected mailbox's
/// message list, and the selected message's body (M2's `MessageView`).
/// Sidebar and message list are both backed by live GRDB
/// `ValueObservation`s via `AppEnvironment`/`AppDatabase`.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var selection: SidebarSelection?
    /// 実機フィードバック (2026-07-30「統合ビューを選んだ時、iOS と同じ
    /// アカウント絞り込みチップ行が macOS でも欲しい」, Task #181): iOS の
    /// `MailScreenView.accountFilter`と同じ役割 — `AccountFilterChipRow`で
    /// 選ばれた1アカウントに`MessageListView`を絞り込む
    /// (`contentColumn`の`unifiedInboxAccountFilter:`引数)。`selection`が
    /// 変わるたび`nil`にリセットする (`navigationView`の`.onChange(of:
    /// selection)`) — iOS の`selectMailbox`/`selectUnifiedRole`等が毎回
    /// `accountFilter = nil`するのと同じ後始末。
    @State private var accountFilter: String?
    /// iOS と同じ「時系列 / アカウント別」の永続表示設定。
    @AppStorage(ListDisplaySettingsStore.groupByAccountKey) private var isGroupByAccount = ListDisplaySettingsStore.defaultGroupByAccount
    /// `AccountDigestSearchBar`(グループ表示中の検索バー入口)専用の状態。
    /// 1文字でも入力された瞬間に`contentColumn`の`.onChange`が
    /// `isGroupByAccount`を`false`に戻す — 実際の検索は切替後に現れる
    /// `MessageListView`側の`MacListSearchBar`が担うため、このテキスト自体は
    /// 切替のトリガーとしてのみ使う (`AccountDigestSearchBar`のdoc comment
    /// 参照)。
    @State private var groupSearchText = ""
    @FocusState private var isGroupSearchFieldFocused: Bool
    // M5: which composer to show. Only actually drives a `.sheet` on iOS
    // (macOS opens `openWindow(id: "composer", ...)` instead and never sets
    // this) — see `presentComposer(_:)`.
    @State private var composerPayload: ComposerLaunchPayload?
    // By id, not the whole `ThreadRecord` — `ThreadRecord` isn't
    // `Hashable`, which `List(selection:)` requires.
    @State private var selectedThreadId: Int64?
    /// 実機フィードバック第3弾 (A) — see `MessageListView.selectedMessageId`'s
    /// doc comment. Written alongside `selectedThreadId` in `selectThread(_:
    /// messageId:under:)`; forwarded to `ThreadDetailView.singleMessageId`
    /// in `detailColumn` below. `restoreLastOpenedThreadIfNeeded()`
    /// deliberately never sets this (`lastOpenedThreadIdBySelectionKey`
    /// only remembers a thread id, not a message id — see its doc comment),
    /// so a same-session restore always reopens the full accordion thread
    /// even if the original open was a flat-mode single message.
    @State private var selectedMessageId: Int64?
    /// G「削除・アーカイブ時の挙動」— see `MailScreenView`'s identical property
    /// doc comment (macOS's `detailColumn`/`contentColumn` equivalent of
    /// iOS's `MailScreenView`).
    @State private var currentThreadOrder: [Int64] = []
    @AppStorage(MessagePostActionSettingsStore.afterDeleteArchiveKey) private var postDeleteArchiveActionRaw = MessagePostActionSettingsStore.defaultAfterDeleteArchive.rawValue
    /// Task #184: mirrors `ThreadDetailView.isThreadArchived` — kept up to
    /// date by that view's own `onArchivedStateChanged` callback (`detailColumn`
    /// below) rather than a second, independent query here, so this can
    /// never disagree with what the detail screen's own footer toolbar is
    /// showing for the same thread. Published to `OtegamiCommands`'s ⌘E menu
    /// item via `.focusedSceneValue(\.isSelectedThreadArchived, ...)`
    /// (`navigationViewWithFocusedValues`) only while `selectedThreadId !=
    /// nil` — a stale `true` left over from a previously viewed thread is
    /// harmless once `selectedThreadId` is `nil` again, since that
    /// `nil`-gating unpublishes the whole key regardless of this value.
    @State private var isSelectedThreadArchived = false

    /// G「削除・アーカイブ時の挙動」— see `MailScreenView.handleThreadRemoved(_:)`'s
    /// identical doc comment. Not `#if os(macOS)`-gated even though its only
    /// callers (`detailColumn`, macOS's `deleteSelectedThread()`) currently
    /// are — `detailColumn`/`contentColumn`/`splitView` themselves aren't
    /// platform-gated either (dead code on iOS, where `rootContent` picks
    /// `OtegamiRootView` instead — see that property's doc comment), so this
    /// has to compile on both platforms too.
    private func handleThreadRemoved(_ threadId: Int64) {
        let action = PostDeleteArchiveAction(rawValue: postDeleteArchiveActionRaw) ?? MessagePostActionSettingsStore.defaultAfterDeleteArchive
        selectedThreadId = MessagePostActionSettingsStore.nextThreadId(after: threadId, in: currentThreadOrder, action: action)
        // 実機フィードバック第3弾 (A): `ThreadDetailView` never calls
        // `onThreadRemoved` for a flat-mode (`singleMessageId != nil`) open
        // (see its doc comment), so every arrival here is already a
        // grouped-mode dismissal — reset defensively anyway so a stale
        // single-message id can never leak into whatever thread opens next.
        selectedMessageId = nil
    }

    /// Task #165 (macOS 操作体系再設計): the macOS message-list row's
    /// right-click "返信"/"全員に返信" (`MessageListRow`'s new macOS-only
    /// context-menu entries) — targets `summary.latestMessage`, the same
    /// message the row's own preview text already shows (`ThreadSummary
    /// .latestMessage`'s doc comment: never `nil` in practice for a summary
    /// an observation actually returned). Deliberately **not** `#if
    /// os(macOS)`-gated, matching `handleThreadRemoved(_:)`'s own doc
    /// comment right above: `contentColumn` (this method's only call site)
    /// compiles on both platforms even though only macOS's `MessageListRow`
    /// ever wires a non-default `onReply`/`onReplyAll` closure into it.
    private func replySummary(_ summary: ThreadSummary, replyAll: Bool) {
        guard let messageId = summary.latestMessage?.id else { return }
        presentComposer(.reply(originalMessageId: messageId, replyAll: replyAll))
    }

    /// Task #165: the macOS message-list row's right-click "転送" — see
    /// `replySummary(_:replyAll:)`'s doc comment.
    private func forwardSummary(_ summary: ThreadSummary) {
        guard let messageId = summary.latestMessage?.id else { return }
        presentComposer(.forward(originalMessageId: messageId))
    }

    // Drives which column a compact-width device (iPhone) shows.
    // `NavigationSplitView` does *not* automatically push from `content`
    // to `detail` just because a `List(selection:)` binding changed value
    // — that's only guaranteed between `sidebar` and `content` (the
    // two-column case). For three columns, the documented way to make a
    // selection in `content` actually navigate to `detail` on compact
    // width is to drive `preferredCompactColumn` explicitly; discovered by
    // testing on a real (compact) simulator — tapping a message row
    // updated `selectedMessageId` correctly but never visibly navigated
    // without this.
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar

    // 実機バグ (macOS: 狭いウィンドウでサイドバーに戻れない) — `splitView` used to
    // call the `preferredCompactColumn`-only `NavigationSplitView` initializer,
    // which leaves `columnVisibility` entirely to AppKit's own internal,
    // unbound state. Owning `columnVisibility` here (via the combined
    // `columnVisibility:preferredCompactColumn:` initializer below) keeps a
    // deterministic binding for AppKit's own standard sidebar-toggle toolbar
    // button to read/drive — an app previously had its own recovery button
    // here too (removed: 実機フィードバック「サイドバーを閉じるとツールバー
    // にサイドバーアイコンが2つ並ぶ」— `NavigationSplitView`自体が同じ役目の
    // 標準ボタンを自動でツールバーに追加しており、`.toolbar(removing:
    // .sidebarToggle)`で標準ボタン側を消そうとしたが効果が無かったため、
    // 自前ボタンを削除して標準ボタン1つに統一した。狭いウィンドウでの復帰
    // 不能自体は、この`columnVisibility`バインディングと各カラムの
    // `navigationSplitViewColumnWidth`の`min`制約により標準ボタンが常に
    // 残ることを実機/ローカルで確認済み)。Default `.all` matches the
    // pre-fix look (sidebar+content+detail all visible) for every
    // already-wide window.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // Remembers the last thread opened per sidebar selection so that
    // switching *back* to a mailbox later in the same session reopens
    // whatever thread was last read there, without another tap. Keyed by a
    // serialized `SidebarSelection` (M4: either "unified" or a mailbox id)
    // rather than just a mailbox id, since the unified inbox has no single
    // mailbox to key on.
    //
    // Deliberately plain `@State` (in-memory only), not `@AppStorage` —
    // it originally persisted across launches, verified by
    // `scripts/verify-ios-m2.sh`'s offline checkpoint and
    // `scripts/verify-ios-m4.sh`'s thread-view checkpoint, but that turned
    // into a real-device bug (docs/verify.md): killing and relaunching the
    // app with a thread previously open jumped straight back into
    // `ThreadDetailView` with no tap, and that view's `MessageView`/
    // `HTMLMessageView` weren't ready to be the *first* thing on screen
    // (see `ThreadDetailView.expandedMessageHeight(in:)`'s doc comment for
    // the layout collapse this exposed).
    //
    // A first attempt at fixing this kept `@AppStorage` but added a
    // one-shot "skip the very first restore call this process" latch —
    // that turned out not to be robust: `SidebarView`'s `List(selection:)`
    // binding (already flagged as flaky in this project — M2's pitfall #2,
    // `.claude/skills/verify/SKILL.md`) can genuinely oscillate `selection`
    // through nil and back to `.unifiedInbox` more than once while the
    // account/mailbox list is still loading in, each transition re-running
    // `.task(id: selection)` — so "skip exactly the first call" ended up
    // skipping the *spurious* first oscillation while still restoring on a
    // later one within the very same cold launch, confirmed via a fresh
    // `simctl erase` + XCUITest repro. Making this in-memory-only instead
    // sidesteps the whole class of problem structurally rather than by
    // counting calls: this dictionary starts *empty* every process launch,
    // so there is nothing to restore *from* no matter how many times or in
    // what order `selection` churns during startup — restoration can only
    // ever produce a thread this same running process itself opened.
    @State private var lastOpenedThreadIdBySelectionKey: [String: Int64] = [:]

    var body: some View {
        // Split into `navigationViewWithFocusedValues` (see its own doc
        // comment) plus this remaining modifier chain, rather than one
        // single expression running from `NavigationSplitView(...)` all the
        // way through every modifier below — the combined form measured at
        // 335ms to type-check on a fast local Mac under
        // `-warn-long-expression-type-checking` (`docs/ci.md`'s
        // troubleshooting notes), well above what's safe headroom for a
        // much slower CI runner. Splitting the chain into pieces here
        // (rather than only extracting the column closures) cuts the
        // remainder further, since a long `View` modifier chain is itself
        // one expression the type-checker must solve as a whole.
        rootContent
            #if os(iOS)
            .sheet(item: $composerPayload) { payload in
                ComposerView(payload: payload)
            }
            // Task #129 (作成画面リッチテキスト化): same "tap-free direct
            // navigation" pattern as `MailScreenView`'s
            // `-uitestsOpenSettingsDirectly`/`-uitestsOpenSearchDirectly`/etc.
            // — lets `scripts/verify-screen.sh composer-richtext` open a
            // brand-new Composer directly (formatting bar visible) with no
            // "作成" button tap, via a plain launch argument. Always absent
            // outside of that one verification scenario, so this is a no-op
            // on every real launch.
            .task {
                if ProcessInfo.processInfo.arguments.contains("-uitestsOpenComposerDirectly") {
                    presentComposer(.new)
                }
            }
            #else
            // Task #200 (Composer 宛先サジェスト検証): macOS 版の同じ
            // tap-free 直接遷移 — 上の iOS 版 `.task`と同じ起動引数、macOS
            // 側は `presentComposer(_:)`が`openWindow(id: "composer", ...)`
            // を呼ぶだけなので分岐は要らない。iOS 版と違い、それまで存在
            // しなかった (macOS の検証はシミュレータ不調が無いぶん、通常は
            // 実際に「作成」ボタンをクリックすれば足りていたため) —
            // このタスクで初めて必要になった。
            .task {
                if ProcessInfo.processInfo.arguments.contains("-uitestsOpenComposerDirectly") {
                    presentComposer(.new)
                }
            }
            #endif
            // Foreground IDLE (M3, plan: "アプリ active 中、INBOX を IDLE"):
            // start every account's IDLE loop (plus one immediate opQueue
            // replay + incremental sync, since becoming active is exactly
            // when queued offline operations should get a chance to flush)
            // on `.active`, and stop them all on `.background`/`.inactive`
            // — there is no IMAP connection to keep alive while the app
            // can't run code.
            .onChange(of: scenePhase, initial: true) { _, newPhase in
                Task { await handleScenePhaseChange(newPhase) }
            }
            // A newly-added account (mid-session, via AccountSetupView)
            // should also get an IDLE loop without waiting for the next
            // background/foreground transition.
            //
            // 空 → 非空の初回配信はコールドローンチそのもの:
            // `.onChange(of: scenePhase, initial: true)` の `.active` は
            // `AppEnvironment.startObservingAccounts()` の ValueObservation
            // が最初のアカウントリストを届けるより先に発火するため、その
            // 時点の `environment.accounts` は空で、`syncAllAccountsOnce()`
            // は何もせずに終わっている。ここで初回配信を捕まえて新着確認
            // (replay + incremental sync) を1回走らせないと、起動直後の
            // 新規メール確認は次のフォアグラウンド復帰か IDLE のサーバー
            // プッシュまで一切走らない。既にアカウントがある状態での増減
            // (非空 → 非空) はここでは同期しない — アカウント追加フローが
            // 自分で初回同期を走らせる。
            .onChange(of: environment.accounts) { oldAccounts, newAccounts in
                guard scenePhase == .active else { return }
                let isColdLaunchFirstDelivery = oldAccounts.isEmpty && !newAccounts.isEmpty
                Task {
                    if isColdLaunchFirstDelivery {
                        await syncAllAccountsOnce()
                    }
                    await startIdleLoops(for: newAccounts)
                }
            }
            // Task #48 (デフォルトメールアプリ対応): the OS routes a tapped
            // `mailto:` link here once this app claims the scheme
            // (`CFBundleURLTypes`, project.yml) — see `handleOpenURL(_:)`'s
            // doc comment for what actually makes that routing happen.
            .onOpenURL(perform: handleOpenURL)
    }

    /// design-phase-2 (1a): the actual top-level content, split by
    /// platform. iOS renders `OtegamiTabRootView`'s three-tab structure
    /// instead of `NavigationSplitView` entirely (`CLAUDE.md`'s adopted 1a
    /// decision — iOS-only, macOS keeps its three-pane layout unchanged);
    /// `presentComposer(_:)` is the one piece of behavior both platforms'
    /// root content still shares (a sheet on iOS, a separate window on
    /// macOS — see that method's doc comment), so it's passed straight
    /// through as a handful of closures rather than duplicated.
    #if os(iOS)
    private var rootContent: some View {
        OtegamiRootView(
            onCompose: { presentComposer(.new) },
            onOpenDraft: { draftId in presentComposer(.draft(draftId: draftId)) },
            onOpenServerDraft: { messageId in presentComposer(.serverDraft(messageId: messageId)) },
            onReply: { messageId, replyAll in
                presentComposer(.reply(originalMessageId: messageId, replyAll: replyAll))
            },
            onForward: { messageId in presentComposer(.forward(originalMessageId: messageId)) },
            onOpenCancelledSend: { snapshot in presentComposer(.cancelledSend(snapshot)) }
        )
    }
    #else
    private var rootContent: some View {
        navigationViewWithFocusedValues
    }
    #endif

    /// `navigationView` plus (macOS only) the `focusedSceneValue` calls that
    /// publish `OtegamiCommands`' menu actions — kept as its own expression,
    /// separate from `body`'s `.sheet`/`.onChange` tail, since this chain of
    /// ternary-typed `focusedSceneValue` calls turned out to be the single
    /// most expensive piece of the original combined expression to
    /// type-check (measured independently while narrowing down `body`'s
    /// 335ms total, `docs/ci.md`'s troubleshooting notes).
    ///
    /// Task #165 added four more actions (archive/toggleRead/replyAll/
    /// forward) to what was originally a five-call chain — appending them
    /// straight onto this same chain hit exactly the CI type-check timeout
    /// `docs/ci.md` warns about (confirmed locally: `make mac` failed with
    /// "the compiler is unable to type-check this expression in reasonable
    /// time" pointing at this property once it grew to nine calls). Split
    /// into this property (four calls) plus
    /// `navigationViewWithPrimaryFocusedValues` (five) below — two smaller
    /// expressions for the type-checker instead of one large one, the same
    /// fix `docs/ci.md` documents elsewhere in this app for the identical
    /// symptom.
    #if os(macOS)
    private var navigationViewWithFocusedValues: some View {
        navigationViewWithPrimaryFocusedValues
            .focusedSceneValue(\.archiveAction, selectedThreadId == nil ? nil : { archiveSelectedThread() })
            // Task #184: same `selectedThreadId == nil` gating as `archiveAction`
            // itself — see `isSelectedThreadArchived`'s doc comment.
            .focusedSceneValue(\.isSelectedThreadArchived, selectedThreadId == nil ? nil : isSelectedThreadArchived)
            .focusedSceneValue(\.toggleReadAction, selectedThreadId == nil ? nil : { toggleReadSelectedThread() })
            .focusedSceneValue(\.nextMailboxAction, environment.accounts.isEmpty ? nil : { cycleMailboxSelection(by: 1) })
            .focusedSceneValue(\.previousMailboxAction, environment.accounts.isEmpty ? nil : { cycleMailboxSelection(by: -1) })
    }

    /// See `navigationViewWithFocusedValues`'s doc comment for why this is
    /// split out rather than one combined chain.
    private var navigationViewWithPrimaryFocusedValues: some View {
        navigationView
            // M10: publishes the actions `OtegamiCommands`' menu items
            // invoke — `AppFocusedValues.swift`'s doc comment on why
            // `FocusedSceneValue` rather than passing closures some other
            // way. `replyAction`/`deleteAction` are only published while a
            // thread is actually open, so ⇧⌘R/⌘⌫ disable themselves
            // automatically otherwise (no extra bookkeeping needed here
            // beyond the `nil`-vs-non-`nil` ternary).
            .focusedSceneValue(\.newMessageAction, environment.accounts.isEmpty ? nil : { presentComposer(.new) })
            .focusedSceneValue(\.replyAction, selectedThreadId == nil ? nil : { replyToSelectedThread() })
            // Task #165: `replyAllAction`/`forwardAction` reuse
            // `replyToSelectedThread`'s own target-message resolution (the
            // flat-mode `selectedMessageId` when set, otherwise the
            // thread's newest message) — see that method's doc comment.
            .focusedSceneValue(\.replyAllAction, selectedThreadId == nil ? nil : { replyToSelectedThread(replyAll: true) })
            .focusedSceneValue(\.forwardAction, selectedThreadId == nil ? nil : { forwardSelectedThread() })
            .focusedSceneValue(\.deleteAction, selectedThreadId == nil ? nil : { deleteSelectedThread() })
    }
    #else
    private var navigationViewWithFocusedValues: some View {
        navigationView
    }
    #endif

    /// `splitView` plus the two modifiers most tightly coupled to
    /// `selection` itself — split out of `body` (see its doc comment) so
    /// this and the rest of `body`'s modifier chain are separate
    /// expressions for the type-checker.
    private var navigationView: some View {
        splitView
        // A newly-selected sidebar item invalidates whatever thread was
        // shown from the previous one — otherwise the detail pane would
        // keep rendering a thread that no longer belongs to the visible
        // list. Restoration (below) re-populates it if there's a
        // remembered thread for the *new* selection.
        //
        // Deliberately does *not* push `preferredColumn` forward here
        // anymore (it used to: `preferredColumn = newValue == nil ?
        // .sidebar : .content`) — two real bugs traced back to deriving
        // navigation from this value *changing* rather than from the
        // user's tap itself (docs/verify.md's cold-launch/sidebar-selection
        // investigation, the follow-up "コールドランチが統合受信トレイから
        // 始まる"/「直前に選択していた行」タップ不能 reports):
        //   1. `SidebarView.observeMailboxes(accountId:)`'s auto-select of
        //      `.unifiedInbox` on the very first mailbox load (below, via
        //      the `environment.accounts` `onChange`) also flows through
        //      this same `selection`, so pushing forward here meant *every*
        //      app launch with an existing account jumped straight past
        //      the sidebar into the message list — there was no way to
        //      land on the sidebar root first on a compact-width device.
        //   2. Re-tapping the row for the *already-selected* mailbox (e.g.
        //      after popping back to the sidebar via the system back
        //      button) doesn't change `selection`'s value, so this
        //      `onChange` simply never fires a second time — the column
        //      never gets pushed back forward, and the row looks broken.
        // `SidebarView.onSelected`/`MessageListView.onThreadSelected`
        // (wired above) are the only paths that push a column forward now,
        // and they do so unconditionally on every real tap regardless of
        // whether the underlying value actually changed — see their doc
        // comments. Falling back to `.sidebar` when a selection is cleared
        // (e.g. the account it pointed at was just deleted) is still a
        // safe, non-forward-pushing thing to do here.
        .onChange(of: selection) { oldValue, newValue in
            selectedThreadId = nil
            selectedMessageId = nil
            // Task #181: `accountFilter`(アカウント絞り込みチップの選択) は
            // `selection`が指すボックス自体に対する絞り込みなので、
            // ボックス自体が変わったら必ずリセットする — iOS の
            // `MailScreenView.selectMailbox`/`selectUnifiedRole`等が毎回
            // `accountFilter = nil`しているのと同じ後始末。
            accountFilter = nil
            if newValue == nil {
                preferredColumn = .sidebar
            } else if oldValue == nil, uiTestsShouldAutoAdvanceToContent {
                // Legacy test-only shortcut — see `uiTestsShouldAutoAdvanceToContent`'s
                // doc comment. Only fires on the nil→non-nil transition
                // (the initial auto-select), matching exactly what the
                // pre-fix code did unconditionally for every transition.
                preferredColumn = .content
            }
        }
        .task(id: selection) { restoreLastOpenedThreadIfNeeded() }
    }

    /// The bare three-column `NavigationSplitView`, with no modifiers
    /// attached besides the per-column width ranges below — split out of
    /// `body` (see its doc comment) so this and each column closure below
    /// are their own expressions for the type-checker rather than one
    /// combined with `body`'s whole modifier chain.
    ///
    /// Task #209 (実機フィードバック「初回起動時のメールビューが狭すぎる」):
    /// before this, no column had a `.navigationSplitViewColumnWidth` at
    /// all — `NavigationSplitView`'s own layout heuristic (no min/max to
    /// respect) already tended to give `detailColumn`(本文)the leftover
    /// space at a comfortably large window size, confirmed by resizing an
    /// unmodified build to 1280×832 and observing the message-list column
    /// stay near its intrinsic content width while the detail column
    /// absorbed the rest. But that heuristic has no floor or ceiling: this
    /// same real dev machine's own `~/Library/Preferences` (accumulated
    /// from earlier manual dragging during development, restored
    /// automatically by AppKit per `OtegamiApp`'s `.defaultSize` doc
    /// comment) had the message-list column dragged wide enough to leave
    /// the detail column visibly cramped — exactly the "狭すぎる" symptom,
    /// and exactly the "極端な値で保存されて戻せなくなる" failure mode
    /// Task #209 asks to guard against. `sidebarColumn`/`contentColumn`
    /// below get an explicit `min`/`max` for that reason: SwiftUI clamps
    /// both live interactive drags *and* whatever a stale/degenerate
    /// restored width says into that range, so this device's own
    /// already-drifted state self-heals on the next launch, and no future
    /// drag (however extreme) can wedge either column past a still-usable
    /// bound again. `detailColumn` deliberately gets no explicit width — it
    /// keeps absorbing whatever `sidebarColumn`/`contentColumn` don't claim,
    /// same as before, and the `max` on those other two now doubles as
    /// `detailColumn`'s effective floor (at the `.defaultSize(width: 1200,
    /// ...)` this app now opens at, 1200 − 300 − 460 leaves it >400pt even
    /// at both columns' worst-case `max` simultaneously).
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredColumn) {
            sidebarColumn
                // サイドバー (アカウント/メールボックス木): folder名の折り返し
                // が要らない程度の下限、統合ビューの長いラベルでも余裕を持つ
                // 上限 — 実機目視で選定。
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } content: {
            contentColumn
                // 一覧 (差出人/件名/プレビュー3行): 3行プレビューが極端に
                // 詰まらない下限、そして「一覧が本文を圧迫し続ける」上記の
                // 実機汚染を再発させない上限 — どちらも実機目視で選定。
                .navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 460)
        } detail: {
            detailColumn
        }
    }

    private var sidebarColumn: some View {
        SidebarView(
            selection: $selection,
            onSelected: { _ in preferredColumn = .content },
            onCompose: { presentComposer(.new) },
            onOpenDraft: { draftId in presentComposer(.draft(draftId: draftId)) },
            onOpenServerDraft: { messageId in presentComposer(.serverDraft(messageId: messageId)) }
        )
    }

    private var contentColumn: some View {
        Group {
            if let selection {
                // Task #181 (実機フィードバック「統合ビューを選んだ時、iOS と
                // 同じアカウント絞り込みチップ行が macOS でも欲しい」):
                // 中央ペイン (メール一覧) の上部にチップ行を置く — 3ペイン
                // 構成の中で、絞り込み対象の一覧そのものの直上が自然という
                // 判断 (`showsAccountFilterChipRow`のdoc comment参照)。
                VStack(spacing: 0) {
                    if showsAccountFilterChipRow(for: selection) {
                        AccountFilterChipRow(accounts: environment.accounts, selectedAccountId: $accountFilter)
                    }
                    if AccountDigestPresentation.isVisible(
                        groupByAccount: isGroupByAccount,
                        accountFilter: accountFilter,
                        accountCount: environment.accounts.count,
                        selection: selection
                    ), let role = AccountDigestPresentation.role(for: selection) {
                        AccountDigestSearchBar(searchText: $groupSearchText, isFieldFocused: $isGroupSearchFieldFocused)
                        AccountDigestView(
                            role: role,
                            onSelectAccount: { accountFilter = $0 }
                        )
                    } else {
                        messageList(for: selection)
                    }
                }
            } else {
                ContentUnavailableView(
                    "メールボックスを選択してください",
                    systemImage: "tray",
                    description: Text("左のサイドバーからアカウントを追加、またはメールボックスを選択してください。")
                )
                .navigationTitle("受信トレイ")
            }
        }
        // `AccountDigestSearchBar`に1文字でも入力された瞬間、グループ表示を
        // 解除し時系列表示 (`MessageListView`+`MacListSearchBar`) へ切り替える
        // — 実際の検索入力・実行はそちら側が担う (doc comment参照)。切替後は
        // 次回また閲覧するときに前回の入力が残らないよう`groupSearchText`を
        // 空へ戻す。
        .onChange(of: groupSearchText) { _, newValue in
            guard !newValue.isEmpty else { return }
            isGroupByAccount = false
            groupSearchText = ""
        }
    }

    private func messageList(for selection: SidebarSelection) -> some View {
        MessageListView(
            selection: selection,
            unifiedInboxAccountFilter: accountFilter,
            selectedThreadId: $selectedThreadId,
            selectedMessageId: $selectedMessageId,
            onThreadSelected: { threadId, messageId in
                selectThread(threadId, messageId: messageId, under: selection)
            },
            onSummariesChanged: { currentThreadOrder = $0 },
            // Task #165: only `MessageListRow`'s macOS-only context-menu
            // entries invoke these callbacks.
            onReply: { summary in replySummary(summary, replyAll: false) },
            onReplyAll: { summary in replySummary(summary, replyAll: true) },
            onForward: { summary in forwardSummary(summary) }
        )
    }

    /// Task #181: `MailScreenView.showsAccountFilterChipRow`のmacOS版 —
    /// 統合ビュー (`.unifiedInbox`/`.unifiedRole`、複数アカウントを横断する
    /// 選択) の間だけチップ行を出す。単一アカウントの個別フォルダ
    /// (`.mailbox`) は絞り込む先が1つしか無いため出さない — iOS と同じ
    /// 判断。ダイジェスト表示中も「時系列」へ戻せるよう、表示モードには
    /// 依存させない。
    private func showsAccountFilterChipRow(for selection: SidebarSelection) -> Bool {
        switch selection {
        case .unifiedInbox, .unifiedRole: true
        case .mailbox: false
        }
    }

    private var detailColumn: some View {
        Group {
            if let selectedThreadId {
                ThreadDetailView(
                    threadId: selectedThreadId,
                    singleMessageId: selectedMessageId,
                    // 画面構造改修バッチ (Task #33) で`ThreadDetailView`に
                    // `isFlatModeEntry`が追加された — macOS はここが唯一の
                    // 直接インスタンス化経路 (`ThreadSelectionView`を経由
                    // しない) なので、以前と同じ「`singleMessageId`が非nil
                    // ならフラット行」という判断をそのままここで明示的に渡す
                    // (`ThreadDetailView.isFlatModeEntry`のdoc comment参照)。
                    isFlatModeEntry: selectedMessageId != nil,
                    onReply: { messageId, replyAll in
                        presentComposer(.reply(originalMessageId: messageId, replyAll: replyAll))
                    },
                    onForward: { messageId in presentComposer(.forward(originalMessageId: messageId)) },
                    // Task #184: keeps `isSelectedThreadArchived` (→ ⌘E's menu
                    // label) in sync with this same thread's own live-tracked
                    // archived state, instead of a second independent query —
                    // see that property's doc comment.
                    onArchivedStateChanged: { isSelectedThreadArchived = $0 },
                    // onSearchFromSender: macOS ではまだ配線していない — 新しい
                    // 検索画面 (`SearchScreenView`) は iOS 専用のインフラ
                    // (`MessageDetailFooterToolbar`'s doc comment)。macOS は
                    // 既存の `MessageListView` インライン `.searchable` を持つ
                    // が、それは `contentColumn` (このビューの兄弟) の状態で
                    // あり、この `detailColumn` から直接書き換える手段が
                    // まだ無い。`nil` のときフッターツールバーは検索アイコン
                    // 自体を出さない。
                    onThreadRemoved: handleThreadRemoved
                )
            } else {
                // Task #170: was the English literal "No Message Selected"
                // directly (never localized, always English regardless of
                // the device's language — see check-localizable-coverage.py's
                // "EN-hardcoded" class of finding). Switched to the same
                // Japanese source string `MailScreenView.detailColumn` uses
                // for the iPad-regular-width equivalent of this same empty
                // state, so both share one catalog entry/translation.
                ContentUnavailableView(
                    "メッセージが選択されていません",
                    systemImage: "envelope.open"
                )
                .accessibilityIdentifier("messageDetail.emptyState")
            }
        }
    }

    /// Set only by this project's own XCUITest/verify-script infrastructure
    /// (`scripts/verify-ios-*.sh`'s `screenshot`/`screenshotForeground`
    /// helpers, and the handful of existing `OtegamiUITests` suites that
    /// aren't specifically testing cold-launch navigation) — never passed
    /// by a real launch. Restores the pre-fix "cold launch with an
    /// existing account jumps straight to the message list" shortcut for
    /// exactly those callers, most of which drive the app from a *host*
    /// shell (`xcrun simctl launch`) with no way to synthesize a tap
    /// afterward and were never testing this specific navigation timing in
    /// the first place — see `SidebarView.observeMailboxes(accountId:)`'s
    /// doc comment for why this shortcut is otherwise gone by default.
    private var uiTestsShouldAutoAdvanceToContent: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestsAutoAdvanceToContent")
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) async {
        switch phase {
        case .active:
            // Task #192 (実機クラッシュ 0xDEAD10CC 対策): resumes the shared
            // database *before* anything else in this case touches it — see
            // `AppEnvironment.resumeSharedDatabaseIfNeeded()`'s doc comment.
            // iOS-only: macOS has no shared App Group database to suspend in
            // the first place (`OtegamiAppGroup.identifier`'s doc comment).
            #if os(iOS)
            await environment.resumeSharedDatabaseIfNeeded()
            // プッシュ通知起点バックグラウンド受信 Phase 1: recovers any
            // `NotificationService` Darwin notification
            // (`DatabaseChangeDarwinNotification`) this app missed while
            // suspended in the background — see `AppEnvironment
            // .notifyDatabaseChangesFromPush()`'s doc comment for why a
            // Darwin-notification post alone can't guarantee this app ever
            // saw it. iOS-only for the same reason
            // `resumeSharedDatabaseIfNeeded()` right above is: macOS has no
            // shared App Group database/`NotificationService` Extension to
            // race in the first place.
            await environment.notifyDatabaseChangesFromPush()
            #endif
            // 新着確認 (replay + incremental sync) を IDLE ループ確立より
            // 先に走らせる: `startIdleLoops` は全アカウント分の TLS+LOGIN
            // を await 直列で払うため、先に置くとアクティブ化から新着反映
            // までの体感がその分丸ごと遅れる。IDLE は「この後の」サーバー
            // プッシュを拾うための常設接続で即時性を要求されないのに対し、
            // こちらは「今アクティブになった瞬間の」新規メール確認そのもの。
            await syncAllAccountsOnce()
            await startIdleLoops(for: environment.accounts)
            // G (実機フィードバック第3弾): the OS's notification settings
            // (badge on/off) can change at any time while this app is
            // backgrounded, with no notification this app receives when it
            // does — re-check on every foreground return, not just once at
            // launch (`AppEnvironment.refreshBadgeObservation()`'s doc
            // comment).
            environment.refreshBadgeObservation()
            // M9 follow-up (実機バグ1): self-heals relay watch drift
            // (deleted-account watches left over from a failed best-effort
            // `DELETE`, or a local account missing its watch) — the `GET
            // /v1/watches` fetch itself runs on every single foreground
            // unconditionally (Task #210: a daily-only fetch left a
            // relay-side watch wipe unrepaired for up to 24h — see
            // `AppEnvironment.reconcilePushWatchesIfNeeded()`'s doc
            // comment), throttled only against retrying a fetch that just
            // failed.
            await environment.reconcilePushWatchesIfNeeded()
            // Task #31 (docs/roadmap.md, さっき読んだメールも起動し直すと読み込みが
            // 入る): background-prefetches bodies for the unified inbox's
            // most recent not-yet-fetched messages so opening one usually
            // doesn't pay a network round trip. Deliberately a detached,
            // low-priority, un-awaited `Task` — unlike everything else in
            // this case, it must never delay `.active` handling itself;
            // `SyncCoordinator.prefetchUnifiedInboxBodiesIfNeeded` is its
            // own debounce/best-effort unit, safe to fire on every
            // foreground return.
            Task(priority: .background) { await environment.prefetchRecentBodiesIfNeeded() }
            // Task #89: pulls any display-settings change another device
            // pushed while this one was backgrounded. `SettingsCloudSyncEngine`
            // has no per-write push hook (`AppSettingsCloudDirectory`'s doc
            // comment), so every foreground return is also this device's
            // chance to notice a local change made just before it was last
            // backgrounded — see the `.background`/`.inactive` case below for
            // the other half of that pair.
            await environment.settingsCloudSync.reconcile()
        case .background, .inactive:
            // Task #192 (実機クラッシュ 0xDEAD10CC 対策): posts GRDB's
            // suspend notification as the very first thing this case does
            // — before `stopAllIdleLoops`/`finalizeNow` below, whose own
            // database writes should already see the database as suspended
            // if they race this exact transition (`AppEnvironment
            // .suspendSharedDatabaseIfNeeded()`'s doc comment covers how
            // `SyncEngine` handles the resulting `SQLITE_INTERRUPT`/
            // `SQLITE_ABORT` gracefully — no crash, no error banner).
            // iOS-only, same reasoning as the `.active` case's matching call.
            #if os(iOS)
            await environment.suspendSharedDatabaseIfNeeded()
            #endif
            await environment.syncCoordinator.stopAllIdleLoops()
            // Phase 3 (IMAP 接続の再利用): `stopAllIdleLoops()` の直後、
            // プールが保持しているアイドル接続 (返却後 TTL 内で接続済みの
            // まま残っているもの) も実切断する — バックグラウンドに接続を
            // 持ったまま入らない、という既存の IDLE ループの方針をプール
            // 側にも揃える。
            await environment.imapSessionPool.drainAll()
            // C7 「アプリを離脱したら即座に送信を確定」— cuts short whatever's
            // left of the countdown the instant the app leaves the
            // foreground, rather than letting it keep counting down
            // unobserved in the background (see `PendingSendCoordinator
            // .finalizeNow()`'s doc comment for why). A no-op if nothing is
            // currently pending.
            await environment.pendingSendCoordinator.finalizeNow()
            // Task #89: pushes any display-settings change made during this
            // foreground session before the app leaves it — see the
            // `.active` case above.
            await environment.settingsCloudSync.reconcile()
        @unknown default:
            break
        }
    }

    private func startIdleLoops(for accounts: [AccountRecord]) async {
        for account in accounts {
            guard let auth = try? await environment.auth(for: account) else { continue }
            await environment.syncCoordinator.startIdleLoop(for: account, auth: auth)
        }
    }

    /// One opQueue replay + incremental sync per account right as the app
    /// becomes active — an IDLE loop only wakes on the *next* server push,
    /// so without this a device that went offline, had changes queued,
    /// and came back online wouldn't flush/pick anything up until the next
    /// unrelated server event. Phase 3: the actual per-account work
    /// (bounded parallelism across IMAP hosts, serialized within a host)
    /// now lives in `AppEnvironment.syncAllAccountsOnce()` — see that
    /// method's doc comment.
    private func syncAllAccountsOnce() async {
        await environment.syncAllAccountsOnce()
    }

    /// Same-session-only convenience: reopens whatever thread was last
    /// read under `selection` (e.g. switching from one mailbox to another
    /// and back) — see `lastOpenedThreadIdBySelectionKey`'s doc comment
    /// for why this can never fire on a cold launch (the dictionary starts
    /// empty every process, so there is structurally nothing to restore).
    /// Still guarded by `-uiTestsSkipThreadRestoration` for
    /// `scripts/verify-ios-m4.sh`'s foreground screenshot phases, which
    /// relaunch mid-script and don't want *this run's own* previously
    /// opened thread reappearing either — never set by the app itself,
    /// harmless in production since nothing else ever passes launch
    /// arguments.
    private func restoreLastOpenedThreadIfNeeded() {
        guard !ProcessInfo.processInfo.arguments.contains("-uiTestsSkipThreadRestoration") else { return }
        guard selectedThreadId == nil,
              let selection,
              let remembered = lastOpenedThreadIdBySelectionKey[selectionKey(for: selection)]
        else { return }
        selectedThreadId = remembered
        selectedMessageId = nil
        preferredColumn = .detail
    }

    /// `MessageListView.onThreadSelected`'s callback: records `threadId` as
    /// both the current detail selection and (keyed by `selectionUnder`)
    /// the "last opened thread" for same-session restoration, then
    /// unconditionally pushes `preferredColumn` forward to `.detail` — see
    /// `MessageListView.onThreadSelected`'s doc comment for why this must
    /// happen on *every* tap rather than only when `selectedThreadId`'s
    /// value actually changes.
    private func selectThread(_ threadId: Int64, messageId: Int64?, under selectionUnder: SidebarSelection) {
        selectedThreadId = threadId
        selectedMessageId = messageId
        lastOpenedThreadIdBySelectionKey[selectionKey(for: selectionUnder)] = threadId
        preferredColumn = .detail
    }

    /// Presents `ComposerView` for `payload` — a sheet on iOS
    /// (`composerPayload` drives `.sheet(item:)` above), a fresh window on
    /// macOS (`WindowGroup(id: "composer")` in `OtegamiApp`'s `Scene`
    /// body). Called from `SidebarView`'s "作成" button and
    /// `ThreadDetailView`'s "返信"/"全員に返信" buttons.
    private func presentComposer(_ payload: ComposerLaunchPayload) {
        #if os(macOS)
        openWindow(id: "composer", value: payload)
        #else
        composerPayload = payload
        #endif
    }

    /// Task #48 (デフォルトメールアプリ対応): handles a `mailto:` URL the OS
    /// handed this app — either because the user tapped a `mailto:` link
    /// somewhere and this app is (or, pre-entitlement, is one of the
    /// candidates for) the handler, or a manual test via
    /// `xcrun simctl openurl booted 'mailto:...'`. Registering
    /// `CFBundleURLTypes` for the `mailto` scheme (project.yml) is what
    /// lets the OS route here at all; actually becoming the system-wide
    /// *default* additionally needs the `com.apple.developer.mail-client`
    /// entitlement Apple grants per-app (`docs/default-mail-app.md`) — this
    /// handler itself works identically either way, since the entitlement
    /// only gates whether the OS is *willing* to route a link here by
    /// default, not what this app does once it receives one.
    ///
    /// Anything that isn't a recognizable `mailto:` URL (`MailtoURLParser
    /// .parse` returning `nil` — wrong scheme, e.g. this app is never
    /// registered for any other custom scheme) is silently ignored, the
    /// same way a real OS integration should degrade for an open it was
    /// never meant to handle rather than surfacing an error UI.
    private func handleOpenURL(_ url: URL) {
        guard let parsed = MailtoURLParser.parse(url) else { return }
        presentComposer(.mailto(MailtoComposePrefill(
            to: parsed.to, cc: parsed.cc, bcc: parsed.bcc, subject: parsed.subject, body: parsed.body
        )))
    }

    private func selectionKey(for selection: SidebarSelection) -> String {
        switch selection {
        case .unifiedInbox: "unified"
        case .mailbox(let mailboxSelection): "mailbox:\(mailboxSelection.mailboxId)"
        // 画面構造改修バッチ (Task #33, 3): macOS の`SidebarView`は
        // `.unifiedRole`を一切生成しない (カテゴリ優先メニューはiOS専用の
        // `FolderListSheet`だけが持つ、`CLAUDE.md`の1a系機能の既存スコープ
        // どおり) — 網羅性のためだけに存在する到達しない分岐。
        case .unifiedRole(let role): "unifiedRole:\(role.rawValue)"
        }
    }

    #if os(macOS)
    // MARK: - Menu commands (M10)

    /// ⇧⌘R: replies to `selectedThreadId`'s newest message — the same
    /// message `ThreadDetailView` expands by default, so this matches
    /// "reply to whatever's currently showing expanded", not an arbitrary
    /// message within the thread.
    /// 実機フィードバック第3弾 (A): replies to `selectedMessageId` directly
    /// when set (a flat-mode single-message open — "reply to whatever's
    /// currently showing", which for that mode is unambiguous), falling
    /// back to the pre-existing "newest message in the thread" rule
    /// otherwise.
    /// Task #165: `replyAll` defaults to `false` for the reply shortcut's
    /// own pre-existing call site — ⌥⇧⌘R (`replyAllAction`) is the only
    /// other caller, passing `true` through to the exact same
    /// target-resolution below.
    private func replyToSelectedThread(replyAll: Bool = false) {
        guard let selectedThreadId else { return }
        if let selectedMessageId {
            presentComposer(.reply(originalMessageId: selectedMessageId, replyAll: replyAll))
            return
        }
        Task {
            let messages = (try? await environment.database.dbWriter.read { db in
                try ThreadQuery.messages(threadId: selectedThreadId, db: db)
            }) ?? []
            guard let newestMessageId = messages.last?.id else { return }
            presentComposer(.reply(originalMessageId: newestMessageId, replyAll: replyAll))
        }
    }

    /// ⇧⌘F: forwards the same "target message" `replyToSelectedThread(replyAll:)`
    /// resolves — `selectedMessageId` for a flat-mode open, otherwise the
    /// thread's newest message.
    private func forwardSelectedThread() {
        guard let selectedThreadId else { return }
        if let selectedMessageId {
            presentComposer(.forward(originalMessageId: selectedMessageId))
            return
        }
        Task {
            let messages = (try? await environment.database.dbWriter.read { db in
                try ThreadQuery.messages(threadId: selectedThreadId, db: db)
            }) ?? []
            guard let newestMessageId = messages.last?.id else { return }
            presentComposer(.forward(originalMessageId: newestMessageId))
        }
    }

    /// Task #165 (macOS 操作体系再設計): ⌘E — routes through the same shared
    /// `MessageRemoval.commit` layer `deleteSelectedThread()`/`ThreadDetailView
    /// .commitRemoval(_:)`/`MessageListView.archiveThread(_:)` all use, so
    /// this menu command gets the same Task #120 pending-relocation and
    /// Task #163 pinned-thread guard behavior for free rather than
    /// reimplementing a fourth, possibly-drifting copy. Reuses
    /// `ThreadDetailView.threadSummary(threadId:singleMessageId:accountId:db:)`
    /// (relaxed from `private` to internal for this call site — same module,
    /// no behavior change) instead of duplicating that adapter a second time.
    /// Unlike `MessageListView`'s row swipe/context-menu path, a pinned
    /// thread's blocked archive has no toast here — this command surface has
    /// none of that view's undo-toast infrastructure, so it just silently
    /// no-ops, matching this method's own pre-existing best-effort `catch`.
    private func archiveSelectedThread() {
        guard let selectedThreadId else { return }
        let targetMessageId = selectedMessageId
        Task {
            do {
                let outcome: (removed: Bool, accountId: String)? = try await environment.database.dbWriter.write { db in
                    guard let thread = try ThreadRecord.fetchOne(db, key: selectedThreadId) else { return nil }
                    guard let summary = try ThreadDetailView.threadSummary(
                        threadId: selectedThreadId, singleMessageId: targetMessageId, accountId: thread.accountId, db: db
                    ) else { return (false, thread.accountId) }
                    // Task #184: `summary.isArchived` is already computed by
                    // `threadSummary` (`ThreadDetailView.isThreadArchived`'s
                    // doc comment covers the same OR-aggregate/per-message-
                    // guard reasoning this reuses) — no second query needed.
                    let kind: MessageRemoval.Kind = summary.isArchived ? .unarchive : .archive
                    let removed = try MessageRemoval.commit(
                        kind, summary: summary, accountId: thread.accountId, db: db,
                        markSeenOnArchive: ArchiveActionSettingsStore.markAsReadOnArchive
                    ) != nil
                    return (removed, thread.accountId)
                }
                guard let outcome, outcome.removed else { return }
                if targetMessageId != nil {
                    self.selectedThreadId = nil
                    self.selectedMessageId = nil
                } else {
                    handleThreadRemoved(selectedThreadId)
                }
                guard let account = environment.accounts.first(where: { $0.id == outcome.accountId }) else { return }
                guard let auth = try? await environment.auth(for: account) else { return }
                _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
            } catch is MessageRemoval.ArchiveGuardError {
                // Task #163: pinned — see this method's doc comment.
            } catch {
                // Best-effort, matching `deleteSelectedThread()`.
            }
        }
    }

    /// Task #165: ⇧⌘U — mirrors `MessageListView.toggleRead(_:)`'s own
    /// direction rule (mark every targeted message read if any of them is
    /// currently unread, mark them all unread otherwise) and its
    /// `applyReadState(_:markingRead:)` write, reimplemented here for the
    /// same reason `deleteSelectedThread()`'s doc comment already gives —
    /// this view has no access to that sibling view's private method.
    private func toggleReadSelectedThread() {
        guard let selectedThreadId else { return }
        let targetMessageId = selectedMessageId
        Task {
            do {
                let accountId: String? = try await environment.database.dbWriter.write { db in
                    guard let thread = try ThreadRecord.fetchOne(db, key: selectedThreadId) else { return nil }
                    guard let summary = try ThreadDetailView.threadSummary(
                        threadId: selectedThreadId, singleMessageId: targetMessageId, accountId: thread.accountId, db: db
                    ) else { return nil }
                    let markingRead = summary.thread.unreadCount > 0
                    let messages = try ThreadQuery.actionTargets(for: summary, db: db)
                    for var message in messages {
                        if markingRead {
                            guard !message.flags.contains(.seen) else { continue }
                            message.flags.insert(.seen)
                        } else {
                            guard message.flags.contains(.seen) else { continue }
                            message.flags.remove(.seen)
                        }
                        message.updatedAt = Date()
                        try message.update(db)
                        guard !message.isPendingRelocation,
                              let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId)
                        else { continue }
                        try OpQueue.enqueueSetFlags(
                            accountId: thread.accountId, mailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                            uids: [UInt32(message.uid)], flags: message.flags, db: db
                        )
                    }
                    try ThreadAssigner.recomputeAggregates(threadId: selectedThreadId, db: db)
                    return thread.accountId
                }
                guard let accountId, let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
                guard let auth = try? await environment.auth(for: account) else { return }
                _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
            } catch {
                // Best-effort, matching `deleteSelectedThread()`.
            }
        }
    }

    /// ⌘⌫: moves every message in `selectedThreadId` to Trash — the same
    /// opQueue-enqueuing path `MessageListView.deleteThread(_:)` uses for
    /// its trailing swipe action, reimplemented here rather than shared
    /// because `MessageListView` doesn't currently expose that logic to a
    /// sibling view; both read from `ThreadQuery`/write through `OpQueue`
    /// the same way, so they can't drift in behavior even though the code
    /// isn't literally shared. Clears the selection afterward, same as a
    /// swipe-deleted row disappearing from the list would.
    /// 実機フィードバック第3弾 (A): deletes just `selectedMessageId` when set
    /// (a flat-mode single-message open), the whole thread otherwise — same
    /// narrowing `MessageListView`'s row actions and `ThreadDetailView`'s
    /// own "…" menu delete already apply (`OtegamiStore.ThreadQuery
    /// .actionTargets(for:db:)`'s doc comment). Always pops back to
    /// "No Message Selected" for the single-message case rather than
    /// calling `handleThreadRemoved` — see `ThreadDetailView
    /// .notifyThreadRemoved()`'s doc comment for why "次のメールを開く"
    /// can't be resolved for a flat-mode open with the ordering data
    /// available here.
    private func deleteSelectedThread() {
        guard let selectedThreadId else { return }
        let targetMessageId = selectedMessageId
        Task {
            do {
                let accountId: String? = try await environment.database.dbWriter.write { db -> String? in
                    let messages: [MessageRecord]
                    if let targetMessageId {
                        messages = try MessageRecord.fetchOne(db, key: targetMessageId).map { [$0] } ?? []
                    } else {
                        messages = try ThreadQuery.messages(threadId: selectedThreadId, db: db)
                    }
                    guard let thread = try ThreadRecord.fetchOne(db, key: selectedThreadId) else { return nil }
                    for message in messages {
                        guard let messageId = message.id, let uid = UInt32(exactly: message.uid) else { continue }
                        guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { continue }
                        try OpQueue.enqueueDelete(
                            accountId: thread.accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                            uids: [uid], db: db
                        )
                        try FTSIndexer.delete(messageId: messageId, db: db)
                        try MessageRecord.deleteOne(db, key: messageId)
                    }
                    try ThreadAssigner.recomputeAggregates(threadId: selectedThreadId, db: db)
                    return thread.accountId
                }
                if targetMessageId != nil {
                    self.selectedThreadId = nil
                    self.selectedMessageId = nil
                } else {
                    handleThreadRemoved(selectedThreadId)
                }
                guard let accountId, let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
                guard let auth = try? await environment.auth(for: account) else { return }
                _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
            } catch {
                // Best-effort, matching every other opQueue-enqueuing path
                // in this app — a failure here just means the thread stays.
            }
        }
    }

    /// ⌘]/⌘[: cycles `selection` through "すべての受信トレイ" followed by
    /// every account's mailboxes in the sidebar's own display order
    /// (`MailboxQuery.request`'s ordering — inbox-role first, then
    /// alphabetical), across every account in `environment.accounts` order.
    /// Wraps around at either end rather than stopping, matching what a
    /// "next/previous" pair of menu items conventionally does.
    private func cycleMailboxSelection(by direction: Int) {
        Task {
            var flattened: [SidebarSelection] = [.unifiedInbox]
            for account in environment.accounts {
                // メールボックス単位の非表示: skip hidden mailboxes, matching
                // the sidebar tree this cycles through (`SidebarView`'s own
                // `includeHidden: false` observation) — a hidden mailbox
                // isn't a selectable row there either.
                let mailboxes = (try? await environment.database.dbWriter.read { db in
                    try MailboxQuery.request(accountId: account.id, includeHidden: false).fetchAll(db)
                }) ?? []
                for mailbox in mailboxes {
                    guard let mailboxId = mailbox.id else { continue }
                    flattened.append(.mailbox(MailboxSelection(accountId: account.id, mailboxId: mailboxId)))
                }
            }
            guard !flattened.isEmpty else { return }
            let currentIndex = selection.flatMap { flattened.firstIndex(of: $0) }
            let nextIndex: Int
            if let currentIndex {
                nextIndex = (currentIndex + direction + flattened.count) % flattened.count
            } else {
                nextIndex = 0
            }
            selection = flattened[nextIndex]
        }
    }
    #endif
}

#Preview {
    RootView()
        .environment(AppEnvironment())
}
