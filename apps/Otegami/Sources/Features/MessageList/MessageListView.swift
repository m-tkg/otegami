import SwiftUI
import GRDB
import GoogleOAuth
import OtegamiCore
import OtegamiStore
import SyncEngine
import MailTransport
import os

/// The selected sidebar item's threads, newest-first (M4: thread rows, not
/// individual messages — plan: "MessageListView をスレッド単位表示に変更").
/// Works fully offline: it only ever reads from `AppDatabase`, either one
/// mailbox's threads (`SidebarSelection.mailbox`) or the cross-account
/// "すべての受信トレイ" unified inbox (`SidebarSelection.unifiedInbox`, plan:
/// "アカウント境界を跨いだスレッド結合はしない" — each row is still one
/// account's thread, just interleaved by date across accounts). Refreshing —
/// pull-to-refresh on iOS, pull-to-refresh or `MacListSearchBar`'s refresh
/// button on macOS (新画面構成: iOS 側のヘッダ再読込ボタンは廃止、
/// pull-to-refresh に一本化) — is what triggers `SyncCoordinator` to talk to
/// the server; with no network the list still renders whatever's already
/// stored.
///
/// Design-phase-2 (1a/1d/1g/1h): the platforms now diverge more than they
/// used to. macOS keeps everything from before this pass unchanged — its
/// own `.navigationTitle` and swipe/context menu semantics. Its search bar
/// (M7) moved off the system `.searchable` and into its own `MacListSearchBar`
/// row (Task #197, this file's `body` doc comment). iOS drops
/// `.navigationTitle`/search from this view entirely (the enclosing
/// `MailScreenView` owns the plain title and search opens in a
/// `SearchScreenView` sheet) and
/// gains 1g's redesigned swipe actions, 1h's long-press bulk-selection mode,
/// and an undo toast for the two destructive bulk-capable actions (delete,
/// archive). Every macOS-only addition/removal below is behind `#if
/// os(macOS)`/`#if os(iOS)` so this stays one file rather than forking into
/// two near-duplicates.
struct MessageListView: View {
    // Access widened from `private` to internal (matches `ComposerView`/
    // `MessageView`'s identical widening): read from
    // `MessageListView+Sync.swift`/`+RowActions.swift`/`+Selection.swift`,
    // each a different file.
    @Environment(AppEnvironment.self) var environment
    let selection: SidebarSelection
    /// 1a's account filter chips: when `selection` is `.unifiedInbox`/
    /// `.unifiedRole` and this is non-`nil`, only that one account's
    /// matching mailboxes are observed (the "仕事"/"個人"-style chip)
    /// instead of every account (the "すべて" chip). `nil` for the "すべて"
    /// chip itself and for `.mailbox` selections (a single mailbox has
    /// nothing to filter further), so this parameter doesn't change
    /// `ThreadQuery.unifiedInboxSummariesObservation`'s existing
    /// accountIds-across-every-account behavior unless a caller opts in.
    ///
    /// Task #181 (実機フィードバック「統合ビューを選んだ時、iOS と同じ
    /// アカウント絞り込みチップ行が macOS でも欲しい」): それまでは常に
    /// `nil`だった macOS 呼び出し元 (`RootView.contentColumn`) も、この
    /// タスク以降は自前の`accountFilter`をここへ渡す — `1a`(この doc
    /// comment) が指す機能自体は iOS の情報設計から来たものだが、この
    /// パラメータ自体はもう「iOS専用」ではない (`docs/design-system.md`
    /// のTask #181節参照)。
    var unifiedInboxAccountFilter: String? = nil
    // By id (`ThreadRecord` isn't `Hashable` in the `List(selection:)`
    // sense this project uses — see M2's doc note on why rows are plain
    // `Button`s instead). Set directly from a `Button` action per row; the
    // compact-width column push to `ThreadDetailView` once this changes is
    // driven by `RootView`'s `preferredCompactColumn` (macOS's
    // `NavigationSplitView`) or `MailScreenView.compactNavigationStack`'s
    // `.navigationDestination` (iOS).
    @Binding var selectedThreadId: Int64?
    /// 実機フィードバック第3弾 (A): the tapped row's `singleMessageId` —
    /// `nil` for a grouped-mode row, the tapped message's own id for a
    /// flat-mode row — written alongside `selectedThreadId` on every tap so
    /// whichever screen owns navigation (`MailScreenView`/`RootView`) can
    /// forward it to `ThreadDetailView.singleMessageId` and open just that
    /// one message instead of the whole accordion thread (see that
    /// property's doc comment). A plain `@Binding` — not folded into
    /// `onThreadSelected`'s callback — for the same reason `selectedThreadId`
    /// itself already is one: `MailScreenView`'s `NavigationStack` drives
    /// its push purely off `.navigationDestination(item: $selectedThreadId)`
    /// without ever overriding `onThreadSelected`, so a binding is the only
    /// way that call site actually observes this value. Required (no
    /// default), matching `selectedThreadId`'s own convention — both actual
    /// call sites (`MailScreenView`, `RootView.contentColumn`) already pass
    /// a real `@State`-backed binding.
    @Binding var selectedMessageId: Int64?
    /// Called on *every* row tap, in addition to writing `selectedThreadId`
    /// directly — mirrors `SidebarView.onSelected`'s doc comment: a
    /// re-tap of the row for the thread that's already `selectedThreadId`
    /// (e.g. after popping back from `ThreadDetailView` via the system
    /// back button, then reopening the same thread) doesn't change the
    /// binding's value, so an `onChange(of: selectedThreadId)`-driven push
    /// of `preferredCompactColumn` never fires a second time
    /// (docs/verify.md, "メール本文 → 戻る → 一覧の「さっき見ていたスレッド」
    /// 行だけタップ不能"). `RootView`/`MailScreenView` use this unconditional
    /// callback to force the column/push forward every time instead. The
    /// second parameter is `summary.singleMessageId` (実機フィードバック
    /// 第3弾 (A)) — `nil` for a grouped-mode row.
    var onThreadSelected: (Int64, Int64?) -> Void = { _, _ in }
    /// 1h: fires whenever this view enters/exits bulk-selection mode, so an
    /// iOS-only enclosing `MailScreenView` can replace its toolbar and hide
    /// its speed-dial FAB while the selection nav/bottom bar
    /// below take over. Never called on macOS (no long-press gesture there
    /// to trigger it in the first place).
    var onSelectionModeChanged: (Bool) -> Void = { _ in }
    /// G「削除・アーカイブ時の挙動」: reports the currently-displayed thread
    /// order (by `thread.id`, in on-screen order) every time `summaries`
    /// changes, so a parent that also owns `ThreadDetailView`'s
    /// `onThreadRemoved` (`MailScreenView` on iOS, `RootView` on macOS) can
    /// resolve `MessagePostActionSettingsStore.nextThreadId(after:in:action:)`
    /// against a reasonably fresh snapshot. Not called for `searchResults`
    /// (this view's own inline `.searchable`, macOS only) — search's own
    /// ordering isn't in scope for this setting (`ThreadDetailView
    /// .onThreadRemoved`'s doc comment).
    var onSummariesChanged: ([Int64]) -> Void = { _ in }

    // MARK: - macOS 操作体系再設計 (Task #165)

    /// Forwarded straight to `MessageListRow`'s macOS-only context menu —
    /// see that type's own `onReply`/`onReplyAll` doc comment. Default
    /// no-ops so every existing iOS call site (`MailScreenView`) keeps
    /// compiling unchanged; only `RootView`'s macOS `contentColumn` passes
    /// real closures.
    var onReply: (ThreadSummary) -> Void = { _ in }
    var onReplyAll: (ThreadSummary) -> Void = { _ in }
    var onForward: (ThreadSummary) -> Void = { _ in }

    /// ヘッダのタイトル横の件数表示 (`MailScreenView.toolbarContent`)を
    /// メッセージ単位の未読数に変更した際の追加コールバック (Task #74 の
    /// 「今表示されてる件数」だった旧仕様からの変更 — ユーザー指示「スレッド
    /// 表示 ON のとき、スレッド数ではなくメッセージ単位の未読数を出す」)。
    /// `onSummariesChanged`の`currentThreadOrder.count`は「今画面に読み込み
    /// 済みの行数」(ページングで切られる、スレッド集約時はスレッド数)
    /// だったのに対し、これは`selection`(と`unifiedInboxAccountFilter`)が
    /// 表す "今のボックススコープ" 全体のメッセージ単位未読数
    /// (`observeUnreadCountInScope()`) — ページング・未読のみ表示・
    /// スレッド/フラット表示のどれにも左右されない一つの定義。`summaries`
    /// とは独立した`.task(id:)`で観測するので (下の`UnreadCountObservationKey`)、
    /// ページング用の`pageLimit`が変わっても不要な再クエリは起きない。
    var onUnreadCountChanged: (Int) -> Void = { _ in }

    /// Task #108 (実機報告「元に戻すトーストが検索・新規作成 FAB の背面に
    /// 描画され重なる」): `MailScreenView`のフローティングボタン
    /// (`floatingSearchButton`/`floatingComposeButton`) はこの`View`より
    /// **外側**の`overlay`として親 (`MailScreenView.content`) に付いている
    /// — SwiftUI の`.overlay`チェーンは後から適用したものほど手前に描画
    /// されるため、親のフローティングボタンは常にこの`View`自身の内部
    /// `overlay`(旧`UndoToast`表示)より手前に来てしまい、`zIndex`だけでは
    /// 越えられない (`zIndex`はその`overlay`が作る`ZStack`の中でしか効か
    /// ない)。根本修正として、undo トーストの表示自体を`MailScreenView`側
    /// (フローティングボタンより後に付ける`overlay`)に持ち上げられるよう、
    /// `suppressInternalUndoToast: true`のとき内部描画を止め、状態変化を
    /// この`onPendingUndoChanged`で親へ伝える。`macOS`(`RootView`)の呼び
    /// 出し元はこのパラメータもコールバックも渡さず既定値のままなので、
    /// 挙動は変わらない (内部描画のまま)。
    var suppressInternalUndoToast = false
    /// See `suppressInternalUndoToast`'s doc comment — fires with the
    /// current `pendingUndo` (`nil` when there is none) every time it
    /// changes, regardless of `suppressInternalUndoToast`'s value (cheap,
    /// and harmless for callers that don't use it — the default no-op).
    var onPendingUndoChanged: (UndoToastPayload?) -> Void = { _ in }

    /// A read-only, display-only projection of the private `PendingUndo` —
    /// just enough for a parent to render an `UndoToast` itself
    /// (`onPendingUndoChanged`'s doc comment). Intentionally doesn't expose
    /// `threadIds`/`accountIds`: those only matter to this view's own
    /// `scheduleUndo`/`undoPending`/`.onChange(of: scenePhase)` bookkeeping.
    struct UndoToastPayload {
        let message: String
        /// Task #163: `nil` for a blocked-action notice — see
        /// `PendingUndo.undo`'s doc comment.
        let onUndo: (() -> Void)?
    }

    /// Backstop for `scheduleUndo`'s delayed commit — see that method's doc
    /// comment on why a background/terminate transition has to flush any
    /// pending delete/archive immediately rather than letting the undo
    /// window's `Task.sleep` run its course. Read via `.onChange` in `body`
    /// (declaring `@Environment(\.scenePhase)` directly is enough; no
    /// binding needed since this view never itself drives scene phase).
    @Environment(\.scenePhase) private var scenePhase

    // `summaries`/`isSyncing`/`syncErrorMessage`/`syncProgress`/
    // `activeSyncTask` below: access widened from `private` to internal —
    // read/written from `MessageListView+Sync.swift`, a different file.
    @State var summaries: [ThreadSummary] = []
    @State var isSyncing = false
    @State var syncErrorMessage: String?
    /// Task #194 (「Pull to refresh が長すぎて終わらない。どのくらい進んでいるのか
    /// のバーを出せるなら出したい。またキャンセルもできるようにして欲しい」):
    /// the most recent `MailboxSyncer.SyncProgressUpdate` from whichever
    /// account/mailbox `refresh()` is currently syncing — `nil` whenever
    /// `isSyncing` is `false`, or briefly while a sync is running but hasn't
    /// reported anything yet. Drives `SyncProgressBanner` (shown alongside
    /// SwiftUI's own `.refreshable` pull spinner, not replacing it — see
    /// that view's doc comment for why this needs its own indicator at all).
    @State var syncProgress: MailboxSyncer.SyncProgressUpdate?
    /// The `Task` actually driving the current `refresh()` call's sync work
    /// — separate from whatever `Task` `.refreshable`/a toolbar button
    /// itself created to call `refresh()`, so `SyncProgressBanner`'s
    /// キャンセル button has something concrete to cancel. `nil` whenever
    /// no sync is in flight.
    @State var activeSyncTask: Task<Void, Never>?

    // MARK: - Archive view detection (Task #87, 1)

    /// `true` while `selection` shows an archive view — see
    /// `refreshArchiveViewFlag()`'s doc comment for exactly how this is
    /// decided. Forwarded to every `MessageListRow` as `isArchiveView`,
    /// which is what actually swaps the archive swipe slot/context-menu
    /// row over to "アーカイブ解除". Starts `false` (not "archive") so a
    /// fresh selection never briefly shows the wrong slot before
    /// `refreshArchiveViewFlag()`'s first read completes.
    @State private var isArchiveView = false

    // MARK: - Junk view detection (「迷惑メール解除」)

    /// `true` while `selection` shows a junk view — the exact `isArchiveView`
    /// analogue for 迷惑メール, decided by `refreshJunkViewFlag()`. Forwarded
    /// to every `MessageListRow` as `isJunkView`, which swaps the junk swipe
    /// slot/context-menu row over to "迷惑メール解除". Starts `false` for the
    /// same reason `isArchiveView` does.
    @State private var isJunkView = false

    // MARK: - Trash view detection (「ゴミ箱を空にする」)

    /// `true` while `selection` shows a trash view — the `isArchiveView`/
    /// `isJunkView` analogue for ゴミ箱, decided by `refreshTrashViewFlag()`.
    /// Gates the "空にする" toolbar button (`MessageListView+EmptyTrash.swift`)
    /// — unlike アーカイブ/迷惑メール, there's no swipe-slot substitution to
    /// drive, just this one button's visibility.
    @State var isTrashView = false

    // MARK: - Empty trash (「ゴミ箱を空にする」、MessageListView+EmptyTrash.swift)

    /// 非`nil`の間、確認`.alert`を表示する — 対象件数 (「N件のメールを完全に
    /// 削除します」の N)。`requestEmptyTrash()`がタップ時に対象メールボックス
    /// の実件数を読んでからセットする (`displayedSummaries.count`のような
    /// 近似値ではなく正確な件数を見せるため — スレッド表示 ON だと1スレッド
    /// に複数メッセージが載ることがあり、スレッド数とメッセージ数は一致
    /// しない)。
    @State var pendingEmptyTrashCount: Int?
    /// `pendingEmptyTrashCount`と対になる、実際に空にする対象
    /// (アカウントID・メールボックスID の組) — 統合ゴミ箱ビューでは複数
    /// アカウント分になりうる。
    @State var pendingEmptyTrashTargets: [EmptyTrashTarget] = []

    // MARK: - Pagination (M10, docs/performance.md)

    /// How many threads `observeThreads()` currently requests — starts at
    /// `Self.pageStep` and grows by the same amount each time the last row
    /// scrolls into view (`loadMoreIfNeeded(currentItem:)`). Without this,
    /// a 100k-message mailbox's `ValueObservation` would fetch (and
    /// `ThreadQuery.summaries(forThreads:)` would N+1-query) every thread
    /// up front — see docs/performance.md's "改善1"/"改善3" for the
    /// measured cost of that. Reset to `Self.pageStep` whenever `selection`
    /// changes so switching mailboxes doesn't keep whatever page depth the
    /// previous mailbox had scrolled to.
    // `pageLimit`/`pageStep`: widened from `private` to internal — read
    // from `MessageListView+Sync.swift`'s `loadMoreIfNeeded(currentItem:)`,
    // a different file.
    @State var pageLimit = MessageListView.pageStep
    static let pageStep = 200

    // MARK: - Search (M7, macOS only as of design-phase-2 — see this
    // type's doc comment)

    // Widened from `private` to internal: read/written from
    // `MessageListView+Sync.swift`'s `scheduleSearch()`/`performSearch(query:scope:)`,
    // a different file.
    @State var searchText = ""
    @State var searchScope: SearchScopeOption = .all
    @State var searchResults: [ThreadSummary] = []
    @State var isSearching = false
    @State var searchTask: Task<Void, Never>?
    /// M10: bound to `.searchFocused` — see the modifier's usage site below
    /// for why (⌘F's target, macOS only — Task #165 moved this off ⇧⌘F to
    /// free that combination for "転送", see `OtegamiCommands`'s doc comment).
    @FocusState private var isSearchFieldFocused: Bool

    // MARK: - Bulk selection (1h, iOS only)

    // Widened from `private` to internal: read/written from
    // `MessageListView+Selection.swift`, a different file.
    @State var isSelecting = false
    @State var selectedThreadIds: Set<Int64> = []

    // MARK: - Undo (1h/1g: "即時反映＋Undo（トースト）")

    /// A destructive action (delete/archive, single-row swipe or bulk)
    /// whose local database write has **already happened** — see
    /// `commitDelete`/`commitArchive`'s doc comment for why this design
    /// commits immediately rather than delaying the write itself (a real
    /// data-loss bug the first version of this feature had). What
    /// `scheduleUndo` actually delays is the *network* replay attempt;
    /// `undo` reverses the local write and cancels the not-yet-replayed
    /// opQueue rows if the user taps "元に戻す" before that.
    /// (`PendingUndo` itself lives in `MessageListView+Undo.swift`; access
    /// widened from `private` to internal on this and the two declarations
    /// below since `MessageListView+Undo.swift`'s functions read/write them
    /// from a different file.)
    @State var pendingUndo: PendingUndo?
    @State var pendingUndoTask: Task<Void, Never>?
    /// How long an undo toast stays up before its queued opQueue rows are
    /// allowed to actually replay to the server. 5s matches the common
    /// "Gmail-style" undo window long enough to react to, short enough not
    /// to leave a destructive action feeling unfinished.
    static let undoWindow: Duration = .seconds(5)

    /// Restarts the thread observation whenever the selection changes *or*
    /// the account list changes — the latter matters for the unified inbox:
    /// adding a second account (M4 verification scenario (c)) should widen
    /// which accounts' inbox threads it observes without needing a manual
    /// refresh or relaunch.
    ///
    /// Task #135 (実機報告「設定でスレッド表示を on/off して設定シートを
    /// 閉じても、一覧が新モードで更新されない」): `isThreadingEnabled` is a
    /// field here *in addition to* `isFlatMode` even though `isFlatMode`
    /// alone is what `observeThreads()` actually uses to pick the query —
    /// see `isFlatMode`'s own doc comment for why it deliberately reads
    /// `ListDisplaySettingsStore.persistedBool(forKey:default:)` (a raw
    /// `UserDefaults` read) rather than trusting `isThreadingEnabled`'s
    /// `@AppStorage`-cached value directly (#82/#105: a per-view
    /// `@AppStorage` cache can still be stale right after launch). That
    /// defense has a cost this task's bug is the real-device symptom of:
    /// a `@AppStorage` property only makes SwiftUI re-invoke `body` (and
    /// therefore reconstruct this key and re-fire `.task(id:)`) when the
    /// view actually *reads* that property while building `body`. Every
    /// read of `isThreadingEnabled` in this file used to be
    /// `#if os(macOS)`-only (the inline-search `.onChange(of:
    /// isThreadingEnabled)` below) — on iOS nothing in `body` ever touched
    /// the property, so SwiftUI never subscribed to `threadingKey` changes
    /// there at all, and toggling it in `MailListSettingsView` (a sibling
    /// view's own `@AppStorage` on the same key) never re-ran this view's
    /// `body`, no matter how correct `isFlatMode`'s persisted-value read
    /// was — a `.task(id:)` can't refire from a change nothing ever
    /// noticed. Including `isThreadingEnabled` here anchors that read
    /// (`ObservationKey(...)` is built while constructing `body`, so this
    /// field's value has to actually be read) on every platform, which is
    /// exactly `persistedUnreadOnly`'s existing doc comment: it names
    /// `emptyStateTitle`'s direct read of `isUnreadOnly` as what "keeps
    /// SwiftUI's change-tracking subscribed to this key" for that setting
    /// — `isThreadingEnabled` had no such unconditional read anywhere
    /// until this field. `observeThreads()` still only ever consults
    /// `isFlatMode`'s persisted-value read for the actual query choice, so
    /// this doesn't reintroduce the #82/#105 stale-on-launch bug either of
    /// those fixed — this field only exists to make the view re-render (and
    /// therefore re-read `isFlatMode` fresh) the moment the setting
    /// changes, not to feed the query decision itself.
    private struct ObservationKey: Hashable {
        var selection: SidebarSelection
        var accountFilter: String?
        var accountIds: [String]
        var pageLimit: Int
        var isFlatMode: Bool
        var isThreadingEnabled: Bool
        var unreadOnly: Bool
        /// Task #142: 「フラグ付きのみ表示」トグルの現在値
        /// (`persistedPinnedOnly`) — `unreadOnly`と同じ役割・同じ理由。
        var pinnedOnly: Bool
    }

    /// `onUnreadCountChanged`'s own `.task(id:)` key — deliberately *not*
    /// `ObservationKey` above: this count doesn't depend on `pageLimit`
    /// (unread-in-scope isn't paginated the way the visible row list is)
    /// or `isFlatMode`/`unreadOnly` (see `onUnreadCountChanged`'s doc
    /// comment — one definition regardless of display mode), so reusing
    /// `ObservationKey` would restart this observation on every page-load
    /// scroll for no reason.
    private struct UnreadCountObservationKey: Hashable {
        var selection: SidebarSelection
        var accountFilter: String?
        var accountIds: [String]
    }

    // MARK: - フラット表示 (B3)

    /// The inverse of the 「スレッド表示」 setting — when threading is *off*,
    /// `observeThreads()` queries
    /// `ThreadQuery.flatSummaries`/`unifiedInboxFlatSummaries` (one row per
    /// message) instead of `summariesObservation`/
    /// `unifiedInboxSummariesObservation` (one row per thread), but still
    /// populates the very same `summaries: [ThreadSummary]` this view
    /// already renders through `MessageListRow`/`ThreadRowView` — see
    /// `ThreadSummary.init(flatMessage:accountId:)`'s doc comment for how a
    /// single message masquerades as a "thread of one" with zero changes to
    /// either row view.
    ///
    /// Search (macOS's inline mailbox search here via `performSearch`, and
    /// iOS's separate `SearchScreenView`) also respects this setting now —
    /// `SearchQuery.flatMessageSummaries` mirrors this same split. A prior
    /// pass left search always thread-grouped regardless of this setting,
    /// reasoned (without live device verification) to be an acceptable gap
    /// since search results are a comparatively small, transient list. A
    /// real-device report ("スレッド表示をオフにしてるのに、スレッドで表示
    /// されることがある") confirmed that gap was in fact user-visible and
    /// worth closing — see `performSearch`'s doc comment for the fix.
    ///
    /// Also deliberate: every row action (既読/未読・アーカイブ・迷惑メール・
    /// ピン留め・削除) still operates on the row's *whole* underlying thread
    /// even in flat mode, not just the one message the row displays — see
    /// `ThreadSummary.init(flatMessage:accountId:)`'s doc comment. Acting on
    /// any message in a conversation moving/removing the whole conversation
    /// is normal mail-client behavior (and exactly what grouped mode
    /// already does), and building a fully separate per-message action path
    /// alongside the existing thread-scoped one would have doubled this
    /// view's already-large action surface for comparatively little
    /// day-to-day benefit — flat mode's core promise ("一覧がメール単位になる")
    /// is about *what's shown*, not a new per-message operation model.
    @AppStorage(ListDisplaySettingsStore.threadingKey) private var isThreadingEnabled = ListDisplaySettingsStore.defaultThreading

    // MARK: - 未読のみ表示 (ヘッダのトグル — see `ListDisplaySettingsStore
    // .unreadOnlyKey`'s doc comment)

    /// iOS では`MailScreenView`の`unreadOnlyToggleButton`が、macOS では
    /// Task #196 で追加した`MacListSearchBar.unreadOnlyToggleButton`
    /// (`macListSearchBar`が`$isUnreadOnly`を直接束ねる) がこのトグルを
    /// 持つ — iOS 側は今も`UserDefaults`キーを直接書く別の`@AppStorage`
    /// 経由 (バインディングではない、iOS版のdoc comment参照)。読む側は
    /// 共通で、ここで`ThreadQuery`呼び出し (`observeThreads()`) と
    /// 空状態の文言 (`emptyStateTitle`) を決める。
    @AppStorage(ListDisplaySettingsStore.unreadOnlyKey) private var isUnreadOnly = ListDisplaySettingsStore.defaultUnreadOnly

    /// Task #82: the value `observeThreads()`/`ObservationKey` actually use
    /// to build the `ThreadQuery` call — see `ListDisplaySettingsStore
    /// .persistedBool(forKey:default:)`'s doc comment for why this reads
    /// straight from `UserDefaults` instead of trusting `isUnreadOnly`
    /// (the `@AppStorage` property above) directly. `isUnreadOnly` itself
    /// stays declared and is still read directly in `emptyStateTitle` below
    /// — that's what keeps SwiftUI's change-tracking subscribed to this key
    /// so a toggle flips this computed property's result too.
    // Widened from `private` to internal: read from
    // `MessageListView+Sync.swift`, a different file.
    var persistedUnreadOnly: Bool {
        ListDisplaySettingsStore.persistedBool(forKey: ListDisplaySettingsStore.unreadOnlyKey, default: ListDisplaySettingsStore.defaultUnreadOnly)
    }

    // MARK: - フラグ付きのみ表示 (Task #142、ヘッダのトグル — 未読のみ表示の隣)

    /// `unreadOnlyKey`/`isUnreadOnly`の対 — `MailScreenView`のヘッダ側トグル
    /// (`pinnedOnlyToggleButton`) が同じ`UserDefaults`キーへ直接書く。
    @AppStorage(ListDisplaySettingsStore.pinnedOnlyKey) private var isPinnedOnly = ListDisplaySettingsStore.defaultPinnedOnly

    /// `persistedUnreadOnly`と同じ理由 (#82/#105) — `observeThreads()`は
    /// このプロパティ経由で`ThreadQuery`を呼ぶ。
    var persistedPinnedOnly: Bool {
        ListDisplaySettingsStore.persistedBool(forKey: ListDisplaySettingsStore.pinnedOnlyKey, default: ListDisplaySettingsStore.defaultPinnedOnly)
    }

    // MARK: - アカウントでグループ化 (Task #77 → Task #92 → Task #99)
    //
    // Task #77 で導入したインラインの`Section`分割 (`isGroupingActive`/
    // `groupedSummaries`/`AccountGroupSectionHeader`) は Task #92 で廃止した
    // — 「アカウントでグループ化」ボタンは一覧をこの場でセクション分割する
    // 代わりに`AccountDigestView`(アカウントごとの件数+直近プレビューの
    // ダイジェスト画面)へ切り替えるようになった
    // (`MailScreenView.groupByAccountToggleButton`)。#92時点ではプッシュ
    // 遷移だったが、Task #99 で`MailScreenView.content`が`MessageListView`
    // とこの`AccountDigestView`を条件分岐で出し分けるトグル表示に変わった
    // — いずれにせよこの`MessageListView`自体はもうグルーピングの状態を
    // 一切知らない。`ListDisplaySettingsStore.groupByAccountKey`はまだ
    // 存在するが、その意味は「一覧をこの場でグルーピングするか」から
    // 「ダイジェスト表示にするか」の永続トグルへ変わった
    // (`MailScreenView`側の同名プロパティのdoc comment参照)。詳細は
    // `docs/design-system.md`のTask #92節/Task #99追記。

    /// Flat mode is simply "threading turned off" — kept as a derived value
    /// so the rest of this view (and `ObservationKey`) can keep reading in
    /// the affirmative "is this the flat query?" direction.
    ///
    /// Task #82 (実機報告「スレッド表示オフが起動直後に反映されない」):
    /// reads `threadingKey`'s persisted value straight from `UserDefaults`
    /// rather than `!isThreadingEnabled` — see `ListDisplaySettingsStore
    /// .persistedBool(forKey:default:)`'s doc comment for the real-device
    /// bug this fixes. `isThreadingEnabled` is still declared and read
    /// directly via `.onChange(of: isThreadingEnabled)` below, which is
    /// what keeps SwiftUI's change-tracking subscribed to this key so this
    /// computed property (and the `.task(id:)` it feeds) re-evaluates the
    /// moment the setting changes anywhere in the app, e.g. in
    /// `MailListSettingsView`'s own Toggle.
    // Widened from `private` to internal: read from
    // `MessageListView+Sync.swift`/`+RowActions.swift`, different files.
    var isFlatMode: Bool {
        !ListDisplaySettingsStore.persistedBool(forKey: ListDisplaySettingsStore.threadingKey, default: ListDisplaySettingsStore.defaultThreading)
    }

    /// Whitespace-only input (including the empty string right after
    /// `.searchable` clears) is "not searching" — the normal `summaries`
    /// list shows, exactly like before M7.
    var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the `List` actually renders: search results while a query is
    /// active (macOS only — iOS never populates `searchText`, this view no
    /// longer hosts a search field there), the live `ThreadQuery`
    /// observation otherwise. No separate "pending removal" filter needed —
    /// `commitDelete`/`commitArchive` write to the database immediately, so
    /// a deleted/archived thread is already gone from `summaries` via the
    /// live observation by the time this is read (see those methods' doc
    /// comment for why the undo window no longer delays the local write
    /// itself). Rows, `MessageListRow`, and every swipe/bulk action are
    /// shared between the search-results and normal-list cases — marking a
    /// search hit read or deleting it works exactly like it does from the
    /// normal list.
    // Widened from `private` to internal: read from
    // `MessageListView+Selection.swift`, a different file.
    var displayedSummaries: [ThreadSummary] {
        isSearchActive ? searchResults : summaries
    }

    /// "現在のメールボックス" only means something with one specific mailbox
    /// selected; the unified inbox has no single mailbox to narrow to, so
    /// its scope picker only ever offers "すべて".
    private var availableScopes: [SearchScopeOption] {
        switch selection {
        case .mailbox: [.all, .currentMailbox]
        case .unifiedInbox, .unifiedRole: [.all]
        }
    }

    /// 1d: the account-color rail/trailing account label only mean
    /// something where a row could plausibly belong to more than one
    /// account — the true "全部" unified inbox. A single mailbox, or the
    /// unified inbox narrowed to one account via 1a's filter chip, already
    /// guarantees every visible row shares one account, so the accent would
    /// be redundant color noise (`docs/design-system.md` records this
    /// refinement over the handoff's plainer "統合受信トレイでは...").
    ///
    /// design-phase-3: also requires more than one account to exist at all.
    /// With exactly one account, "全部"/unified inbox and that account's own
    /// mailbox show the identical set of messages, so a rail/label naming
    /// the only account that could possibly appear is pure noise — and,
    /// worse, it eats into the subject's available width on every single
    /// row for a piece of information that's always the same value. Caught
    /// by actually looking at a single-account screenshot (`docs/design-
    /// system.md`'s design-phase-3 section) rather than in the handoff,
    /// which didn't consider the one-account case explicitly.
    ///
    /// Task #87 (4): real-device feedback wanted the rail visible *always*,
    /// even for a single mailbox or an account-filtered unified inbox —
    /// the doc comment above (and `isMultiAccountScope` just below) record
    /// the narrower condition this property used to return, kept alive
    /// only for `isMultiAccountScope` (the trailing account-name label
    /// still shouldn't show where every visible row already shares one
    /// account — that would just be a redundant repeated label). The
    /// header's own account-digest eligibility (`MailScreenView
    /// .isAccountDigestEligible`, gating the "すべて" chip's dropdown as of
    /// Task #106) is unrelated and intentionally untouched by this change.
    private var showsAccountAccent: Bool { true }

    /// The condition `showsAccountAccent` used to gate on before Task #87
    /// (4) made the rail unconditional — still exactly right for deciding
    /// whether `threadRow(for:)`'s trailing account-name label should show
    /// at all (only where more than one account's rows could actually
    /// appear together in `displayedSummaries`).
    private var isMultiAccountScope: Bool {
        switch selection {
        case .unifiedInbox:
            guard unifiedInboxAccountFilter == nil else { return false }
        case .unifiedRole:
            // 画面構造改修バッチ (Task #33, 3) 時点では「横断ビュー」に
            // アカウント絞り込みチップが無く、`unifiedInboxAccountFilter`は
            // 常に無視されていた。Task #92 (アカウントダイジェスト画面):
            // ダイジェスト行タップ→絞り込み一覧という新しい遷移が
            // `.unifiedRole`にも`unifiedInboxAccountFilter`を実際に適用する
            // ようになった (`observeThreads()`) ため、ここも`.unifiedInbox`
            // と同じ条件に揃える — 1アカウントに絞られた横断ビューでも、
            // もう全行が同じアカウントなのでラベルは冗長になる。
            guard unifiedInboxAccountFilter == nil else { return false }
        case .mailbox:
            return false
        }
        return environment.accounts.count > 1
    }

    /// Task #87 (1): decides `isArchiveView` for whatever `selection`
    /// currently is. `.unifiedRole(.archive)` (the カテゴリ優先メニューの
    /// 「アーカイブ」行, i.e. "すべてのアーカイブ") is archive unconditionally
    /// — no DB read needed. `.mailbox` needs an actual read: a specific
    /// mailbox counts as "archive" if its own role is `.archive`, or —
    /// Gmail has no `\Archive`-flagged folder at all — if it's that
    /// account's All Mail (`role == .all`), which `MailboxRecord
    /// .request(mailboxId:...)`'s own `GmailArchiveFilter` already always
    /// narrows down to exactly the "archived" subset regardless of which
    /// entry point opened it (that filter's own doc comment covers why
    /// there's no separate "raw All Mail, unfiltered" view to distinguish
    /// from). `.unifiedInbox` is never "archive" — 1a's account-filter
    /// chips only ever narrow *which accounts'* INBOX-role mail shows, not
    /// which role.
    private func refreshArchiveViewFlag() async {
        switch selection {
        case .unifiedRole(let role):
            isArchiveView = (role == .archive)
        case .unifiedInbox:
            isArchiveView = false
        case .mailbox(let mailboxSelection):
            guard let account = environment.accounts.first(where: { $0.id == mailboxSelection.accountId }) else {
                isArchiveView = false
                return
            }
            do {
                let role = try await environment.database.dbWriter.read { db in
                    try MailboxRecord.fetchOne(db, key: mailboxSelection.mailboxId)?.role
                }
                isArchiveView = role == .archive || (role == .all && account.kind == .gmail)
            } catch {
                isArchiveView = false
            }
        }
    }

    /// 「迷惑メール解除」: `refreshArchiveViewFlag()`'s junk counterpart —
    /// `.unifiedRole(.junk)` (カテゴリ「迷惑メール」, i.e. "すべての迷惑メール")
    /// is junk unconditionally, a `.mailbox` counts as junk when its own
    /// role is `.junk` (no Gmail special case — Spam is a real folder there,
    /// unlike アーカイブ), and `.unifiedInbox` never is.
    private func refreshJunkViewFlag() async {
        switch selection {
        case .unifiedRole(let role):
            isJunkView = (role == .junk)
        case .unifiedInbox:
            isJunkView = false
        case .mailbox(let mailboxSelection):
            do {
                let role = try await environment.database.dbWriter.read { db in
                    try MailboxRecord.fetchOne(db, key: mailboxSelection.mailboxId)?.role
                }
                isJunkView = role == .junk
            } catch {
                isJunkView = false
            }
        }
    }

    /// 「ゴミ箱を空にする」: `refreshArchiveViewFlag()`/`refreshJunkViewFlag()`
    /// のゴミ箱版 — `.unifiedRole(.trash)` (「すべてのゴミ箱」) は無条件に
    /// trash、`.mailbox` はその role が `.trash` かどうかを読む、
    /// `.unifiedInbox` は常に false。Gmail 特有の分岐は無い (ゴミ箱は
    /// アーカイブと違って Gmail でも実フォルダ)。
    func refreshTrashViewFlag() async {
        switch selection {
        case .unifiedRole(let role):
            isTrashView = (role == .trash)
        case .unifiedInbox:
            isTrashView = false
        case .mailbox(let mailboxSelection):
            do {
                let role = try await environment.database.dbWriter.read { db in
                    try MailboxRecord.fetchOne(db, key: mailboxSelection.mailboxId)?.role
                }
                isTrashView = role == .trash
            } catch {
                isTrashView = false
            }
        }
    }

    private var accountDisplayNames: [String: String] {
        Dictionary(uniqueKeysWithValues: environment.accounts.map { ($0.id, $0.displayName) })
    }

    /// D「アカウントのラベル色を変更可能に」— only non-`nil` `labelColorKey`s are
    /// included; `ThreadRowView`/`AccountColorRail`/`SenderAvatar` already
    /// treat a missing dictionary entry the same as an explicit `nil`
    /// (auto-assignment).
    private var accountLabelColorKeys: [String: String] {
        Dictionary(uniqueKeysWithValues: environment.accounts.compactMap { account in
            account.labelColorKey.map { (account.id, $0) }
        })
    }

    // MARK: - Empty state (実機バグ調査: 「アーカイブ運用で INBOX が本当に空」を
    // 「同期が失敗している」と誤読させないための分岐, docs/verify.md)

    /// `AccountRecord.lastSyncError` for whichever account(s) this view's
    /// `selection` could plausibly be empty *because of* a failed sync —
    /// `nil` means "as far as we know, the relevant account(s) last synced
    /// cleanly", which is also true before the first sync ever runs (that's
    /// fine: the empty state then falls back to the same "同期中…" as any
    /// other pre-sync moment via `isSyncing`, not a spurious error message).
    /// `.unifiedInbox` with no `unifiedInboxAccountFilter` (1a's "全部" chip)
    /// has no single account to check, so it reports an error if *any*
    /// account last failed — an empty unified inbox while even one account
    /// is in a known-bad state is exactly the ambiguous case this exists to
    /// resolve in favor of "re-sync", not silently "no mail".
    private var currentAccountLastSyncError: String? {
        switch selection {
        case .mailbox(let mailboxSelection):
            return environment.accounts.first { $0.id == mailboxSelection.accountId }?.lastSyncError
        case .unifiedInbox:
            let accountId = unifiedInboxAccountFilter
            if let accountId {
                return environment.accounts.first { $0.id == accountId }?.lastSyncError
            }
            return environment.accounts.compactMap(\.lastSyncError).first
        case .unifiedRole:
            // 画面構造改修バッチ (Task #33, 3): 「横断ビュー」にはアカウント
            // 絞り込みチップが無い (`showsAccountAccent`のdoc comment) ので、
            // `.unifiedInbox`のno-filter分岐と同じく「いずれかのアカウントが
            // 失敗していれば報告」でよい。
            return environment.accounts.compactMap(\.lastSyncError).first
        }
    }

    /// "メッセージがありません" (something might be missing — check again) only
    /// once there's a reason to doubt the sync, i.e. mid-sync or after a
    /// recorded failure; a *known-clean* empty mailbox (the common case for
    /// an inbox-zero workflow — this is the exact real-device report that
    /// prompted this split, see docs/verify.md) instead says "メールはあり
    /// ません", which doesn't imply anything went wrong. 未読のみ表示中の
    /// "known-clean" 空状態はさらに専用の文言 ("未読のメールはありません") —
    /// フィルタで絞った結果ゼロ件なのを「メールが1通もない」と誤読させない
    /// ため。Task #142: 「フラグ付きのみ表示」も同じ理由で専用文言を持つ —
    /// この直接読みが`isPinnedOnly`(`@AppStorage`)を購読させる役目も兼ねる
    /// (`persistedPinnedOnly`のdoc comment/`isThreadingEnabled`のObservationKey
    /// フィールドと同じ「どこかで実際に読まないとSwiftUIの変更検知が効かない」
    /// 事情、`ObservationKey`のdoc comment参照)。
    private var emptyStateTitle: LocalizedStringKey {
        if isSyncing || currentAccountLastSyncError != nil { return "メッセージがありません" }
        if isUnreadOnly && isPinnedOnly { return "未読かつフラグ付きのメールはありません" }
        if isPinnedOnly { return "フラグ付きのメールはありません" }
        return isUnreadOnly ? "未読のメールはありません" : "メールはありません"
    }

    /// No description at all for the known-clean empty case — "メールはあり
    /// ません" alone doesn't need a "here's what to do about it" line the
    /// way the syncing/error cases do.
    private var emptyStateDescription: Text? {
        if isSyncing { return Text("同期中…") }
        if currentAccountLastSyncError != nil { return Text("再同期を試してください。") }
        return nil
    }

    var body: some View {
        // Task #197 (実機フィードバック「更新ボタンと検索欄をメールビュー
        // 側から一覧側へ移して欲しい」): macOS だけ、この一覧自身の上に
        // 検索欄+更新ボタンの行 (`macListSearchBar`) を重ねる薄い`VStack`で
        // 包む。以前は同じ`refresh()`/`searchText`が`messageListCore`の
        // `.searchable`/`.toolbar`(システムのウィンドウ共通ツールバー) に
        // 乗っていて、コード上はこの一覧の`.toolbar`だったにもかかわらず、
        // 3ペインの`NavigationSplitView`ではその共通ツールバーの検索欄が
        // ウィンドウ右端 (＝実質メールビュー側の真上) に描画され、
        // 「メールビューに検索欄がある」ように見えてしまっていた
        // (実機スクリーンショットで確認、詳細は`docs/design-system.md`の
        // Task #197 節)。`VStack`で一覧のすぐ上に直接描画すれば、
        // どのペイン幅でも必ず一覧の真上に来ることが保証できる。
        // iOS は無変更 (`messageListCore`をそのまま返す) — iOS はそもそも
        // この`List`に`.searchable`を付けていない (検索は`SearchScreenView`
        // という別画面、`messageListCore`の doc comment参照)。
        #if os(macOS)
        VStack(spacing: 0) {
            macListSearchBar
            messageListCore
        }
        // `messageListCore` 側のチェーンに足すと型チェックタイムアウトで
        // CI が落ちる (docs/ci.md) ため、短いこちらの式に付ける。
        .focusedSceneValue(\.refreshMessageListAction, refreshActionForMenu)
        #else
        messageListCore
        #endif
    }

    #if os(macOS)
    /// `MacListSearchBar`型自体へ検索/更新まわりの状態を橋渡しするだけの
    /// 薄いラッパー — `body`の`VStack`を単純な式に保つため、初期化子呼び
    /// 出し自体をここへ追い出した。
    private var macListSearchBar: some View {
        MacListSearchBar(
            searchText: $searchText,
            searchScope: $searchScope,
            availableScopes: availableScopes,
            isFieldFocused: $isSearchFieldFocused,
            isUnreadOnly: $isUnreadOnly,
            isSyncing: isSyncing,
            onRefresh: startManualRefresh,
            isTrashView: isTrashView && !summaries.isEmpty,
            onEmptyTrash: requestEmptyTrash
        )
    }

    /// 更新ボタン (`MacListSearchBar.onRefresh`) と ⌘R
    /// (`refreshMessageListAction`) の共通ハンドラ。
    private func startManualRefresh() {
        Task { await refresh() }
    }

    /// 同期中は nil で unpublish → メニュー項目が自動 disabled
    /// (`MacListSearchBar.refreshButton` の `.disabled(isSyncing)` と同挙動)。
    private var refreshActionForMenu: (() -> Void)? {
        if isSyncing { return nil }
        return { startManualRefresh() }
    }
    #endif

    /// `body`本体 — 以前はこれが`body`そのものだった (`.searchable`/
    /// `refreshToolbarItem`を含む) が、Task #197 でmacOS専用の検索欄+
    /// 更新ボタン行 (`macListSearchBar`) を`body`側の`VStack`に外出しした
    /// ため、この一覧単体をここへ切り出した。
    private var messageListCore: some View {
        selectableList
        // Task #87 (2): iOS 26's default `List` style renders the whole
        // scrollable content region as one implicit rounded "card" (visible
        // as a rounded top-left/top-right corner on the very first row and
        // a rounded bottom-left/bottom-right corner on the very last one,
        // confirmed via `scripts/verify-screen.sh list-2accounts` in dark
        // mode — the rounding is most visible against `AccountColorRail`'s
        // hard-edged color bar sitting right at that corner) — independent
        // of `ThreadRowView.rowCornerRadius`'s own `OtegamiRadius.none`,
        // which only ever governed each row's *own* background shape, never
        // this outer system-level masking. Task #67 never caught this: its
        // own verification fixture had exactly one account, and
        // `AccountColorRail` is hidden entirely for a single account
        // (`MessageListView.showsAccountAccent`), so the rounded corner had
        // nothing high-contrast sitting against it to make it visible.
        // `.listStyle(.plain)` (iOS only — macOS stays exactly as it was,
        // per `CLAUDE.md`'s "macOS は現状の `NavigationSplitView` 3ペインを
        // 維持する") opts back into the flat, edge-to-edge list rendering
        // this design has relied on since 実機フィードバック第2弾, across
        // every entry point this same `List` serves (single mailbox/
        // unifiedInbox/unifiedRole/macOS's inline search).
        #if os(iOS)
        .listStyle(.plain)
        #endif
        .accessibilityIdentifier("messageList.list")
        // Liquid Glass Phase 1 (2026-08-07、docs/design-system.md「Liquid
        // Glass 方針」): iOS 独自の`.scrollContentBackground(.hidden)` +
        // `OtegamiColor.background`塗りをやめ、macOS (`SidebarView
        // .sidebarList`と同じ判断) と同様に標準のリスト背景へ委譲した —
        // 以前ここにあった「2026-08-07 (メイン UI の macOS ネイティブ化):
        // 独自の背景塗りは iOS のみ」というコメントは、まさにその日のうち
        // にこの Liquid Glass 移行で iOS 側にも波及した。
        // design-phase-3: a `List` with no explicit `Section`s still gets
        // treated as one implicit section, and iOS 17+'s default
        // inter-section spacing (`ListSectionSpacing.default`, a fixed
        // ~20-30pt-plus gap meant to separate *visually distinct* grouped
        // sections) applies above it regardless — with nothing else above
        // the list on macOS/most iOS screens this is invisible (it just
        // reads as ordinary top padding), but on iOS's 1a mail tab, where
        // `AccountFilterChipRow` sits directly above this `List` in the
        // same `VStack`, it showed up as a conspicuous unstyled empty band
        // between the chips and the first row (caught by actually looking
        // at a screenshot, not by reading the modifier list — see
        // `docs/design-system.md`'s design-phase-3 section). `.compact`
        // collapses it to the same tight spacing this app's own row
        // dividers already use. iOS-only: `.listSectionSpacing` isn't
        // available on macOS in this SDK at all (this app's
        // `NavigationSplitView` 3-pane layout has nothing above this list
        // in the same `VStack` in the first place — `CLAUDE.md`'s "macOS
        // は現状の `NavigationSplitView` 3ペインを維持する" — so there was
        // never a gap to fix there).
        #if os(iOS)
        .listSectionSpacing(.compact)
        // 左下フローティングの検索ボタン (`MailScreenView.floatingSearchButton`)
        // が最下段の行と重ならないよう、スクロール内容の下端に余白を足す —
        // `FolderListSheet`の`floatingSettingsButton`と同じパターン。
        .contentMargins(.bottom, OtegamiSpacing.xxl + OtegamiSpacing.lg, for: .scrollContent)
        #endif
        .overlay {
            if isSearchActive {
                if isSearching {
                    ProgressView("検索中…")
                        .accessibilityIdentifier("messageList.search.loading")
                } else if searchResults.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .accessibilityIdentifier("messageList.search.emptyState")
                }
            } else if summaries.isEmpty {
                ContentUnavailableView(
                    emptyStateTitle,
                    systemImage: "envelope",
                    description: emptyStateDescription
                )
                .accessibilityIdentifier("messageList.emptyState")
            }
        }
        #if os(macOS)
        // Task #197 より前はここに`.searchable`/`.searchFocused`/
        // `.searchScopes`が付いていた — システムのウィンドウ共通ツール
        // バーに検索欄を差し込む方式で、`accessibilityIdentifier`の
        // 上書き注意点などここに長いコメントが付いていたが、Task #197 で
        // `body`の`VStack`側に自前の`macListSearchBar`(`MacListSearchBar`
        // 型) を置く方式へ切り替えたため丸ごと不要になった (検索欄自体は
        // 独立した`View`なので"messageList.list"の識別子を上書きする心配も
        // 無い)。`⌘F`(`OtegamiCommands`) でのフォーカスは`isSearchFieldFocused`
        // への`.focusedSceneValue`をそのまま残し、`MacListSearchBar`側の
        // `TextField`に`.focused($isFieldFocused)`で束ねることで維持して
        // いる。
        .navigationTitle(title)
        .focusedSceneValue(\.focusSearchAction, { isSearchFieldFocused = true })
        // ユーザー要望 (2026-08-08): カーソル/クリックでの選択とその後始末。
        // `selectableList` の doc comment 参照。
        .focusedSceneValue(\.selectAllThreadsAction, selectAllThreadsActionForMenu)
        .onChange(of: selectedThreadIds) { _, _ in syncDetailWithSelection() }
        .onChange(of: searchText) { _, _ in scheduleSearch() }
        .onChange(of: searchScope) { _, _ in scheduleSearch() }
        // 実機バグ報告「スレッド表示をオフ/オンにした直後、検索結果だけ
        // 古いグルーピングのまま残る」対策 — `performSearch`は`isFlatMode`
        // を見るが、`scheduleSearch()`自体は`searchText`/`searchScope`の
        // 変化でしか再実行されないため、検索中に設定だけ切り替えても
        // 次のキー入力までは古い結果が残っていた。
        .onChange(of: isThreadingEnabled) { _, _ in scheduleSearch() }
        #endif
        .onChange(of: summaries) { _, newValue in
            onSummariesChanged(newValue.compactMap(\.thread.id))
        }
        .onChange(of: selection) { _, _ in
            if !availableScopes.contains(searchScope) { searchScope = .all }
            // M10 pagination: a fresh mailbox/unified-inbox selection
            // starts back at the first page — otherwise switching from a
            // mailbox someone had scrolled deep into to a brand-new one
            // would request (and wait on) that same deep page size again.
            pageLimit = Self.pageStep
            exitSelectionMode()
        }
        .toolbar {
            listToolbarContent
        }
        #if os(iOS)
        .refreshable { await refresh() }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
        #endif
        // Task #194: shown for the whole duration of a pull-to-refresh/
        // toolbar-button sync, on both platforms — not just while iOS's own
        // `.refreshable` spinner is visible (that one stops as soon as the
        // finger lifts, well before a slow sync actually finishes), and
        // macOS's toolbar refresh button has no pull gesture/spinner of its
        // own at all. See `SyncProgressBanner`'s doc comment.
        .safeAreaInset(edge: .top) {
            if isSyncing {
                SyncProgressBanner(update: syncProgress) {
                    activeSyncTask?.cancel()
                }
            }
        }
        .overlay(alignment: .bottom) {
            // Task #108: `suppressInternalUndoToast`(`MailScreenView`が
            // 渡す)のときはここで描画せず、`onPendingUndoChanged`経由で
            // 親に委ねる — そのプロパティのdoc comment参照。macOS
            // (`RootView`)はこのパラメータを渡さないので、これまでどおり
            // ここで描画する。
            if !suppressInternalUndoToast, let pendingUndo {
                UndoToast(message: pendingUndo.message, onUndo: undoButtonAction(for: pendingUndo))
                    .animation(.default, value: pendingUndo.threadIds)
                    #if os(iOS)
                    .padding(.bottom, OtegamiSpacing.xxl + OtegamiSpacing.lg)
                    #endif
            }
        }
        .task(id: ObservationKey(selection: selection, accountFilter: unifiedInboxAccountFilter, accountIds: environment.accounts.map(\.id), pageLimit: pageLimit, isFlatMode: isFlatMode, isThreadingEnabled: isThreadingEnabled, unreadOnly: persistedUnreadOnly, pinnedOnly: persistedPinnedOnly)) {
            await observeThreads()
        }
        // `onUnreadCountChanged`'s doc comment — independent of the
        // observation right above (own key, own task).
        .task(id: UnreadCountObservationKey(selection: selection, accountFilter: unifiedInboxAccountFilter, accountIds: environment.accounts.map(\.id))) {
            await observeUnreadCountInScope()
        }
        // Task #44: see `syncSelectedMailboxOnAppear()`'s doc comment —
        // keyed on `selection` alone (not the `ObservationKey` above, which
        // also changes for `unreadOnly`/`isFlatMode`/pagination and would
        // otherwise re-trigger a network sync for purely local display
        // settings).
        .task(id: selection) {
            await syncSelectedMailboxOnAppear()
        }
        // Task #87 (1): also keyed on `selection` alone, same reasoning as
        // the task right above — an archive-or-not read has nothing to do
        // with `unreadOnly`/`isFlatMode`/pagination either.
        .task(id: selection) {
            await refreshArchiveViewFlag()
        }
        // 「迷惑メール解除」: same shape/keying as the archive flag right
        // above — see `refreshJunkViewFlag()`'s doc comment.
        .task(id: selection) {
            await refreshJunkViewFlag()
        }
        // 「ゴミ箱を空にする」: 同じ形/keying。
        .task(id: selection) {
            await refreshTrashViewFlag()
        }
        // Not required for correctness anymore (the local write already
        // happened by the time a `PendingUndo` exists — see `commitDelete`/
        // `commitArchive`'s doc comment), but backgrounding is also the
        // natural point to give up on "undo" and let the already-queued
        // opQueue rows replay right away instead of waiting out the rest of
        // the window for no one to see.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active, let pendingUndo else { return }
            pendingUndoTask?.cancel()
            self.pendingUndo = nil
            notifyPendingUndoChanged()
            Task { await replayOpQueueSoon(accountIds: pendingUndo.accountIds) }
        }
        .alert(
            "同期エラー",
            isPresented: Binding(
                get: { syncErrorMessage != nil },
                set: { if !$0 { syncErrorMessage = nil } }
            )
        ) {
            Button("閉じる") { syncErrorMessage = nil }
        } message: {
            Text(syncErrorMessage ?? "")
        }
        // 「ゴミ箱を空にする」破壊的操作の確認 — `.confirmationDialog`ではなく
        // `.alert`にしているのは、Task #190 が確立した既存の方針 (iPad/macOS
        // では`.confirmationDialog`がソースに紐づく吹き出しになってしまう
        // ため常に画面中央のモーダルが要る破壊的確認は`.alert`、
        // `AccountDigestView`のdoc comment参照) に合わせたもの。
        // Binding/ボタン/メッセージをインラインで書かず
        // `MessageListView+EmptyTrash.swift`の名前付きプロパティに分けて
        // いるのは CI の型チェックタイムアウト対策 (`docs/ci.md`) — 初版は
        // インライン`Binding(get:set:)`クロージャがこの巨大な modifier
        // チェーンに折り畳まれ、ローカルでは通るのに CI ランナーで
        // 「unable to type-check this expression in reasonable time」で
        // 落ちた (ci-app run 31947831733)。
        .alert(
            "ゴミ箱を空にしますか？",
            isPresented: isEmptyTrashAlertPresented,
            actions: emptyTrashAlertActions,
            message: emptyTrashAlertMessage
        )
    }

    /// The toolbar's whole content, split out of `body` — split for the same
    /// "keep each modifier-chain expression small" reason `docs/ci.md`
    /// documents everywhere else in this app, but also because it now
    /// branches on `isSelecting` (1h's swapped-out nav bar: キャンセル /
    /// "N件を選択中" / 全選択) in addition to the platform split the rest of
    /// `body` already has.
    @ToolbarContentBuilder
    private var listToolbarContent: some ToolbarContent {
        #if os(iOS)
        // 一覧ヘッダの再読込ボタンは iOS では廃止 — pull-to-refresh
        // (`.refreshable`、下の `#if os(iOS)` ブロック) がその役目を持つ。
        if isSelecting {
            ToolbarItem(placement: .cancellationAction) {
                Button("キャンセル") { exitSelectionMode() }
                    .accessibilityIdentifier("messageList.selection.cancelButton")
            }
            ToolbarItem(placement: .principal) {
                Text("\(selectedThreadIds.count)件を選択中")
                    .font(OtegamiFont.headline())
                    .accessibilityIdentifier("messageList.selection.countLabel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isAllVisibleSelected ? "選択解除" : "全選択") { toggleSelectAll() }
                    .accessibilityIdentifier("messageList.selection.selectAllButton")
            }
        } else if isTrashView && !isSearchActive && !summaries.isEmpty {
            // 「ゴミ箱を空にする」— ゴミ箱ビューを見ている間だけ出す。
            // 一括選択中/検索中/空のゴミ箱では出さない。
            ToolbarItem(placement: .topBarTrailing) {
                Button("空にする", role: .destructive) { requestEmptyTrash() }
                    .accessibilityIdentifier("messageList.emptyTrashButton")
            }
        }
        #else
        // Task #197: macOS の更新ボタンはウィンドウ共通ツールバーの
        // `ToolbarItem`から`macListSearchBar`内の`MacListSearchBar`の
        // 自前ボタンへ移した (`body`のdoc comment参照) — この分岐に
        // 出す項目はもう無い。
        ToolbarItemGroup {}
        #endif
    }

    #if os(iOS)
    /// 1h's bottom action bar while `isSelecting`: 既読に・移動（アーカイブ）・
    /// 削除 — "まとめて翻訳" isn't rendered for the same reason
    /// `MessageListRow.trailingSwipeActions`'s doc comment gives for the
    /// swipe row's 翻訳/後で slots (no backing feature yet in this UI-
    /// restructuring pass). "移動" is simplified to "選択したスレッドをそれぞれの
    /// アカウントのアーカイブへ移動" rather than a full arbitrary-folder picker
    /// — see `docs/design-system.md`'s deviations section for why a full
    /// folder picker was judged out of this task's scope.
    private var selectionBottomBar: some View {
        HStack(spacing: OtegamiSpacing.xl) {
            selectionBarButton(title: "既読に", systemImage: "envelope.open", identifier: "markReadButton", action: markSelectedAsRead)
            selectionBarButton(title: "移動", systemImage: "archivebox", identifier: "archiveButton", action: archiveSelected)
            Spacer()
            selectionBarButton(title: "削除", systemImage: "trash", identifier: "deleteButton", action: deleteSelected, tint: OtegamiColor.destructive)
        }
        .padding(.horizontal, OtegamiSpacing.lg)
        .padding(.vertical, OtegamiSpacing.sm)
        .background(OtegamiColor.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(OtegamiColor.divider).frame(height: OtegamiStroke.secondary)
        }
        .disabled(selectedThreadIds.isEmpty)
    }

    // 表示・操作改善バッチ「表示言語の設定」: `title: String`のままだと
    // `Text(title)`がverbatim (非ローカライズ) 呼び出しになる —
    // `LocalizedStringKey`に変えるだけで、呼び出し側の文字列リテラルは
    // そのまま`Localizable.xcstrings`のキーとして解決されるようになる。
    private func selectionBarButton(title: LocalizedStringKey, systemImage: String, identifier: String, action: @escaping () -> Void, tint: Color = OtegamiColor.accent) -> some View {
        Button(action: action) {
            VStack(spacing: OtegamiSpacing.xs) {
                Image(systemName: systemImage)
                Text(title).font(OtegamiFont.caption())
            }
            .foregroundStyle(tint)
        }
        .otegamiMinimumTappable()
        .accessibilityIdentifier("messageList.selection.\(identifier)")
    }
    #endif

    /// Builds one row for the `ForEach` in `body` — pulled into its own
    /// `@ViewBuilder` method, with the row's interactive content
    /// (`Button`/swipe actions/context menu/long-press) in the standalone
    /// `MessageListRow` type, for the same reason `SidebarView`'s
    /// `mailboxRow(for:in:)`/`MailboxRow` split exists (see that pair's doc
    /// comments and docs/ci.md's troubleshooting notes): an `if let`
    /// binding plus a multi-argument view initializer plus several chained
    /// trailing-closure modifiers, all inline inside one `ForEach` row
    /// closure, is exactly the shape that hit `error: the compiler is
    /// unable to type-check this expression in reasonable time` on CI's
    /// toolchain for `SidebarView` — and this row (now with two
    /// `.swipeActions` groups, a long-press gesture, and a conditional
    /// context menu on top of what was already flagged as risky) is larger
    /// still.
    /// `body`の`List`本体 — Task #77 ではここで`isGroupingActive`を見て
    /// アカウントごとの`Section`分割/フラットな`ForEach`を出し分けていたが、
    /// Task #92 (アカウントダイジェスト画面) がそのインライン分割を廃止した
    /// ため、常にフラットな`ForEach`一本になった。`@ViewBuilder`のまま
    /// (中身を1行のプロパティに畳まない) で残しているのは、`docs/ci.md`の
    /// 「`List`の中身は独立した式に切り出す」方針そのもの — この`List`には
    /// 既に長いモディファイアチェーンが積んであり、それと合わさって
    /// CI型チェックタイムアウトの典型的な引き金になりうるため。
    /// ユーザー要望 (2026-08-08「mac版において、カーソルでのメール選択が
    /// できるようにして欲しい。また、マウスなどで複数選択して、右クリックで
    /// アーカイブや既読化、ピン留めできるようにして」): macOS だけ `List` に
    /// `selection:` を与える。矢印キーでの移動・⇧/⌘クリックでの複数選択・
    /// 選択のハイライトはこれだけで SwiftUI (AppKit の `NSTableView`) 側が
    /// 面倒を見るので、このアプリが自前で持つのは「選択が1件になったら
    /// その1件を詳細ペインに出す」(`syncDetailWithSelection`) と、選択集合
    /// に対するコンテキストメニュー (`MessageListSelectionMenu`) だけ。
    ///
    /// iOS は無変更 — あちらの複数選択は長押しで入る独自の選択モード
    /// (`isSelecting`、1h) で、`List(selection:)` の編集モードとは別物。
    ///
    /// `docs/ci.md` の型チェックタイムアウト対策で `List` 自体をここへ
    /// 切り出してある (`messageListCore` の長いモディファイアチェーンに
    /// `#if` 分岐付きの `List` 生成式を直接埋めない)。
    @ViewBuilder
    private var selectableList: some View {
        #if os(macOS)
        List(selection: $selectedThreadIds) {
            listContent
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            selectionContextMenu(for: ids)
        }
        #else
        List {
            listContent
        }
        #endif
    }

    @ViewBuilder
    private var listContent: some View {
        ForEach(displayedSummaries) { summary in
            threadRow(for: summary)
        }
    }

    #if os(macOS)
    /// `.contextMenu(forSelectionType:)` の中身 — 中身自体は独立した
    /// `View` (`MessageListSelectionMenu`) に持たせ、ここはコールバックを
    /// 束ねるだけにしてある (`docs/ci.md`)。各操作は
    /// `runBulkAction(on:_:)` を通す — 既存の一括操作はどれも
    /// `selectedThreadIds` を読むため (そちらの doc comment 参照)。
    @ViewBuilder
    private func selectionContextMenu(for ids: Set<Int64>) -> some View {
        MessageListSelectionMenu(
            targets: summaries(for: ids),
            isArchiveView: isArchiveView,
            isJunkView: isJunkView,
            onReply: onReply,
            onReplyAll: onReplyAll,
            onForward: onForward,
            onMarkRead: { runBulkAction(on: ids, markSelectedAsRead) },
            onMarkUnread: { runBulkAction(on: ids, markSelectedAsUnread) },
            onArchive: { runBulkAction(on: ids, archiveSelected) },
            onUnarchive: { runBulkAction(on: ids, unarchiveSelected) },
            onPin: { pinning in runBulkAction(on: ids) { applyPinToSelected(pinning: pinning) } },
            onJunk: { runBulkAction(on: ids, junkSelected) },
            onUnjunk: { runBulkAction(on: ids, unjunkSelected) },
            onDelete: { runBulkAction(on: ids, deleteSelected) }
        )
    }

    /// `List(selection:)` の選択が1件に定まったら、その1件を詳細ペインへ
    /// 出す (Apple Mail.app と同じ「1クリックで本文が出る」挙動) —
    /// 複数選択中は詳細を切り替えない (どれを出すべきか決まらないため、
    /// 直前に開いていたスレッドをそのまま残す)。
    private func syncDetailWithSelection() {
        guard selectedThreadIds.count == 1, let threadId = selectedThreadIds.first else { return }
        guard let summary = displayedSummaries.first(where: { $0.thread.id == threadId }) else { return }
        handleThreadSelected(summary)
    }

    /// ⌘A (`OtegamiCommands`「すべてのメールを選択」) — 表示中の全行を
    /// 選択する。行が1つも無いときは publish 自体をやめてメニュー項目を
    /// 自動 disabled にする (`selectAllThreadsActionForMenu`)。
    private func selectAllThreads() {
        selectedThreadIds = Set(displayedSummaries.compactMap(\.thread.id))
    }

    private var selectAllThreadsActionForMenu: (() -> Void)? {
        displayedSummaries.isEmpty ? nil : { selectAllThreads() }
    }
    #endif

    @ViewBuilder
    private func threadRow(for summary: ThreadSummary) -> some View {
        if let threadId = summary.thread.id {
            MessageListRow(
                summary: summary,
                threadId: threadId,
                // Task #87 (4): `showsAccountAccent` itself now always
                // shows the rail, but the trailing account-name label
                // (`ThreadRowTrailing`) still only makes sense where more
                // than one account's rows could actually appear —
                // `isMultiAccountScope` is the old `showsAccountAccent`
                // condition, kept for exactly this.
                accountDisplayName: isMultiAccountScope ? accountDisplayNames[summary.thread.accountId] : nil,
                accountLabelColorKey: accountLabelColorKeys[summary.thread.accountId],
                showsAccountAccent: showsAccountAccent,
                isArchiveView: isArchiveView,
                isJunkView: isJunkView,
                isSelecting: isSelecting,
                isSelected: selectedThreadIds.contains(threadId),
                onSelect: handleThreadSelected,
                onToggleSelection: toggleSelection,
                onEnterSelection: enterSelectionMode,
                onToggleRead: toggleRead,
                onArchive: archiveThread,
                onArchiveBlocked: { _ in showArchiveBlockedByPinNotice() },
                onUnarchive: unarchiveThread,
                onDelete: deleteThread,
                onJunk: junkThread,
                onUnjunk: unjunkThread,
                onPin: togglePin,
                onAppear: loadMoreIfNeeded,
                onReply: onReply,
                onReplyAll: onReplyAll,
                onForward: onForward
            )
            // macOS の `List(selection:)` が行を識別するためのタグ
            // (`selectableList`)。iOS では `List` に `selection:` を渡して
            // いないので効果を持たない。
            .tag(threadId)
        }
    }

    /// `MessageListRow.onSelect`'s target — writes `selectedThreadId`/
    /// `selectedMessageId` and forwards to `onThreadSelected`, the same
    /// steps the inline `Button` action this replaced used to do directly
    /// (see this type's own doc comment on why a re-tap of the same row
    /// needs both). 実機フィードバック第3弾 (A): now takes the whole
    /// `ThreadSummary` (not just its thread id) so it can also forward
    /// `summary.singleMessageId` — a flat-mode row's own message id, `nil`
    /// for a grouped-mode row.
    private func handleThreadSelected(_ summary: ThreadSummary) {
        guard let threadId = summary.thread.id else { return }
        // Task #105 続報: cold launch 直後の初回タップだけ `ThreadEntryView`
        // に `preselectedMessageId=nil` が渡る実機ログが取れた (一覧クエリは
        // フラットで正しい)。切り分けのため「タップした行が持っていた値」を
        // ここで記録する (notice — log collect アーカイブに残るレベル)。
        // また、`selectedThreadId` を先に書くと push の destination 評価が
        // `selectedMessageId` の書き込みより先に走る可能性を排除するため、
        // messageId を先に書いてから threadId を書く順序に変更。
        Self.observeThreadsLogger.notice(
            "handleThreadSelected: threadId=\(threadId, privacy: .public) singleMessageId=\(summary.singleMessageId.map(String.init) ?? "nil", privacy: .public)"
        )
        selectedMessageId = summary.singleMessageId
        selectedThreadId = threadId
        onThreadSelected(threadId, summary.singleMessageId)
    }

    // Bulk selection (enterSelectionMode/exitSelectionMode/toggleSelection/
    // isAllVisibleSelected/toggleSelectAll/selectedTargets/
    // markSelectedAsRead/archiveSelected/deleteSelected) lives in
    // MessageListView+Selection.swift.

    // MARK: - Undo (1g/1h)
    //
    // `PendingUndo`, `scheduleUndo`, `notifyPendingUndoChanged`,
    // `undoPending`, `undoButtonAction`, and `showArchiveBlockedByPinNotice`
    // live in `MessageListView+Undo.swift`.

    private var title: String {
        switch selection {
        case .unifiedInbox:
            // 表示・操作改善バッチ「表示言語の設定」: `Text(title)`は
            // `Text(String)`(verbatim)なので、リテラルを直接書くだけでは
            // ローカライズされない — `String(localized:)`で明示的に
            // `Localizable.xcstrings`を引く。
            String(localized: "すべての受信トレイ")
        case .mailbox(let mailboxSelection):
            environment.accounts.first { $0.id == mailboxSelection.accountId }.map { $0.displayName } ?? String(localized: "受信トレイ")
        case .unifiedRole(let role):
            // 画面構造改修バッチ (Task #33, 3): カテゴリ優先メニューの「横断
            // ビュー」— macOS の`RootView`(`.navigationTitle`をこの`title`
            // から読む)が対象。iOS は`MailScreenView`自身が独立した
            // `selectionTitle`を持つため、この`title`は使わない
            // (`MailScreenView.selectUnifiedRole(_:)`が同じ文言を組み立てる)。
            //
            // 実機フィードバック (Task #141): `role == .all`の
            // `categoryDisplayName`自体がすでに「すべてのメール」(=
            // 「すべての」を含む語) なので、他roleと同じ「すべての◯◯」
            // テンプレートに通すと「すべてのすべてのメール」に二重化する
            // (英語ローカライズでも "All All Mail" になる) — `.all`だけは
            // テンプレートを適用せず`categoryDisplayName`をそのまま使う。
            role == .all ? role.categoryDisplayName : String(localized: "すべての\(role.categoryDisplayName)")
        }
    }

    /// Task #82: every branch below reads `isFlatMode`/`persistedUnreadOnly`
    /// (both backed by a fresh `UserDefaults` read, not a cached
    /// `@AppStorage` value) to decide which `ThreadQuery` observation to
    /// start — see `ListDisplaySettingsStore.persistedBool(forKey:default:)`'s
    /// doc comment for why. Task #142 adds `persistedPinnedOnly` alongside
    /// it, same treatment (AND-combined with `unreadOnly` in every
    /// `ThreadQuery` call below, not an either/or). This guarantees every call to this method,
    /// starting with the very first one after launch, reflects whatever is
    /// actually persisted rather than risking a stale in-memory default.
    /// Task #105: one line per `observeThreads()` call stating which query
    /// mode it picked and the raw persisted values behind that pick — see
    /// `ListDisplaySettingsStore.forceReloadFromDiskOnce()`'s doc comment
    /// for the bug this instruments (mirrors `SettingsCloudSyncEngine`'s
    /// own `Logger` from Task #101, added for the same "couldn't reproduce
    /// deterministically off-device" reason).
    // Widened from `private` to internal: also read from
    // `MessageListView+Sync.swift`'s `observeThreads()`, a different file.
    static let observeThreadsLogger = Logger(subsystem: "com.mtkg.otegami", category: "MessageListQueryMode")

    // observeThreads(), observeUnreadCountInScope(), and applySummaries(_:)
    // live in MessageListView+Sync.swift.

    // MARK: - Task #80: list-update-triggered background body prefetch

    /// Debounce before `schedulePrefetch(for:)`'s candidate ids are actually
    /// requested from `SyncCoordinator` — a few seconds, deliberately much
    /// longer than `scheduleSearch()`'s 300ms input-debounce: this is a
    /// background, low-priority fetch the user isn't waiting on, not
    /// something blocking visible search results, so there's no reason to
    /// react as fast. Also acts as a coalescing window for a burst of
    /// `ValueObservation` fires in quick succession (e.g. several read-state
    /// flips landing together).
    // `listUpdatePrefetchDebounce`/`prefetchTask`/`lastPrefetchedMessageIds`
    // below: widened from `private` to internal — read/written from
    // `MessageListView+Sync.swift`'s `schedulePrefetch(for:)`, a different
    // file.
    static let listUpdatePrefetchDebounce: Duration = .seconds(3)

    @State var prefetchTask: Task<Void, Never>?
    /// The candidate id set `schedulePrefetch(for:)` most recently actually
    /// dispatched to `SyncCoordinator` — a repeat call whose leading
    /// not-yet-fetched ids come out identical (e.g. `summaries` re-fired
    /// from an unrelated field changing, per `applySummaries`'s doc comment)
    /// is skipped outright, on top of the time-based debounce above, so
    /// typing in macOS's inline search or an unrelated live update never
    /// re-requests the exact same in-flight/already-attempted set.
    @State var lastPrefetchedMessageIds: Set<Int64> = []

    // schedulePrefetch(for:) and loadMoreIfNeeded(currentItem:) live in
    // MessageListView+Sync.swift.

    // Search (scheduleSearch/performSearch), refresh (refresh/
    // applySyncProgress/performRefreshSync/syncProgressCallback/
    // syncSelectedMailboxOnAppear/selectedMailboxResyncInterval) live in
    // MessageListView+Sync.swift.

    // Row actions (toggleRead/applyReadState/togglePin/applyPinState/
    // junkThread/undoNoun/commitJunk/archiveThread/commitArchive/
    // unarchiveThread/commitUnarchive/deleteThread/commitDelete/
    // undoRemoval) live in MessageListView+RowActions.swift.

    // Access widened from `private` to internal: called from
    // `MessageListView+Undo.swift`'s `scheduleUndo`, a different file.
    func replayOpQueueSoon(accountIds: Set<String>) async {
        for accountId in accountIds {
            await replayOpQueueSoon(accountId: accountId)
        }
    }

    func replayOpQueueSoon(accountId: String) async {
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
        guard let auth = try? await environment.auth(for: account) else { return }
        _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
    }
}
