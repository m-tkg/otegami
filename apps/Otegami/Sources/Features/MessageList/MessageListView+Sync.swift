import SwiftUI
import GRDB
import GoogleOAuth
import OtegamiCore
import OtegamiStore
import SyncEngine
import MailTransport
import os

extension MessageListView {
    func observeThreads() async {
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
    func observeUnreadCountInScope() async {
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
    func loadMoreIfNeeded(currentItem: ThreadSummary) {
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
    func scheduleSearch() {
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
    ///
    /// Task #194: runs the actual sync work (`performRefreshSync`) in its
    /// own child `Task`, kept in `activeSyncTask` for the duration — that's
    /// what `SyncProgressBanner`'s キャンセル button (wired up in `body`)
    /// cancels. A plain `await performRefreshSync(...)` right here (no
    /// child `Task`) would leave nothing for a cancel button to target: a
    /// SwiftUI `Button` action can't reach into the middle of an already-
    /// running `async` call on this same `View` and cancel just that call
    /// without a `Task` handle to call `.cancel()` on.
    ///
    /// Pull-to-refresh の再入ガード: このメソッドは複数の経路から並行して
    /// 呼ばれうる — `syncSelectedMailboxOnAppear()`の5分ループ (:447-452,
    /// silent, `surfaceErrors: false`)、macOS の ⌘R/更新ボタン
    /// (`MessageListView.startManualRefresh()`)、そして pull-to-refresh
    /// (`.refreshable { await refresh() }`)。以前はガードが無く、後から
    /// 始まった呼び出しの`defer`が先に完了した呼び出しの`isSyncing`/
    /// `activeSyncTask`を上書きしてしまい、バナーが (本来は消えるべき
    /// タイミングで) 残り続けたり、(まだ同期中なのに) 早く消えたりする
    /// バグがあった。既にどれかの`refresh()`呼び出しが進行中なら
    /// (`activeSyncTask`が非`nil`)、新たに`isSyncing`/`activeSyncTask`を
    /// 触らずその完了を待つだけにして相乗りする — 二重に同期を走らせない。
    ///
    /// race-free な理由: `@MainActor`上のこの`View`で、下の
    /// `isSyncing = true`から`activeSyncTask = task`までの間に
    /// `await`(suspension point)が一切無い — つまり「`activeSyncTask`が
    /// まだ`nil`なのに別の`refresh()`呼び出しが既に走り始めている」瞬間は
    /// 存在せず、上のガードの`if let running = activeSyncTask`チェックと
    /// 下のセットアップの間に他の`refresh()`呼び出しが割り込む余地が無い。
    ///
    /// 相乗りした場合の既知のトレードオフ: pull-to-refresh がたまたま
    /// silent な5分ループ (`surfaceErrors: false`) に相乗りすると、その
    /// パスが失敗してもユーザーの pull 操作に対して`syncErrorMessage`が
    /// 表示されない。ユーザー操作起点の同期が失敗を確実に表示できなく
    /// なるより、二重同期による`isSyncing`/`activeSyncTask`の破壊を防ぐ
    /// 方を優先する許容範囲のトレードオフとして明記しておく。
    func refresh(surfaceErrors: Bool = true, autoRetry: Bool = false) async {
        if let running = activeSyncTask {
            await running.value
            return
        }

        isSyncing = true
        syncProgress = nil
        defer {
            isSyncing = false
            syncProgress = nil
            activeSyncTask = nil
        }

        let task = Task {
            await performRefreshSync(surfaceErrors: surfaceErrors, autoRetry: autoRetry)
        }
        activeSyncTask = task
        let timeoutTask = makeRefreshTimeoutTask(for: task, surfaceErrors: surfaceErrors)
        await task.value
        timeoutTask.cancel()
    }

    /// 実機バグ (pull-to-refresh が5分終わらない) の再発防止線: 同期そのものに
    /// 上限が無く、遅い経路に当たると「待つ以外に何もできない」状態が続いて
    /// いた。原因になっていた UID 空間全体スキャンは
    /// `MailboxSyncer.incrementalSync` 側で塞いだが、IMAP サーバー/回線が
    /// 単に遅い日は誰にも予測できないので、上限そのものをここに置く。
    ///
    /// キャンセルは `SyncProgressBanner` のキャンセルボタンとまったく同じ
    /// 経路 (`activeSyncTask.cancel()`) — `MailCoreIMAPSession.runCancellable`
    /// と `MailboxSyncer`/`AccountSyncer` の `Task.checkCancellation()` が
    /// 実際に効くようになったので、押されたときと同じように途中で止まって
    /// 「そこまでに取り込めた分」は残る (各ステップが自前のトランザクション
    /// でコミットしているため — `MailboxSyncer` 冒頭の doc comment)。
    ///
    /// `surfaceErrors` が `false` の経路 (`syncSelectedMailboxOnAppear()` の
    /// 5分ループ) では中断はするがアラートは出さない — ユーザーが頼んでいない
    /// パスで割り込まない、という既存の使い分けをそのまま踏襲する。
    private func makeRefreshTimeoutTask(for task: Task<Void, Never>, surfaceErrors: Bool) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: Self.refreshTimeout)
            guard !Task.isCancelled else { return }
            task.cancel()
            guard surfaceErrors else { return }
            syncErrorMessage = "同期に時間がかかりすぎたため中断しました。通信状況を確認して、もう一度お試しください。"
        }
    }

    /// 1回の pull-to-refresh / 手動再同期が走り続けてよい上限。初回同期
    /// (`AccountSyncer.performInitialSync`、直近500件+本文プリフェッチ) は
    /// この経路を通らないので、ここを通るのは差分同期だけ — 実機ログでは
    /// 正常なアカウントで数秒、遅い日でも十数秒で終わっている。90秒は
    /// 「明らかに何かおかしい」と言い切れる余裕を持たせた線。
    private static let refreshTimeout: Duration = .seconds(90)

    /// Task #194: applies one `MailboxSyncer.SyncProgressUpdate` to
    /// `syncProgress`. `@MainActor` and called via `Task { @MainActor in
    /// applySyncProgress(update) }` at every `onProgress:` call site below
    /// — the closure itself runs on whatever actor
    /// `AccountSyncer`/`MailboxSyncer` calls it from (not this view's own
    /// `MainActor` isolation, even though the closure literal was created
    /// here), so touching `@State` directly inside it would be unsafe.
    /// Same shape as `AboutUpdateSection.applyPhase(_:)`'s identical
    /// "progress callback from a background actor, hop back for `@State`"
    /// pattern.
    @MainActor
    private func applySyncProgress(_ update: MailboxSyncer.SyncProgressUpdate) {
        syncProgress = update
    }

    private func performRefreshSync(surfaceErrors: Bool, autoRetry: Bool) async {
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
                    _ = try await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth, scope: .mailbox(path: mailboxPath), autoRetry: autoRetry, forceReconcileVanishedUIDs: true, onProgress: syncProgressCallback)
                } else {
                    _ = try await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth, autoRetry: autoRetry, forceReconcileVanishedUIDs: true, onProgress: syncProgressCallback)
                }
            } catch is CancellationError {
                // Task #194: a user-initiated cancel, not a sync failure —
                // no alert.
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
                    _ = try await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth, scope: .inboxOnly, autoRetry: autoRetry, forceReconcileVanishedUIDs: true, onProgress: syncProgressCallback)
                } catch is CancellationError {
                    // Task #194: stop refreshing the *remaining* accounts
                    // too — a cancel means "stop now", not "skip just this
                    // one account and move on" (the per-account failure
                    // handling below is for genuine sync errors).
                    break
                } catch {
                    failures.append("\(account.email): \(error)")
                }
            }
            if surfaceErrors, !failures.isEmpty {
                syncErrorMessage = failures.joined(separator: "\n")
            }
        case .unifiedRole(let role):
            // 画面構造改修バッチ (Task #33, 3): 「横断ビュー」の pull-to-
            // refresh。`.unifiedInbox`と同じく`unifiedInboxAccountFilter`
            // を適用する — 表示クエリの`observeThreads()`は既に
            // `.unifiedRole`ケースで`unifiedInboxAccountFilter`を適用済み
            // (このファイル冒頭のdoc comment参照) なのに、同期側だけ常に
            // 全アカウントを回るのは非対称だった (アカウントダイジェスト
            // からの絞り込み遷移中に pull-to-refresh すると、フィルタ対象
            // 外のアカウントまで同期される)。
            let accountsToRefresh = unifiedInboxAccountFilter
                .flatMap { filterId in environment.accounts.first { $0.id == filterId } }
                .map { [$0] } ?? environment.accounts
            var failures: [String] = []
            for account in accountsToRefresh {
                do {
                    let auth = try await environment.auth(for: account)
                    _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
                    // scope 縮小: `.unifiedInbox`の`.inboxOnly`に相当する
                    // role 専用の同期スコープが`SyncCoordinator`側に無い
                    // (`SyncScope`は`.inboxOnly`/`.mailbox(path:)`/
                    // `.mailboxes(paths:)`/`.all`の4種) ため、この role の
                    // メールボックスを実際に引いて`.mailboxes(paths:)`に
                    // 絞る — Task #152 で`.mailboxes(paths:)`が入った際は
                    // opQueue replay 後のターゲット再同期用だったが、ここでも
                    // 「特定のメールボックス集合だけ同期したい」という同じ
                    // 形にちょうど当てはまる。該当 role のメールボックスが
                    // 見つからない (まだ一度も`listMailboxes`していない等)
                    // 場合だけ従来どおり`.all`にフォールバックする —
                    // role mailbox 未発見アカウントの自己修復経路として
                    // 維持する。
                    let paths = try await roleMailboxPaths(account: account, role: role)
                    let scope: SyncScope = paths.isEmpty ? .all : .mailboxes(paths: paths)
                    _ = try await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth, scope: scope, autoRetry: autoRetry, forceReconcileVanishedUIDs: true, onProgress: syncProgressCallback)
                } catch is CancellationError {
                    // Task #194: same reasoning as the `.unifiedInbox` case's
                    // identical `break`.
                    break
                } catch {
                    failures.append("\(account.email): \(error)")
                }
            }
            if surfaceErrors, !failures.isEmpty {
                syncErrorMessage = failures.joined(separator: "\n")
            }
        }
    }

    /// 画面構造改修バッチ (Task #33, 3): `.unifiedRole`の pull-to-refresh
    /// scope 縮小用 — 該当メールボックスの`path`集合を返し、呼び出し側は
    /// そのまま`SyncScope.mailboxes(paths:)`に渡す。scope の定義そのものは
    /// `MailboxQuery.roleScopedMailboxPaths`側 (表示クエリ
    /// `ThreadQuery.unifiedInboxRequest`と揃える必要があり、`make test`だけ
    /// で回帰を押さえられる場所) にあり、ここは DB 読みの薄いラッパ —
    /// CI の SwiftUI 型チェックタイムアウト対策 (CLAUDE.md参照) で判定を
    /// ビューに持ち込まない。
    ///
    /// 特に Gmail の「アーカイブ」は All Mail (role `.all`) が実体なので
    /// `role`をそのまま引くと 0 件になり、呼び出し側が`.all`(そのアカウント
    /// の全メールボックス同期) にフォールバックしていた — 表示側は
    /// `MailboxRoleRecord.gmailArchiveQueryRole`で読み替えていたのに同期側
    /// だけ読み替えておらず非対称だった。
    private func roleMailboxPaths(account: AccountRecord, role: MailboxRoleRecord) async throws -> Set<String> {
        try await environment.database.dbWriter.read { db in
            try MailboxQuery.roleScopedMailboxPaths(
                accountId: account.id, accountKind: account.kind, role: role, db: db
            )
        }
    }

    /// Task #194: shared `onProgress` closure for every `syncAccountIncrementally`
    /// call in `performRefreshSync` above — hops to `@MainActor` via
    /// `applySyncProgress(_:)` (see that method's doc comment for why this
    /// closure can't just touch `syncProgress` directly).
    private var syncProgressCallback: @Sendable (MailboxSyncer.SyncProgressUpdate) -> Void {
        { update in
            Task { @MainActor in applySyncProgress(update) }
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
    func syncSelectedMailboxOnAppear() async {
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
}
