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
/// `MailTabView` owns the tappable folder-picker title instead, and search
/// moved to its own tab — `SearchTabView`) and
/// gains 1g's redesigned swipe actions, 1h's long-press bulk-selection mode,
/// and an undo toast for the two destructive bulk-capable actions (delete,
/// archive). Every macOS-only addition/removal below is behind `#if
/// os(macOS)`/`#if os(iOS)` so this stays one file rather than forking into
/// two near-duplicates.
struct MessageListView: View {
    @Environment(AppEnvironment.self) private var environment
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
    // `NavigationSplitView`) or `MailTabView`'s own `.navigationDestination`
    // (iOS).
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
    /// 行だけタップ不能"). `RootView`/`MailTabView` use this unconditional
    /// callback to force the column/push forward every time instead. The
    /// second parameter is `summary.singleMessageId` (実機フィードバック
    /// 第3弾 (A)) — `nil` for a grouped-mode row.
    var onThreadSelected: (Int64, Int64?) -> Void = { _, _ in }
    /// 1h: fires whenever this view enters/exits bulk-selection mode, so an
    /// iOS-only enclosing `MailTabView` can hide its own toolbar (folder
    /// title button, compose button) while the selection nav/bottom bar
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

    @State private var summaries: [ThreadSummary] = []
    @State private var isSyncing = false
    @State private var syncErrorMessage: String?

    // MARK: - Archive view detection (Task #87, 1)

    /// `true` while `selection` shows an archive view — see
    /// `refreshArchiveViewFlag()`'s doc comment for exactly how this is
    /// decided. Forwarded to every `MessageListRow` as `isArchiveView`,
    /// which is what actually swaps the archive swipe slot/context-menu
    /// row over to "アーカイブ解除". Starts `false` (not "archive") so a
    /// fresh selection never briefly shows the wrong slot before
    /// `refreshArchiveViewFlag()`'s first read completes.
    @State private var isArchiveView = false

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
    @State private var pageLimit = MessageListView.pageStep
    private static let pageStep = 200

    // MARK: - Search (M7, macOS only as of design-phase-2 — see this
    // type's doc comment)

    @State private var searchText = ""
    @State private var searchScope: SearchScopeOption = .all
    @State private var searchResults: [ThreadSummary] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    /// M10: bound to `.searchFocused` — see the modifier's usage site below
    /// for why (⌘F's target, macOS only — Task #165 moved this off ⇧⌘F to
    /// free that combination for "転送", see `OtegamiCommands`'s doc comment).
    @FocusState private var isSearchFieldFocused: Bool

    // MARK: - Bulk selection (1h, iOS only)

    @State private var isSelecting = false
    @State private var selectedThreadIds: Set<Int64> = []

    // MARK: - Undo (1h/1g: "即時反映＋Undo（トースト）")

    /// A destructive action (delete/archive, single-row swipe or bulk)
    /// whose local database write has **already happened** — see
    /// `commitDelete`/`commitArchive`'s doc comment for why this design
    /// commits immediately rather than delaying the write itself (a real
    /// data-loss bug the first version of this feature had). What
    /// `scheduleUndo` actually delays is the *network* replay attempt;
    /// `undo` reverses the local write and cancels the not-yet-replayed
    /// opQueue rows if the user taps "元に戻す" before that.
    private struct PendingUndo {
        var threadIds: Set<Int64>
        var message: String
        var accountIds: Set<String>
        /// Task #163: `nil` for a blocked-action notice (nothing was
        /// actually removed, so there's nothing to reverse) — see
        /// `showArchiveBlockedByPinNotice()`'s doc comment.
        var undo: (() async -> Void)?
    }
    @State private var pendingUndo: PendingUndo?
    @State private var pendingUndoTask: Task<Void, Never>?
    /// How long an undo toast stays up before its queued opQueue rows are
    /// allowed to actually replay to the server. 5s matches the common
    /// "Gmail-style" undo window long enough to react to, short enough not
    /// to leave a destructive action feeling unfinished.
    private static let undoWindow: Duration = .seconds(5)

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
    private var persistedUnreadOnly: Bool {
        ListDisplaySettingsStore.persistedBool(forKey: ListDisplaySettingsStore.unreadOnlyKey, default: ListDisplaySettingsStore.defaultUnreadOnly)
    }

    // MARK: - フラグ付きのみ表示 (Task #142、ヘッダのトグル — 未読のみ表示の隣)

    /// `unreadOnlyKey`/`isUnreadOnly`の対 — `MailScreenView`のヘッダ側トグル
    /// (`pinnedOnlyToggleButton`) が同じ`UserDefaults`キーへ直接書く。
    @AppStorage(ListDisplaySettingsStore.pinnedOnlyKey) private var isPinnedOnly = ListDisplaySettingsStore.defaultPinnedOnly

    /// `persistedUnreadOnly`と同じ理由 (#82/#105) — `observeThreads()`は
    /// このプロパティ経由で`ThreadQuery`を呼ぶ。
    private var persistedPinnedOnly: Bool {
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
    private var isFlatMode: Bool {
        !ListDisplaySettingsStore.persistedBool(forKey: ListDisplaySettingsStore.threadingKey, default: ListDisplaySettingsStore.defaultThreading)
    }

    /// Whitespace-only input (including the empty string right after
    /// `.searchable` clears) is "not searching" — the normal `summaries`
    /// list shows, exactly like before M7.
    private var isSearchActive: Bool {
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
    private var displayedSummaries: [ThreadSummary] {
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
            onRefresh: { Task { await refresh() } }
        )
    }
    #endif

    /// `body`本体 — 以前はこれが`body`そのものだった (`.searchable`/
    /// `refreshToolbarItem`を含む) が、Task #197 でmacOS専用の検索欄+
    /// 更新ボタン行 (`macListSearchBar`) を`body`側の`VStack`に外出しした
    /// ため、この一覧単体をここへ切り出した。
    private var messageListCore: some View {
        List {
            listContent
        }
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
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
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
    @ViewBuilder
    private var listContent: some View {
        ForEach(displayedSummaries) { summary in
            threadRow(for: summary)
        }
    }

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
                onPin: togglePin,
                onAppear: loadMoreIfNeeded,
                onReply: onReply,
                onReplyAll: onReplyAll,
                onForward: onForward
            )
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

    // MARK: - Bulk selection (1h)

    private func enterSelectionMode(startingWith threadId: Int64) {
        guard !isSelecting else { return }
        isSelecting = true
        selectedThreadIds = [threadId]
        onSelectionModeChanged(true)
    }

    private func exitSelectionMode() {
        guard isSelecting else { return }
        isSelecting = false
        selectedThreadIds = []
        onSelectionModeChanged(false)
    }

    private func toggleSelection(_ threadId: Int64) {
        if selectedThreadIds.contains(threadId) {
            selectedThreadIds.remove(threadId)
        } else {
            selectedThreadIds.insert(threadId)
        }
    }

    private var isAllVisibleSelected: Bool {
        let visibleIds = Set(displayedSummaries.compactMap(\.thread.id))
        return !visibleIds.isEmpty && visibleIds.isSubset(of: selectedThreadIds)
    }

    private func toggleSelectAll() {
        let visibleIds = displayedSummaries.compactMap(\.thread.id)
        if isAllVisibleSelected {
            selectedThreadIds.subtract(visibleIds)
        } else {
            selectedThreadIds.formUnion(visibleIds)
        }
    }

    private func selectedTargets() -> [ThreadSummary] {
        let base = isSearchActive ? searchResults : summaries
        return base.filter { summary in
            guard let threadId = summary.thread.id else { return false }
            return selectedThreadIds.contains(threadId)
        }
    }

    private func markSelectedAsRead() {
        let targets = selectedTargets()
        exitSelectionMode()
        Task {
            for summary in targets {
                await applyReadState(summary, markingRead: true)
            }
        }
    }

    /// Bulk "移動" — see `selectionBottomBar`'s doc comment for why this is
    /// scoped to "アーカイブへ移動" rather than an arbitrary destination
    /// picker. Each target thread's messages are moved (deleted locally,
    /// `move` op enqueued) immediately, same as the swipe row's own
    /// `archiveThread(_:)` — see `commitArchive`'s doc comment for why this
    /// commits right away rather than waiting out the undo window first.
    private func archiveSelected() {
        let targets = selectedTargets()
        let ids = selectedThreadIds
        let accountIds = Set(targets.map(\.thread.accountId))
        exitSelectionMode()
        Task {
            var snapshots: [MessageRemoval.Snapshot] = []
            for summary in targets {
                if let snapshot = await commitArchive(summary) { snapshots.append(snapshot) }
            }
            guard !snapshots.isEmpty else { return }
            scheduleUndo(threadIds: ids, message: "\(ids.count)件のスレッドをアーカイブしました", accountIds: accountIds) {
                for snapshot in snapshots { await undoRemoval(snapshot) }
            }
        }
    }

    private func deleteSelected() {
        let targets = selectedTargets()
        let ids = selectedThreadIds
        let accountIds = Set(targets.map(\.thread.accountId))
        exitSelectionMode()
        Task {
            var snapshots: [MessageRemoval.Snapshot] = []
            for summary in targets {
                if let snapshot = await commitDelete(summary) { snapshots.append(snapshot) }
            }
            guard !snapshots.isEmpty else { return }
            scheduleUndo(threadIds: ids, message: "\(ids.count)件のスレッドを削除しました", accountIds: accountIds) {
                for snapshot in snapshots { await undoRemoval(snapshot) }
            }
        }
    }

    // MARK: - Undo (1g/1h)

    /// Shows an `UndoToast` for `Self.undoWindow`, after which the already-
    /// queued opQueue rows are allowed to actually replay to the server
    /// (`replayOpQueueSoon`) — see `commitDelete`/`commitArchive`'s doc
    /// comment for why the local write driving what's actually visible on
    /// screen has *already happened* by the time this is called, and only
    /// the network side is what this delays. `undo` reverses that local
    /// write and deletes the not-yet-replayed opQueue rows if the user taps
    /// "元に戻す" (`undoPending()`) before the window elapses; if replay
    /// already won the race (e.g. the account's IDLE loop or a manual
    /// refresh replayed it independently), `undo`'s opQueue-row deletion is
    /// simply a no-op (the rows are already gone) and only the local
    /// restore applies — a rare, acceptable edge case, not silent data
    /// corruption either way. Only one undo toast is shown at a time;
    /// scheduling a new one while an earlier one is still pending lets the
    /// earlier one's replay proceed immediately instead of waiting out its
    /// own window unseen.
    private func scheduleUndo(threadIds: Set<Int64>, message: String, accountIds: Set<String>, undo: (() async -> Void)?) {
        pendingUndoTask?.cancel()
        if let previous = pendingUndo {
            Task { await replayOpQueueSoon(accountIds: previous.accountIds) }
        }
        pendingUndo = PendingUndo(threadIds: threadIds, message: message, accountIds: accountIds, undo: undo)
        notifyPendingUndoChanged()
        pendingUndoTask = Task {
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            pendingUndo = nil
            notifyPendingUndoChanged()
            await replayOpQueueSoon(accountIds: accountIds)
        }
    }

    /// Task #108: reports the current `pendingUndo` (or its absence) to
    /// `onPendingUndoChanged` — called from every site that mutates
    /// `pendingUndo` (`scheduleUndo`'s two writes, `undoPending()`, and the
    /// `scenePhase` backstop below) so a parent rendering the toast
    /// externally (`suppressInternalUndoToast`'s doc comment) never sees a
    /// stale value.
    private func notifyPendingUndoChanged() {
        guard let pendingUndo else {
            onPendingUndoChanged(nil)
            return
        }
        onPendingUndoChanged(UndoToastPayload(message: pendingUndo.message, onUndo: undoButtonAction(for: pendingUndo)))
    }

    private func undoPending() {
        pendingUndoTask?.cancel()
        guard let pendingUndo, let undo = pendingUndo.undo else { return }
        self.pendingUndo = nil
        notifyPendingUndoChanged()
        Task { await undo() }
    }

    /// Task #163: `UndoToast`/`UndoToastPayload`'s `onUndo` for a given
    /// `PendingUndo` — `nil` (no button) for a blocked-action notice
    /// (`pending.undo == nil`), `undoPending` otherwise. Extracted into its
    /// own explicitly-typed function rather than an inline ternary at
    /// either call site — see `AccountDigestView.undoButtonAction(for:)`'s
    /// identical doc comment for why (a Swift compiler crash the inline
    /// form triggered inside `body`'s `some View` expression).
    private func undoButtonAction(for pending: PendingUndo) -> (() -> Void)? {
        guard pending.undo != nil else { return nil }
        return undoPending
    }

    /// Task #163 (実機フィードバック「ピン留めされたメールはアーカイブできない
    /// ようにしてほしい」): shown when `SyncEngine.MessageRemoval.commit(_:
    /// summary:accountId:db:)` throws `MessageRemoval.ArchiveGuardError
    /// .pinned` — reuses `scheduleUndo`'s exact timer/external-render
    /// plumbing (`suppressInternalUndoToast`'s doc comment) with an empty
    /// `threadIds`/`accountIds` and a `nil` `undo`, so it renders as the same
    /// toast shell with no "元に戻す" button (`UndoToast`'s doc comment) and
    /// no opQueue replay to schedule — nothing was actually removed.
    private func showArchiveBlockedByPinNotice() {
        scheduleUndo(threadIds: [], message: "ピン留め中のためアーカイブできません", accountIds: [], undo: nil)
    }

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
    private static let observeThreadsLogger = Logger(subsystem: "com.mtkg.otegami", category: "MessageListQueryMode")

    private func observeThreads() async {
        // `.notice`: debug は log collect アーカイブに残らない (Task #105)。
        Self.observeThreadsLogger.notice(
            "observeThreads: isFlatMode=\(isFlatMode, privacy: .public) unreadOnly=\(persistedUnreadOnly, privacy: .public) pinnedOnly=\(persistedPinnedOnly, privacy: .public) selection=\(String(describing: selection), privacy: .public)"
        )
        switch selection {
        case .mailbox(let mailboxSelection):
            let observation: ValueObservation<ValueReducers.Fetch<[ThreadSummary]>> = isFlatMode
                ? ThreadQuery.flatSummariesObservation(mailboxId: mailboxSelection.mailboxId, limit: pageLimit, accountId: mailboxSelection.accountId, unreadOnly: persistedUnreadOnly, pinnedOnly: persistedPinnedOnly)
                : ThreadQuery.summariesObservation(mailboxId: mailboxSelection.mailboxId, limit: pageLimit, unreadOnly: persistedUnreadOnly, pinnedOnly: persistedPinnedOnly)
            do {
                for try await fetched in observation.values(in: environment.database.dbWriter) {
                    applySummaries(fetched)
                }
            } catch {
                // A failing observation just stops the list from updating
                // further; it doesn't clear what's already shown.
            }
        case .unifiedInbox:
            let accountIds = unifiedInboxAccountFilter.map { [$0] } ?? environment.accounts.map(\.id)
            let observation: ValueObservation<ValueReducers.Fetch<[ThreadSummary]>> = isFlatMode
                ? ThreadQuery.unifiedInboxFlatSummariesObservation(accountIds: accountIds, limit: pageLimit, unreadOnly: persistedUnreadOnly, pinnedOnly: persistedPinnedOnly)
                : ThreadQuery.unifiedInboxSummariesObservation(accountIds: accountIds, limit: pageLimit, unreadOnly: persistedUnreadOnly, pinnedOnly: persistedPinnedOnly)
            do {
                for try await fetched in observation.values(in: environment.database.dbWriter) {
                    applySummaries(fetched)
                }
            } catch {
                // Same as above.
            }
        case .unifiedRole(let role):
            // 画面構造改修バッチ (Task #33, 3): `.unifiedInbox`と同じ形だが、
            // role が`.inbox`固定ではない — `FolderListSheet`のカテゴリ優先
            // メニューの「横断ビュー」行。当初は`unifiedInboxAccountFilter`
            // のようなアカウント絞り込みが無く常に全アカウントだったが、
            // Task #92 (アカウントダイジェスト画面): ダイジェスト行タップ
            // →絞り込み一覧という遷移がこの`selection`でも起きるように
            // なったため、`.unifiedInbox`と同じく`unifiedInboxAccountFilter`
            // を適用する。`MailScreenView`はこの遷移でしか`.unifiedRole`
            // 選択中に`accountFilter`を設定しない (`selectUnifiedRole(_:)`
            // は毎回`nil`にリセットする) ので、フィルタ無し(`nil`)の
            // 既存の呼び出し元は挙動が変わらない。
            let accountIds = unifiedInboxAccountFilter.map { [$0] } ?? environment.accounts.map(\.id)
            let observation: ValueObservation<ValueReducers.Fetch<[ThreadSummary]>> = isFlatMode
                ? ThreadQuery.unifiedInboxFlatSummariesObservation(accountIds: accountIds, role: role, limit: pageLimit, unreadOnly: persistedUnreadOnly, pinnedOnly: persistedPinnedOnly)
                : ThreadQuery.unifiedInboxSummariesObservation(accountIds: accountIds, role: role, limit: pageLimit, unreadOnly: persistedUnreadOnly, pinnedOnly: persistedPinnedOnly)
            do {
                for try await fetched in observation.values(in: environment.database.dbWriter) {
                    applySummaries(fetched)
                }
            } catch {
                // Same as above.
            }
        }
    }

    /// `onUnreadCountChanged`'s doc comment — the message-level, role-scoped
    /// unread count for whatever `selection` currently is, independent of
    /// `observeThreads()`'s own paginated/threaded/unread-only-filtered row
    /// list. `.mailbox` uses `MessageQuery.unreadCountObservation`, backed
    /// by the same per-mailbox grouped query the folder list's own unread
    /// badges read (already includes the Gmail All-Mail archive definition
    /// via `GmailArchiveFilter`, since that only ever depends on the target
    /// mailbox's own `role`/`account.kind`, not on which entry point opened
    /// it — see that query's doc comment). `.unifiedInbox`/`.unifiedRole`
    /// use `MessageQuery.unifiedInboxUnreadCount(accountIds:role:)` — the
    /// same query `AccountDigestQuery.digests(accountIds:role:recentLimit:db:)`
    /// was fixed to use for Task #137's per-account badge, reused here
    /// summed across every account in scope instead of one at a time.
    private func observeUnreadCountInScope() async {
        do {
            switch selection {
            case .mailbox(let mailboxSelection):
                let observation = MessageQuery.unreadCountObservation(mailboxId: mailboxSelection.mailboxId, accountId: mailboxSelection.accountId)
                for try await count in observation.values(in: environment.database.dbWriter) {
                    onUnreadCountChanged(count)
                }
            case .unifiedInbox:
                let accountIds = unifiedInboxAccountFilter.map { [$0] } ?? environment.accounts.map(\.id)
                let observation = MessageQuery.unifiedInboxUnreadCountObservation(accountIds: accountIds)
                for try await count in observation.values(in: environment.database.dbWriter) {
                    onUnreadCountChanged(count)
                }
            case .unifiedRole(let role):
                let accountIds = unifiedInboxAccountFilter.map { [$0] } ?? environment.accounts.map(\.id)
                let observation = MessageQuery.unifiedInboxUnreadCountObservation(accountIds: accountIds, role: role)
                for try await count in observation.values(in: environment.database.dbWriter) {
                    onUnreadCountChanged(count)
                }
            }
        } catch {
            // A failing observation just stops the badge from updating
            // further — matches every other `observation.values(in:)` loop
            // in this file (`observeThreads()`).
        }
    }

    /// スワイプ滑らかさ改善: wraps every `summaries` update in an animation so
    /// a swipe/bulk removal (`MessageRemoval.commit`, observed here via
    /// GRDB's live `ValueObservation` the instant the row's own DB write
    /// commits) collapses the vacated row height smoothly instead of
    /// snapping the rows below it up a beat after `MessageListRow`'s own
    /// slide-out animation already finished — see that type's
    /// `commitReveal(action:direction:)` doc comment for the full
    /// choreography this coordinates with. `ForEach(displayedSummaries)`
    /// diffs by `ThreadSummary.id`, so this only actually animates a
    /// genuine insert/remove/reorder; an unrelated field changing on an
    /// otherwise-identical row set (e.g. a read receipt flipping the
    /// unread dot) is a no-op diff and animates nothing.
    private func applySummaries(_ fetched: [ThreadSummary]) {
        withAnimation(.easeInOut(duration: 0.25)) {
            summaries = fetched
        }
        schedulePrefetch(for: fetched)
    }

    // MARK: - Task #80: list-update-triggered background body prefetch

    /// Debounce before `schedulePrefetch(for:)`'s candidate ids are actually
    /// requested from `SyncCoordinator` — a few seconds, deliberately much
    /// longer than `scheduleSearch()`'s 300ms input-debounce: this is a
    /// background, low-priority fetch the user isn't waiting on, not
    /// something blocking visible search results, so there's no reason to
    /// react as fast. Also acts as a coalescing window for a burst of
    /// `ValueObservation` fires in quick succession (e.g. several read-state
    /// flips landing together).
    private static let listUpdatePrefetchDebounce: Duration = .seconds(3)

    @State private var prefetchTask: Task<Void, Never>?
    /// The candidate id set `schedulePrefetch(for:)` most recently actually
    /// dispatched to `SyncCoordinator` — a repeat call whose leading
    /// not-yet-fetched ids come out identical (e.g. `summaries` re-fired
    /// from an unrelated field changing, per `applySummaries`'s doc comment)
    /// is skipped outright, on top of the time-based debounce above, so
    /// typing in macOS's inline search or an unrelated live update never
    /// re-requests the exact same in-flight/already-attempted set.
    @State private var lastPrefetchedMessageIds: Set<Int64> = []

    /// Task #80 (「メール一覧が更新されたときに、バックグラウンドでメールを
    /// 取得するようにしてほしい」): whenever `summaries`/`searchResults`
    /// change — a fresh sync landing, switching mailboxes, or (macOS) a
    /// search producing new results — background-prefetches the leading
    /// `SyncCoordinator.listUpdatePrefetchLimit` not-yet-fetched messages
    /// among what's now on screen, the same "3日/200件" background-fetch
    /// infrastructure (`SyncCoordinator`/`BodyFetcher`, Task #31/#63) reused
    /// for an arbitrary displayed list rather than only the fixed unified-
    /// inbox candidate set. Only ever reads `summary.latestMessage` (the
    /// message a row would actually open first) — a grouped-mode thread's
    /// older messages aren't prefetched here.
    private func schedulePrefetch(for summaries: [ThreadSummary]) {
        let candidateIds = summaries
            .compactMap(\.latestMessage)
            .filter { $0.bodyState != .fetched }
            .compactMap(\.id)
            .prefix(SyncCoordinator.listUpdatePrefetchLimit)
        guard !candidateIds.isEmpty else { return }
        let idSet = Set(candidateIds)
        guard idSet != lastPrefetchedMessageIds else { return }

        prefetchTask?.cancel()
        let ids = Array(candidateIds)
        prefetchTask = Task(priority: .background) {
            try? await Task.sleep(for: Self.listUpdatePrefetchDebounce)
            guard !Task.isCancelled else { return }
            lastPrefetchedMessageIds = idSet
            _ = await environment.prefetchMessageBodiesIfNeeded(messageIds: ids)
        }
    }

    /// M10 pagination: called from every row's `.onAppear` — cheap even
    /// though that fires often (a `!=` comparison against the last item's
    /// id most of the time), and simpler than threading a "last visible
    /// index" through `List`. Only grows `pageLimit` when `currentItem` is
    /// the *last* row currently loaded **and** the page came back full
    /// (`summaries.count == pageLimit`) — a short page means the query
    /// already returned everything there is, so growing the limit further
    /// would just re-run the same observation for no new rows.
    private func loadMoreIfNeeded(currentItem: ThreadSummary) {
        guard !isSearchActive else { return } // search results aren't paginated this way; see SearchQuery.defaultResultLimit
        guard currentItem.id == summaries.last?.id else { return }
        guard summaries.count == pageLimit else { return }
        pageLimit += Self.pageStep
    }

    // MARK: - Search (M7, macOS only)

    /// Debounces `searchText`/`searchScope` changes by 300ms (plan: "入力
    /// 300ms デバウンス") before actually querying — cancels whatever search
    /// was already in flight so a fast typist never races two queries
    /// against the same `searchResults` state. Clearing the field (`
    /// isSearchActive == false`) skips the debounce and the query
    /// entirely: there's nothing to search, and the normal list should
    /// reappear immediately rather than after a delay.
    private func scheduleSearch() {
        searchTask?.cancel()
        guard isSearchActive else {
            isSearching = false
            searchResults = []
            return
        }
        let query = searchText
        let scope = searchScope
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch(query: query, scope: scope)
        }
    }

    private func performSearch(query: String, scope: SearchScopeOption) async {
        let storeScope: OtegamiStore.SearchScope
        switch (selection, scope) {
        case (.mailbox(let mailboxSelection), .currentMailbox):
            storeScope = .mailbox(mailboxId: mailboxSelection.mailboxId)
        default:
            storeScope = .allAccounts(accountIds: environment.accounts.map(\.id))
        }
        do {
            // 実機バグ報告「スレッド表示をオフにしてるのに、スレッドで表示
            // されることがある」: 検索結果は`isFlatMode`を無視して常に
            // グループ化されたスレッドを返していた唯一の経路だった — この
            // ファイルの他のすべての`ThreadQuery`呼び出し (`observeThreads()`)
            // は既に`isFlatMode`で分岐していたのに、検索だけ取り残されて
            // いた。`SearchQuery.flatMessageSummaries`(このバッチで新設) が
            // `ThreadQuery.flatSummaries`/`unifiedInboxFlatSummaries`と同じ
            // 「1メッセージ1行」の形を検索結果にも適用する。
            let isFlat = isFlatMode
            let results = try await environment.database.dbWriter.read { db in
                isFlat
                    ? try SearchQuery.flatMessageSummaries(query: query, scope: storeScope, db: db)
                    : try SearchQuery.threadSummaries(query: query, scope: storeScope, db: db)
            }
            guard !Task.isCancelled else { return }
            searchResults = results
            schedulePrefetch(for: results)
        } catch {
            guard !Task.isCancelled else { return }
            searchResults = []
        }
        isSearching = false
    }

    /// Pull-to-refresh / the toolbar refresh button: differential sync
    /// (M3), scoped (M4) to whichever mailbox is actually being viewed —
    /// a single mailbox for `.mailbox`, or every account's INBOX for the
    /// unified inbox (plan: "サイドバー選択時 + 手動更新"). Replays any
    /// queued offline operations first, since "the user explicitly asked
    /// to reconnect" is exactly the moment those should get a chance to
    /// flush too.
    ///
    /// `surfaceErrors` (Task #44 実機バグ「All Mail に新着が反映されない」):
    /// `syncSelectedMailboxOnAppear()` calls this same scope-resolution
    /// logic with `false` — see that method's doc comment for why a
    /// merely-opened-a-screen sync shouldn't pop the same alert an
    /// explicit pull-to-refresh does.
    ///
    /// `autoRetry` (Task #69): defaults to `false` so `.refreshable {
    /// await refresh() }`'s pull-to-refresh gesture keeps its pre-Task-#69
    /// behavior verbatim — 「手動 pull-to-refresh はユーザー操作起点 → 即時
    /// 1回実行し、失敗は従来どおり表示」(the request's exception 2):
    /// exactly one attempt, and a failure shows up in `syncErrorMessage`
    /// right away rather than after `SyncCoordinator`'s automatic-retry
    /// window. `syncSelectedMailboxOnAppear()` passes `true` explicitly —
    /// that pass is already silent (`surfaceErrors: false`), so applying
    /// `AccountSyncer.SyncRetryPolicy`'s retry-then-suppress behavior there
    /// too is a strict improvement (a transient hiccup self-heals quietly
    /// instead of just waiting for the next 5-minute pass).
    private func refresh(surfaceErrors: Bool = true, autoRetry: Bool = false) async {
        isSyncing = true
        defer { isSyncing = false }

        switch selection {
        case .mailbox(let mailboxSelection):
            guard let account = environment.accounts.first(where: { $0.id == mailboxSelection.accountId }) else { return }
            do {
                let auth: MailAuth
                do {
                    auth = try await environment.auth(for: account)
                } catch TokenStoreError.reauthenticationRequired {
                    if surfaceErrors { syncErrorMessage = "再認証が必要です。設定からアカウントを再認証してください。" }
                    return
                } catch {
                    if surfaceErrors { syncErrorMessage = "保存された資格情報が見つかりません。アカウントを再追加してください。" }
                    return
                }
                let mailboxPath = try await environment.database.dbWriter.read { db in
                    try MailboxRecord.fetchOne(db, key: mailboxSelection.mailboxId)?.path
                }
                _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
                // Task #83: `refresh()` is only ever reached from
                // pull-to-refresh, macOS's manual 再同期 button, and
                // `syncSelectedMailboxOnAppear()`'s 5-minute loop below —
                // all low-frequency, this-mailbox-scoped passes — so it
                // always asks for the vanished-UID reconciliation
                // unconditionally rather than trusting `highestModSeq`
                // alone (see `MailboxSyncer.incrementalSync`'s
                // `forceReconcileVanishedUIDs` doc comment for why that
                // guard alone missed a real residual-message bug).
                if let mailboxPath {
                    _ = try await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth, scope: .mailbox(path: mailboxPath), autoRetry: autoRetry, forceReconcileVanishedUIDs: true)
                } else {
                    _ = try await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth, autoRetry: autoRetry, forceReconcileVanishedUIDs: true)
                }
            } catch {
                if surfaceErrors { syncErrorMessage = "\(error)" }
            }
        case .unifiedInbox:
            let accountsToRefresh = unifiedInboxAccountFilter
                .flatMap { filterId in environment.accounts.first { $0.id == filterId } }
                .map { [$0] } ?? environment.accounts
            // One account failing must not stop the others from refreshing,
            // but the failures must not vanish either — an earlier version
            // `try?`'d everything here, which meant a unified-inbox refresh
            // could fail for *every* account (e.g. a real Gmail/iCloud
            // account whose sync path is broken) with no visible symptom
            // beyond the empty-state's "再同期を試してください". Collect
            // per-account failures and surface them through the same alert
            // the single-mailbox path already uses.
            var failures: [String] = []
            for account in accountsToRefresh {
                do {
                    let auth = try await environment.auth(for: account)
                    _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
                    _ = try await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth, scope: .inboxOnly, autoRetry: autoRetry, forceReconcileVanishedUIDs: true)
                } catch {
                    failures.append("\(account.email): \(error)")
                }
            }
            if surfaceErrors, !failures.isEmpty {
                syncErrorMessage = failures.joined(separator: "\n")
            }
        case .unifiedRole:
            // 画面構造改修バッチ (Task #33, 3): 「横断ビュー」の pull-to-
            // refresh — `.unifiedInbox`の`.inboxOnly`スコープに相当する role
            // 専用の同期スコープが`SyncCoordinator`側に無い (`SyncScope`は
            // `.inboxOnly`/`.mailbox(path:)`/`.all`の3種のみ) ため、`.all`
            // (全メールボックスのフル差分同期、既存の「手動全体更新」と同じ
            // スコープ)にフォールバックする — 「送信済み」や「アーカイブ」
            // だけを狙って同期する最適化は無いが、正しさ (最新の状態が見える)
            // は保たれる。
            var failures: [String] = []
            for account in environment.accounts {
                do {
                    let auth = try await environment.auth(for: account)
                    _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
                    _ = try await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth, scope: .all, autoRetry: autoRetry, forceReconcileVanishedUIDs: true)
                } catch {
                    failures.append("\(account.email): \(error)")
                }
            }
            if surfaceErrors, !failures.isEmpty {
                syncErrorMessage = failures.joined(separator: "\n")
            }
        }
    }

    /// Task #44 (実機バグ: Gmail の「すべてのメール」を表示/pull-to-refresh
    /// しても直近の新着が反映されない): merely *selecting* a mailbox
    /// previously triggered no sync of its own at all — INBOX mostly hid
    /// this gap (`OtegamiApp.syncAllAccountsOnce`'s launch/foreground
    /// `.inboxOnly` pass, plus the foreground `IDLE` loop, both keep it
    /// fresh independent of what's on screen), but every other mailbox
    /// (Sent/Archive, Gmail's role-`.all` "すべてのメール", ...) only ever
    /// caught up if/when the user happened to pull-to-refresh *that exact
    /// screen* — recently arrived mail already visible in INBOX could sit
    /// unsynced there indefinitely otherwise. Runs the identical
    /// scope-per-selection differential sync `refresh()` does (so once it
    /// succeeds, `MailboxSyncer.incrementalSync`'s "everything since the
    /// highest UID already stored" step 1 closes *any* gap in one pass,
    /// not just whatever arrived since the last sync — self-healing any
    /// backlog this mailbox missed while unviewed), just silently
    /// (`surfaceErrors: false`): a stale/offline connection here shouldn't
    /// interrupt browsing with the same alert an explicit pull-to-refresh
    /// shows, since the user never asked this particular pass to run.
    ///
    /// **Keeps retrying** every ``selectedMailboxResyncInterval`` while this
    /// mailbox stays on screen, rather than a single one-shot pass: real
    /// Gmail's own server-side indexing lag for "すべてのメール" (a message
    /// already visible in INBOX simply isn't in All Mail's IMAP view *yet*,
    /// server-side) means the very first sync right when the screen opens
    /// can legitimately, correctly come back with nothing new — confirmed
    /// against the real dev mailstack (`SyncEngineIntegrationTests
    /// .mailboxScopedIncrementalSyncPicksUpNewMailInNonInboxMailbox`) that
    /// `.mailbox(path:)`'s differential sync itself has no bug here.
    /// Looping turns "the user has to keep manually pulling to refresh,
    /// hoping to catch the exact moment Gmail catches up" into "shows up on
    /// its own eventually, no action needed" — closing the same gap INBOX
    /// already doesn't have (its foreground `IDLE` loop reacts the instant
    /// the server pushes new data). No explicit lifetime bookkeeping
    /// needed: `.task(id: selection)` cancels this loop for free the
    /// instant `selection` changes or this view disappears, so it simply
    /// stops the moment this mailbox isn't the one on screen anymore.
    ///
    /// `.task(id: selection)` (not `.onChange(of: selection)`) so this also
    /// covers the very first mailbox shown after a cold launch/relaunch
    /// (e.g. a restored "last selected" mailbox) — `.onChange` only fires
    /// on a *later* change, never for the initial value.
    private func syncSelectedMailboxOnAppear() async {
        while !Task.isCancelled {
            await refresh(surfaceErrors: false, autoRetry: true)
            try? await Task.sleep(for: .seconds(Self.selectedMailboxResyncInterval))
        }
    }

    /// How often ``syncSelectedMailboxOnAppear()`` retries while a mailbox
    /// stays on screen — battery/network-conscious (this dev mailstack's
    /// own `SyncCoordinator.prefetchUnifiedInboxBodiesIfNeeded` uses the
    /// same 5-minute figure for its own "don't spam this too often" budget)
    /// rather than IDLE-loop-tight, since this is a best-effort background
    /// catch-up pass, not the primary "new mail arrived" signal path.
    private static let selectedMailboxResyncInterval: TimeInterval = 5 * 60

    // MARK: - Row actions (M4/1g: thread-wide, applied to every message)

    /// Toggles every message in the thread to the opposite of the thread's
    /// current unread state — the swipe row's own single-thread action.
    /// `applyReadState(_:markingRead:)` below is the shared implementation
    /// bulk "既読に" also uses (forcing `markingRead: true` regardless of
    /// each thread's current state, rather than toggling).
    private func toggleRead(_ summary: ThreadSummary) {
        let markingRead = summary.thread.unreadCount > 0
        Task {
            await applyReadState(summary, markingRead: markingRead)
        }
    }

    /// Enqueues an absolute `setFlags` op per affected message (plan: "全
    /// メッセージへ適用、opQueue 経由") and makes a best-effort replay attempt
    /// right away. Shared by the swipe row's `toggleRead(_:)` and bulk
    /// selection's "既読に" button.
    private func applyReadState(_ summary: ThreadSummary, markingRead: Bool) async {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        do {
            try await environment.database.dbWriter.write { db in
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
                    // Task #120: `message.isPendingRelocation` — no real
                    // server UID to enqueue a `setFlags` op against yet;
                    // see `MessageReadMarker.markSeen`'s identical guard for
                    // the accepted-limitation rationale (this optimistic
                    // flag write can be silently superseded by that
                    // mailbox's next resync if the window doesn't close in
                    // time — the local write above still applies either
                    // way).
                    guard !message.isPendingRelocation,
                          let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId)
                    else { continue }
                    try OpQueue.enqueueSetFlags(
                        accountId: accountId, mailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [UInt32(message.uid)], flags: message.flags, db: db
                    )
                }
                try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
            }
            await replayOpQueueSoon(accountId: accountId)
        } catch {
            // Best-effort: the row simply doesn't update if this fails.
        }
    }

    // MARK: - Pinning (E9)

    /// D8/E9's swipe/context-menu "ピン留め" action — toggles every message
    /// in the thread to the opposite of the thread's current pinned state
    /// (`summary.thread.isPinned`, the OR-aggregate over its messages —
    /// `AppDatabase`'s v16 migration doc comment). Pinning every message in
    /// the thread together (rather than, say, just the row's own
    /// `latestMessage`) mirrors `toggleRead(_:)`/`archiveThread(_:)`'s
    /// existing "act on the whole thread" convention, and keeps pin/unpin
    /// symmetric: pinning then immediately unpinning the same row returns
    /// every message to exactly the state it started in, regardless of how
    /// many were already individually pinned.
    private func togglePin(_ summary: ThreadSummary) {
        let pinning = !summary.thread.isPinned
        Task { await applyPinState(summary, pinning: pinning) }
    }

    /// No undo toast (unlike delete/archive) — pinning never removes a row
    /// from the list, it only reorders it, so the action is already
    /// trivially reversible with one more tap on the same button.
    private func applyPinState(_ summary: ThreadSummary, pinning: Bool) async {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        let syncEnabled = PinSettingsStore.isSyncWithFlaggedEnabled
        do {
            try await environment.database.dbWriter.write { db in
                let messages = try ThreadQuery.actionTargets(for: summary, db: db)
                for var message in messages {
                    guard message.isPinnedLocal != pinning else { continue }
                    message.isPinnedLocal = pinning
                    if syncEnabled {
                        if pinning {
                            message.flags.insert(.flagged)
                        } else {
                            message.flags.remove(.flagged)
                        }
                    }
                    message.updatedAt = Date()
                    try message.update(db)
                    // Task #120: same pending-relocation guard as
                    // `applyReadState(_:markingRead:)` just above.
                    guard syncEnabled, !message.isPendingRelocation,
                          let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId)
                    else { continue }
                    try OpQueue.enqueueSetFlags(
                        accountId: accountId, mailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [UInt32(message.uid)], flags: message.flags, db: db
                    )
                }
                try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
            }
            if syncEnabled { await replayOpQueueSoon(accountId: accountId) }
        } catch {
            // Best-effort, matching every other opQueue-enqueuing path in
            // this file.
        }
    }

    // MARK: - Junk (D8)

    /// D8「迷惑メールにする」— mirrors `archiveThread(_:)`/`commitArchive(_:)`'s
    /// shape exactly, just moving to the account's Junk-role mailbox at
    /// *replay* time (`OpQueue.enqueueJunk`, resolved/self-healed by
    /// `OpQueueProcessor.resolveOrCreateJunkMailbox` the same way `delete`
    /// resolves Trash) rather than a pre-resolved local Archive mailbox id.
    private func junkThread(_ summary: ThreadSummary) {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        Task {
            guard let snapshot = await commitJunk(summary) else { return }
            scheduleUndo(threadIds: [threadId], message: "\(undoNoun(for: summary))を迷惑メールにしました", accountIds: [accountId]) {
                await undoRemoval(snapshot)
            }
        }
    }

    /// 実機フィードバック第3弾 (A): the undo toast's noun — "スレッド" for a
    /// grouped-mode row (unchanged wording) vs. "メール" for a flat-mode row,
    /// matching `ThreadQuery.actionTargets(for:db:)`'s equally narrowed
    /// scope (see its doc comment) so the toast text never overstates what
    /// was actually touched.
    private func undoNoun(for summary: ThreadSummary) -> String {
        summary.singleMessageId != nil ? "メール" : "スレッド"
    }

    /// `commitArchive`'s `.junk` counterpart — see its doc comment.
    private func commitJunk(_ summary: ThreadSummary) async -> MessageRemoval.Snapshot? {
        do {
            guard let snapshot = try await environment.database.dbWriter.write({ db in
                try MessageRemoval.commit(.junk, summary: summary, accountId: summary.thread.accountId, db: db)
            }) else { return nil }
            if isSearchActive {
                searchResults.removeAll { $0.id == summary.id }
            }
            return snapshot
        } catch {
            return nil
        }
    }

    /// The swipe row's single-thread archive action — commits immediately
    /// (see `MessageRemoval.commit(_:summary:accountId:db:)`'s doc comment
    /// in `SyncEngine`), then hands the resulting snapshot to
    /// `scheduleUndo`.
    private func archiveThread(_ summary: ThreadSummary) {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        Task {
            guard let snapshot = await commitArchive(summary) else { return }
            scheduleUndo(threadIds: [threadId], message: "\(undoNoun(for: summary))をアーカイブしました", accountIds: [accountId]) {
                await undoRemoval(snapshot)
            }
        }
    }

    /// Thin app-target wrapper around `SyncEngine.MessageRemoval.commit(_:
    /// summary:accountId:db:)` — the actual local-DB mutation is `SyncEngine`
    /// code now (unit-tested there without a SwiftUI host); this just wires
    /// it to `environment.database.dbWriter` and keeps `searchResults` in
    /// sync (a one-shot array, not a live `ValueObservation` like
    /// `summaries` — the normal list picks up a removal automatically, but
    /// a search-mode row needs this explicit nudge or the just-removed
    /// thread would keep showing until the next debounced re-search).
    private func commitArchive(_ summary: ThreadSummary) async -> MessageRemoval.Snapshot? {
        do {
            guard let snapshot = try await environment.database.dbWriter.write({ db in
                try MessageRemoval.commit(.archive, summary: summary, accountId: summary.thread.accountId, db: db)
            }) else { return nil }
            if isSearchActive {
                searchResults.removeAll { $0.id == summary.id }
            }
            return snapshot
        } catch is MessageRemoval.ArchiveGuardError {
            // Task #163: pinned — `archiveThread(_:)`'s swipe already
            // pre-checks this (`MessageListRow.commitReveal`'s pinned guard)
            // to skip the exit-slide animation, but this catch is still the
            // one place that actually blocks *every* archive path (the
            // toolbar/context-menu row action on macOS has no such
            // pre-check) — see `MessageRemoval.ArchiveGuardError`'s doc
            // comment.
            showArchiveBlockedByPinNotice()
            return nil
        } catch {
            // Best-effort, matching every other opQueue-enqueuing path in
            // this file.
            return nil
        }
    }

    /// Task #87 (1): "アーカイブ解除" — the archive view's swipe/context-menu
    /// row action. Mirrors `archiveThread(_:)`/`commitArchive(_:)` exactly
    /// (see their doc comments); only reached when `MessageListRow
    /// .isArchiveView` is `true`, so every `summary` this is ever called
    /// with is already an archived thread. Undo (`undoRemoval`) reverses
    /// this exactly like it reverses an archive/delete/junk — it just
    /// re-inserts the removed row(s) and cancels the not-yet-replayed
    /// `.unarchive` opQueue rows, which in effect re-archives.
    private func unarchiveThread(_ summary: ThreadSummary) {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        Task {
            guard let snapshot = await commitUnarchive(summary) else { return }
            scheduleUndo(threadIds: [threadId], message: "\(undoNoun(for: summary))のアーカイブを解除しました", accountIds: [accountId]) {
                await undoRemoval(snapshot)
            }
        }
    }

    /// `commitArchive`'s `.unarchive` counterpart — see its doc comment.
    private func commitUnarchive(_ summary: ThreadSummary) async -> MessageRemoval.Snapshot? {
        do {
            guard let snapshot = try await environment.database.dbWriter.write({ db in
                try MessageRemoval.commit(.unarchive, summary: summary, accountId: summary.thread.accountId, db: db)
            }) else { return nil }
            if isSearchActive {
                searchResults.removeAll { $0.id == summary.id }
            }
            return snapshot
        } catch {
            // Best-effort, matching every other opQueue-enqueuing path in
            // this file.
            return nil
        }
    }

    /// The swipe row's single-thread delete action — commits immediately
    /// (see `commitArchive`'s doc comment; `commitDelete` is its `.delete`
    /// counterpart), then hands the resulting snapshot to `scheduleUndo`.
    private func deleteThread(_ summary: ThreadSummary) {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        Task {
            guard let snapshot = await commitDelete(summary) else { return }
            scheduleUndo(threadIds: [threadId], message: "\(undoNoun(for: summary))を削除しました", accountIds: [accountId]) {
                await undoRemoval(snapshot)
            }
        }
    }

    /// `commitArchive`'s `.delete` counterpart — see its doc comment.
    private func commitDelete(_ summary: ThreadSummary) async -> MessageRemoval.Snapshot? {
        do {
            guard let snapshot = try await environment.database.dbWriter.write({ db in
                try MessageRemoval.commit(.delete, summary: summary, accountId: summary.thread.accountId, db: db)
            }) else { return nil }
            if isSearchActive {
                searchResults.removeAll { $0.id == summary.id }
            }
            return snapshot
        } catch {
            // Best-effort: whatever's left stays if this fails; the
            // swipe can be retried.
            return nil
        }
    }

    /// Reverses one `commitDelete`/`commitArchive` call — thin wrapper
    /// around `SyncEngine.MessageRemoval.undo(_:db:)`; see that method's
    /// doc comment for the thread-before-messages ordering this restores
    /// and why it matters. Best-effort, matching every other
    /// opQueue-enqueuing/db-mutating path in this file — a failure here
    /// just leaves the delete/archive applied, same as if "元に戻す" had
    /// never been tapped.
    private func undoRemoval(_ snapshot: MessageRemoval.Snapshot) async {
        do {
            try await environment.database.dbWriter.write { db in
                try MessageRemoval.undo(snapshot, db: db)
            }
        } catch {
            // Best-effort — see doc comment above.
        }
    }

    private func replayOpQueueSoon(accountIds: Set<String>) async {
        for accountId in accountIds {
            await replayOpQueueSoon(accountId: accountId)
        }
    }

    private func replayOpQueueSoon(accountId: String) async {
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
        guard let auth = try? await environment.auth(for: account) else { return }
        _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
    }
}
