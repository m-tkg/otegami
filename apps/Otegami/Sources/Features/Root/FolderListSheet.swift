import SwiftUI
import GRDB
import OtegamiStore
import SyncEngine

/// iOS-only (新画面構成 (1)): the content of `MailScreenView`'s hamburger-
/// menu drawer (`HamburgerMenuContainer`) — formerly a modal `.sheet`
/// (design-phase-2's 1a), now permanently mounted inside the drawer and
/// slid in/out instead of presented/dismissed. Content mirrors what
/// `SidebarView` (macOS's permanently-visible left column) shows — unified
/// inbox row, outbox/drafts/sync-error banners, each account's mailbox
/// tree — plus 設定 pinned at the bottom (`settingsSection`, 新画面構成 (1):
/// "設定はそのメニューの一番下に配置"). Deliberately a *separate* type from
/// `SidebarView` rather than a shared extraction: this view owns its own
/// `ValueObservation`s (mailboxes, unread counts, outbox/draft/error
/// counts) with the same shape as `SidebarView`'s, but the two are
/// presented completely differently (an always-visible `NavigationSplitView`
/// column vs. a sliding drawer) and `SidebarView` is macOS-only from here
/// on — keeping them independent avoids coupling two screens that no longer
/// share a rendering context, at the cost of the observation logic living
/// in two places. See `docs/design-system.md` for the tradeoff this task
/// recorded.
///
/// Rows that need to present something (送信待ち/下書き/同期エラー/設定/
/// アカウント追加) don't do so directly from here — they call an `onOpen*`
/// closure that asks `MailScreenView` (the common ancestor) to close the
/// drawer and present that sheet. Historically (design-phase-2) this
/// indirection existed because this view itself used to be a `.sheet`, and
/// a sheet-presented-from-a-sheet was a confirmed-broken nesting depth in
/// this app; now that this view is a drawer rather than a sheet, that
/// specific hazard is gone, but the `onOpen*` closures remain the simplest
/// way for a common ancestor that already owns every target `@State` flag
/// to coordinate "close the drawer, then open the next thing" in one place
/// (`MailScreenView.presentAfterClosingMenu(_:)`).
struct FolderListSheet: View {
    @Environment(AppEnvironment.self) private var environment

    let selectedMailboxId: Int64?
    var onSelectMailbox: (MailboxSelection, String) -> Void
    var onOpenOutbox: () -> Void
    var onOpenDrafts: () -> Void
    var onOpenFailedOps: () -> Void
    var onAddAccount: () -> Void
    /// 新画面構成 (1): メニュー最下部の「設定」行。
    var onOpenSettings: () -> Void
    /// Task #73: ドロワーの開閉状態そのもの — `MailScreenView.isMenuOpen`が
    /// そのまま渡ってくる。このビューは`HamburgerMenuContainer`の doc
    /// comment通り常設マウントされたまま`offset`でスライドするだけなので、
    /// `.sheet`のような「開くたびに再生成される」ライフサイクルが無い。
    /// 「開いた時は全折りたたみ＋選択中のみ展開」を実現するには、この値の
    /// 変化 (`false`→`true`) を`.onChange`で拾って毎回明示的にリセットする
    /// しかない — `resetCollapseStateToCurrentSelection()`参照。
    let isMenuOpen: Bool
    /// 新画面構成 (1): "閉じる" ツールバーボタン — このビューはもう `.sheet`
    /// ではなくドロワーとして常設マウントされているため、`@Environment
    /// (\.dismiss)` は使えない (呼び出しても何も起きない、提示コンテキストが
    /// 無いため)。`MailScreenView` が `isMenuOpen` を渡してドロワーを閉じる。
    var onClose: () -> Void

    /// The mailbox tree + badge counts this view shows — see
    /// `MailboxCountsObserver`'s doc comment for why the observation logic
    /// itself lives there rather than directly in this view (shared with
    /// `SidebarView`, which owns its own separate instance).
    @State private var countsObserver = MailboxCountsObserver()
    /// K (実機フィードバック第3弾): which accounts' mailbox trees are
    /// currently collapsed — seeded once from `FolderSectionCollapseStore`
    /// (persisted `UserDefaults`) so a relaunch remembers what the user
    /// last chose, then kept in sync with every toggle
    /// (`toggleAccountCollapsed(_:)`). Not present in the set = expanded
    /// (the default for an account never explicitly collapsed).
    @State private var collapsedAccountIds: Set<String> = FolderSectionCollapseStore.collapsedAccountIds

    /// 実機フィードバック第2弾 (2026-07-29「一番下にある項目を開いたとき、
    /// 開かれてることに気づきにくい」): セクションを展開した直後に、その
    /// 見出しを画面上部へ自動スクロールするためのターゲット。トグル関数が
    /// 展開時にセクション見出しの `.id` をここへ入れ、`ScrollViewReader` の
    /// `.onChange` が拾って `scrollTo(_:anchor: .top)` する — 展開行が画面
    /// 外 (下) に伸びるだけで何も動かないように見える問題への対策。
    @State private var menuScrollTarget: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                if environment.accounts.isEmpty {
                    ContentUnavailableView {
                        Label("アカウントがありません", systemImage: "envelope.badge")
                    } description: {
                        Text("メールアカウントを追加してください。")
                    } actions: {
                        Button("アカウントを追加") { onAddAccount() }
                            .accessibilityIdentifier("folderSheet.addAccountButton")
                    }
                } else {
                    statusSection
                    // ユーザー要望 (2026-08-02「ハンバーガーメニューからは
                    // このリストは消して、アカウント一覧だけ残して」):
                    // カテゴリ横断ビュー (受信トレイ/アーカイブ/送信済み等の
                    // ロール単位セクション、旧`categorySection(for:)`) は
                    // `MailScreenView.headerTitleMenu`(ヘッダタイトルの
                    // プルダウン) に選択導線を統合したため削除した —
                    // ハンバーガーメニューはアカウント別のメールボックス
                    // ツリーだけを表示する。
                    ForEach(environment.accounts) { account in
                        accountSection(for: account)
                    }
                }
            }
            .accessibilityIdentifier("folderSheet.list")
            // Task #191 (実機フィードバック「各項目の高さが高すぎてスカスカ」):
            // 憶測で数値を変える前に、`scripts/verify-screen.sh menu`/
            // `menu-expanded`のスクリーンショットをピクセル単位で計測して
            // 高さの出どころを切り分けた (行のカード境界・見出しグリフの
            // y座標を実測、`docs/design-system.md`「Task #191」節に詳細)。
            // 分かったこと2つ:
            // 1. データ行 (`otegamiMenuRowChrome()`) は`.frame(minHeight:
            //    32)`+`.listRowInsets`を付けていたのに実測 約51pt もあった
            //    — `List`(この画面は`.listStyle`を指定していなかった) が
            //    敷く行の最小高さ (`defaultMinListRowHeight`環境値) の方が
            //    常に上回って勝っていたため。32ptという数値は最初から一度も
            //    実際の行高になったことがなかった。
            // 2. セクション見出し (`AccountSectionHeader`/`CategorySectionHeader`)
            //    はもっと深刻だった — ユーザーが実際に開いた瞬間に見る
            //    「全セクション折りたたみ済み」の初期状態 (`resetCollapse
            //    StateToCurrentSelection()`) は見出し行だけが縦に並ぶので、
            //    報告の「12行しか入らない」はほぼこの見出し行の高さの話。
            //    見出し自身のコンテンツは44ptで収まっているのに、見出し1行
            //    が`List`内で専有する実際のピッチは約67pt — 差の23ptは
            //    見出しの*外側*、`Section`境界に付く余白だった。この余白は
            //    `UITableView.sectionHeaderTopPadding`ではない (Xcode-beta
            //    のこのiOSでは`List`はもう`UITableView`ではなく
            //    `UICollectionView`(`UpdateCoalescingCollectionView`/
            //    `ListRepresentable<CollectionViewListDataSource...>`)裏打ち
            //    — 実際にビューツリーをダンプして確認済み、SwiftUI/UIKit
            //    どちら側にも直接叩ける public API が無い。
            // 対策: `.listStyle(.plain)` に明示的に切り替える —
            // `MessageListView`/`AccountDigestView`が既に同じ理由 (実機
            // フィードバック第2弾以降の「フラット・エッジツーエッジ」デザ
            // イン) で使っている、このアプリ既存の標準スタイル。`Section`
            // 境界の強制余白が事実上消え、見出し行・データ行とも実測どおり
            // 詰まる。アカウント別の白いカード外観 (`Section`の背景) 自体は
            // `.plain`でも維持される — 変わるのはセクション*間*の強制マー
            // ジンだけ (`scripts/verify-screen.sh menu-expanded`で見た目を
            // 確認済み、後述)。`FolderListSheet`自体は iOS 専用
            // (`HamburgerMenuContainer`のドロワーとしてのみ使われる — macOS
            // は別の `SidebarView` を持つ) だが、`.listStyle`自体は macOS で
            // 型が合わない/意味が異なるため `#if os(iOS)` で囲む
            // (`make mac`のビルドを壊さないため — Swift はプラットフォーム
            // ごとに未使用コードでも全部コンパイルする)。
            #if os(iOS)
            .listStyle(.plain)
            // セクション間の最小限の呼吸幅として明示的に指定 — `.plain`は
            // 既定でもかなり詰まるが、0だとアカウント間/カテゴリ間の境界が
            // 完全に消えて見分けにくくなることを画面で確認したため、
            // `OtegamiSpacing.xs`(4pt) 分だけ残す。生の`4`を書いていた旧実装
            // をトークン参照に直した。
            .listSectionSpacing(OtegamiSpacing.xs)
            #endif
            // データ行の実際のタップ領域＝見た目の行高になる (`List`の1行は
            // 隣接セルとタップ判定を奪い合うため、`otegamiMinimumTappable()`
            // のcontentShape拡張トリックがここでは効かない) ので、44pt を
            // 下回ると即 HIG 違反になる。`.listStyle(.plain)`にしても行の
            // 最小高さの既定値がこのアプリの想定より大きい可能性があるため、
            // `OtegamiTapTarget.minimum` (44pt, `otegamiMinimumTappable()`と
            // 同じ HIG 由来の定数) を明示的に敷いて、削れるのは「実測51pt→
            // 44pt」までであることをコード上でも保証する。
            .environment(\.defaultMinListRowHeight, OtegamiTapTarget.minimum)
            // `menuScrollTarget` の doc comment 参照 — 展開直後に見出しを
            // 上端へスクロール。`.onChange` は展開行の insert が同じ更新
            // サイクルで確定した後に発火するため、`scrollTo` 時点で行の
            // 実体が存在する。
            .onChange(of: menuScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.default) {
                    proxy.scrollTo(target, anchor: .top)
                }
                menuScrollTarget = nil
            }
            .scrollContentBackground(.hidden)
            .background(OtegamiColor.background)
            .navigationTitle("フォルダ")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // J (実機フィードバック第3弾): アイコンのみのボタンに変更
                    // (テキストラベルだった旧実装 — `Button("閉じる")`) —
                    // `Label` の `title`/`icon` を両方渡しつつ
                    // `.labelStyle(.iconOnly)` にすることで、見た目は
                    // xmark アイコンだけになりつつ VoiceOver は "title"
                    // (=「閉じる」) をそのまま読み上げ続ける — SwiftUI の
                    // `Label` は `.iconOnly` でも `title` をアクセシビリ
                    // ティラベルとして保持する、というドキュメント通りの
                    // 挙動。
                    Button(action: onClose) {
                        Label("閉じる", systemImage: "xmark")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("folderSheet.closeButton")
                }
                // Task #126, 1: 設定ボタンをメニュー最下部の左下フローティング
                // (旧`floatingSettingsButton`) から、ヘッダ右上 (歯車アイコン)
                // へ移設した — `presentAfterClosingMenu`経由の「ドロワーを
                // 閉じてから設定シートを開く」動線 (`onOpenSettings`) 自体は
                // 変えていない、呼び出し元をこのツールバーボタンに変えただけ。
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onOpenSettings) {
                        Label("設定", systemImage: "gearshape")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("folderSheet.settings")
                }
            }
            }
        }
        .tint(OtegamiColor.accent)
        .accessibilityIdentifier("folderSheet.sheet")
        .task(id: environment.accounts.map(\.id)) {
            await countsObserver.observeOutbox(accountIds: environment.accounts.map(\.id), dbWriter: environment.database.dbWriter)
        }
        .task(id: environment.accounts.map(\.id)) {
            await countsObserver.observeDraftCount(accountIds: environment.accounts.map(\.id), dbWriter: environment.database.dbWriter)
        }
        .task(id: environment.accounts.map(\.id)) {
            await countsObserver.observeFailedOpCount(accountIds: environment.accounts.map(\.id), dbWriter: environment.database.dbWriter)
        }
        // 画面構造改修バッチ (Task #33, 3): 以前は`accountSection(for:)`の
        // `.task(id: account.id)`としてアカウント単位のSectionにぶら下がって
        // いたこの2つの観測を、ここへ引き上げてある — アカウント別ツリーが
        // 全アカウントを横断して読むため。
        .task(id: environment.accounts.map(\.id)) { await observeAllMailboxes() }
        .task(id: environment.accounts.map(\.id)) { await observeAllUnreadCounts() }
        // Task #73: 「開いた時は全折りたたみ＋選択中のみ展開」— ドロワーが
        // 閉→開に切り替わるたびリセットする。開いている間の手動開閉
        // (`toggleAccountCollapsed`) はここでは一切妨げない (このビューは
        // 常設マウントのため、閉じている間の手動操作もそのまま次に活きて
        // しまうが、次に開いた瞬間に必ずここで上書きされるので実害はない)。
        .onChange(of: isMenuOpen) { _, newValue in
            if newValue {
                resetCollapseStateToCurrentSelection()
            }
        }
    }

    /// Task #73: ドロワーが開かれた瞬間に呼ばれる — 現在の選択
    /// (`selectedMailboxId`) が属するアカウントセクションだけを展開状態に
    /// し、それ以外の全アカウントセクションを折りたたむ。`.unifiedInbox`/
    /// `.unifiedRole`選択中 (`selectedMailboxId`が`nil`) の場合は展開対象が
    /// 無い = 全折りたたみになる。
    private func resetCollapseStateToCurrentSelection() {
        // Task #110 検証用: `scripts/verify-screen.sh`の`menu-expanded`
        // シナリオが、タップ (シェブロン操作) 無しで展開状態を screenshot
        // するための直接遷移フラグ — `-uitestsOpenSettingsDirectly`等と
        // 同じ「実機/通常起動では引数に無いので常にno-op」パターン。
        if ProcessInfo.processInfo.arguments.contains("-uitestsExpandFolderMenuSectionsDirectly") {
            withAnimation(.default) {
                collapsedAccountIds = []
            }
            FolderSectionCollapseStore.replaceAll(collapsedAccountIds: collapsedAccountIds)
            return
        }

        var expandedAccountIds: Set<String> = []

        // 実機フィードバック第2弾 (2026-07-29「常に1つだけ開かれてる状態に
        // して」): アコーディオン化に合わせ、開いた時の展開も選択中の
        // アカウント1つだけに絞る。
        if let selectedMailboxId, let entry = accountAndMailbox(forMailboxId: selectedMailboxId) {
            expandedAccountIds.insert(entry.account.id)
        }

        let allAccountIds = Set(environment.accounts.map(\.id))

        withAnimation(.default) {
            collapsedAccountIds = allAccountIds.subtracting(expandedAccountIds)
        }
        FolderSectionCollapseStore.replaceAll(collapsedAccountIds: collapsedAccountIds)
    }

    /// 現在選択中の`mailboxId`がどのアカウント・メールボックスのものかを
    /// `mailboxesByAccountId`から引く — `resetCollapseStateToCurrentSelection()`
    /// 専用のヘルパー。
    private func accountAndMailbox(forMailboxId mailboxId: Int64) -> (account: AccountRecord, mailbox: MailboxRecord)? {
        for account in environment.accounts {
            if let mailbox = (countsObserver.mailboxesByAccountId[account.id] ?? []).first(where: { $0.id == mailboxId }) {
                return (account, mailbox)
            }
        }
        return nil
    }

    private func observeAllMailboxes() async {
        await withTaskGroup(of: Void.self) { group in
            for account in environment.accounts {
                group.addTask { await countsObserver.observeMailboxes(accountId: account.id, dbWriter: environment.database.dbWriter) }
            }
        }
    }

    private func observeAllUnreadCounts() async {
        await withTaskGroup(of: Void.self) { group in
            for account in environment.accounts {
                group.addTask { await countsObserver.observeUnreadCounts(accountId: account.id, dbWriter: environment.database.dbWriter) }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            // ユーザー要望 (2026-08-02): 統合受信トレイ/カテゴリ横断ビュー
            // (受信トレイ/アーカイブ等) への選択導線は
            // `MailScreenView.headerTitleMenu`(ヘッダタイトルのプルダウン)
            // に一本化した — この画面には送信待ち/下書き/同期エラーへの
            // 導線だけが残る。
            if countsObserver.outboxCount > 0 {
                Button {
                    onOpenOutbox()
                } label: {
                    Label("送信待ち (\(countsObserver.outboxCount))", systemImage: "tray.and.arrow.up")
                }
                .otegamiMenuRowChrome()
                .accessibilityIdentifier("folderSheet.outbox")
            }
            if countsObserver.draftCount > 0 {
                Button {
                    onOpenDrafts()
                } label: {
                    Label("下書き (\(countsObserver.draftCount))", systemImage: "doc")
                }
                .otegamiMenuRowChrome()
                .accessibilityIdentifier("folderSheet.drafts")
            }
            if countsObserver.failedOpCount > 0 {
                Button {
                    onOpenFailedOps()
                } label: {
                    Label("同期エラー (\(countsObserver.failedOpCount))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(OtegamiColor.destructive)
                }
                .otegamiMenuRowChrome()
                .accessibilityIdentifier("folderSheet.failedOps")
            }
        }
    }

    // Task #126, 1: 設定は左下のフローティングボタン (旧`floatingSettingsButton`)
    // だった — メニュー最上部の右上、歯車アイコンのツールバーボタンに移設
    // した (`body`の`.toolbar`内、`.confirmationAction`プレースメント)。
    // `otegamiFloatingButtonChrome()`はもうこの画面では使わない。

    /// K (実機フィードバック第3弾): one account's collapsible mailbox-tree
    /// `Section` — the header itself is a tappable row
    /// (`AccountSectionHeader`, split out for the same `docs/ci.md` reason
    /// every other row-shaped closure in this file already is) rather than
    /// `Section`'s own `String` header, since a plain `Section` header has
    /// no tap target to hang the collapse toggle off. The `ForEach` over
    /// mailboxes only renders while expanded — collapsing removes the rows
    /// from the list entirely (not just visually hidden), matching a
    /// standard disclosure-group's behavior.
    @ViewBuilder
    private func accountSection(for account: AccountRecord) -> some View {
        let isCollapsed = collapsedAccountIds.contains(account.id)
        let header = AccountSectionHeader(
            accountId: account.id,
            labelColorKey: account.labelColorKey,
            title: account.displayName,
            unreadCount: accountUnreadCount(for: account.id),
            isCollapsed: isCollapsed,
            onToggle: { toggleAccountCollapsed(account.id) }
        )
        .id("menuSection-account-\(account.id)")
        if isCollapsed {
            // Task #191 の doc comment 参照 (`body`の`List`直下のコメント) —
            // 折りたたみ中は`Section`そのものを使わない。中身の行がゼロ件
            // なのに`Section`境界のシステム既定余白 (実測、後述) だけを
            // 払う羽目になっていたのが「各項目の高さが高すぎてスカスカ」
            // の主因だった。折りたたみ中は見出しをただの1行として描画し、
            // 行の高さ管理は他のデータ行と同じ`defaultMinListRowHeight`に
            // 委ねる。展開時だけ`Section`に包み直す (下の`else`枝) — 中身の
            // 行がある間は白いカード外観を保ちたいため。
            header.otegamiMenuHeaderRowChrome()
        } else {
            Section {
                ForEach(countsObserver.mailboxesByAccountId[account.id] ?? []) { mailbox in
                    folderMailboxRow(for: mailbox, in: account)
                }
            } header: {
                header
            }
        }
    }

    /// K: the badge a collapsed account's header shows — every mailbox's
    /// unread count summed, not just the inbox's, so collapsing an account
    /// never hides unread mail the way a single-mailbox badge would.
    private func accountUnreadCount(for accountId: String) -> Int {
        (countsObserver.mailboxesByAccountId[accountId] ?? [])
            .compactMap(\.id)
            .reduce(0) { $0 + (countsObserver.unreadByMailboxId[$1] ?? 0) }
    }

    /// 実機フィードバック第2弾 (2026-07-29): アコーディオン動作 — 展開する
    /// ときは他のアカウントセクションを全て畳み、常に最大1セクションだけが
    /// 開いた状態を保つ。畳む操作は単にそのセクションを閉じるだけ
    /// (全closedは許容)。
    private func toggleAccountCollapsed(_ accountId: String) {
        let collapsing = !collapsedAccountIds.contains(accountId)
        withAnimation(.default) {
            if collapsing {
                collapsedAccountIds.insert(accountId)
            } else {
                collapsedAccountIds = Set(environment.accounts.map(\.id)).subtracting([accountId])
            }
        }
        FolderSectionCollapseStore.replaceAll(collapsedAccountIds: collapsedAccountIds)
        if !collapsing {
            // 展開に気づけるよう見出しを上端へ (`menuScrollTarget`参照)。
            menuScrollTarget = "menuSection-account-\(accountId)"
        }
    }

    /// Mirrors `SidebarView.mailboxRow(for:in:)`'s split (see its own doc
    /// comment/`docs/ci.md`): the `ForEach` closure stays a single named
    /// function call, everything else lives in `FolderMailboxRow`.
    @ViewBuilder
    private func folderMailboxRow(for mailbox: MailboxRecord, in account: AccountRecord) -> some View {
        if let mailboxId = mailbox.id {
            let mailboxSelection = MailboxSelection(accountId: account.id, mailboxId: mailboxId)
            let isSelected = selectedMailboxId == mailboxId
            FolderMailboxRow(
                accountId: account.id,
                mailbox: mailbox,
                unreadCount: countsObserver.unreadByMailboxId[mailboxId],
                isSelected: isSelected,
                onTap: { onSelectMailbox(mailboxSelection, mailbox.displayPath) }
            )
        }
    }

}

/// K (実機フィードバック第3弾): persists which accounts' mailbox trees are
/// collapsed — a plain `UserDefaults` array under one key (not a value per
/// account id, since the set of collapsed accounts is small and read/
/// written as a whole every time anyway). Account names are dynamic user
/// data, never localized strings, so unlike this app's `*SettingsStore`
/// types this one has no `docs/localization.md` concerns.
enum FolderSectionCollapseStore {
    static let collapsedAccountIdsKey = "folderSheet.collapsedAccountIds"

    static var collapsedAccountIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedAccountIdsKey) ?? [])
    }

    static func setCollapsed(_ collapsed: Bool, accountId: String) {
        var ids = collapsedAccountIds
        if collapsed {
            ids.insert(accountId)
        } else {
            ids.remove(accountId)
        }
        UserDefaults.standard.set(Array(ids), forKey: collapsedAccountIdsKey)
    }

    /// Task #73: ドロワーを開いた瞬間の一括リセット専用 — `setCollapsed(_:accountId:)`
    /// を1件ずつ呼ぶ (読み直し→書き直しをアカウント数ぶん繰り返す) 代わりに、
    /// 計算済みの集合をまとめて書く。
    static func replaceAll(collapsedAccountIds: Set<String>) {
        UserDefaults.standard.set(Array(collapsedAccountIds), forKey: collapsedAccountIdsKey)
    }
}

/// K: one account's tappable `Section` header inside `FolderListSheet` —
/// the account's display name, its aggregate unread badge (visible whether
/// expanded or collapsed — "折りたたみ中も見えること"), and a chevron whose
/// rotation communicates the current state (SwiftUI's own `DisclosureGroup`
/// convention, reproduced here rather than using `DisclosureGroup` itself
/// since that type doesn't let this app style the header as a plain
/// `Section`-header row alongside the rest of `SidebarView`/`FolderListSheet`'s
/// existing row styling).
private struct AccountSectionHeader: View {
    let accountId: String
    /// 実機フィードバック第3弾 (2026-07-29「ハンバーガーメニューでも
    /// アカウント名の横に色をつけてほしい」): カテゴリ内アカウント行
    /// (`CategoryAccountRow`) と同じ `AccountColorRail` を名前の左に出す。
    let labelColorKey: String?
    let title: String
    let unreadCount: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                AccountColorRail(accountId: accountId, labelColorKey: labelColorKey)
                Text(verbatim: title)
                Spacer()
                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(OtegamiFont.badge())
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Task #126, 2: これは`Section`の`header:`(List行そのものではない)
        // なので`.listRowInsets`は効かず、`defaultMinListRowHeight`環境値
        // (行専用) も効かない — この`.frame(minHeight:)`だけが、この
        // ヘッダー行 (丸ごと1つの`Button`＝丸ごと1つのタップ領域) の高さと
        // タップ領域の両方を決める唯一の値。実機フィードバック第2弾で
        // 一度 44→36 に圧縮していたが、Task #191 で見出し行のタップ領域を
        // 実測したところ、この`AccountSectionHeader`には`CategorySection
        // Header`のシェブロン (`CategoryDisclosureChevron`、44×44 を別途
        // 強制) のような「他の要素が44ptを底上げしてくれる」仕掛けが無く、
        // 36pt のままだと本当に HIG の44pt を下回りうると判明したため
        // `OtegamiTapTarget.minimum`(44pt) に戻した。
        .frame(minHeight: OtegamiTapTarget.minimum)
        .accessibilityIdentifier("folderSheet.account.\(accountId).header")
        // VoiceOver: the chevron's rotation alone communicates nothing to
        // VoiceOver, so the collapsed/expanded state is spelled out in the
        // trait/label instead — standard `DisclosureGroup` accessibility
        // behavior, reproduced here since this is a hand-rolled substitute.
        .accessibilityAddTraits(isCollapsed ? [] : .isSelected)
        .accessibilityValue(isCollapsed ? "折りたたみ" : "展開")
    }
}

/// One mailbox row inside `FolderListSheet` — see `SidebarView.MailboxRow`'s
/// doc comment for why this is split out of the `ForEach` closure at all
/// (same CI type-check rationale, independently re-applied to this file).
///
/// Task #126, 3: この行はもうアカウント優先モードの
/// `folderMailboxRow(for:in:)`だけから使われる (カテゴリ優先モードの「その他」
/// セクション向けだった旧`categoryMailboxRow(for:)`は削除済み) — アカウント
/// 優先モードでは呼び出し元のアカウント自身がすでにSection見出しなので、
/// 行の中に別アカウント名を併記する`accountLabelText`パラメータは常に`nil`
/// にしかならなくなった。使われなくなったフィールドと表示分岐を削除した。
private struct FolderMailboxRow: View {
    let accountId: String
    let mailbox: MailboxRecord
    let unreadCount: Int?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Label(mailbox.displayPath, systemImage: icon(for: mailbox.role))
                Spacer()
                if let unreadCount, unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(OtegamiFont.badge())
                        .accessibilityIdentifier("folderSheet.mailbox.\(accountId).\(mailbox.path).unreadBadge")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .otegamiMenuRowChrome()
        .listRowBackground(isSelected ? OtegamiColor.paleBase : nil)
        .accessibilityIdentifier("folderSheet.mailbox.\(accountId).\(mailbox.path)")
    }

    private func icon(for role: MailboxRoleRecord) -> String {
        switch role {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .trash: "trash"
        case .junk: "exclamationmark.octagon"
        case .archive: "archivebox"
        case .flagged: "flag"
        case .all: "envelope.badge.fill"
        case .none: "folder"
        }
    }
}

/// Task #126, 2 (ハンバーガーメニュー各行の縦paddingを詰める) → 実機
/// フィードバック第2弾 (2026-07-29「各行の高さをもっと短くして」) で
/// さらに圧縮: 縦insets `OtegamiSpacing.sm`(8pt)→`OtegamiSpacing.xs`(4pt)。
/// フォントサイズは変えていない。水平方向は `OtegamiSpacing.lg`(16pt)
/// のまま。`private`なので同一ファイル内の型だけが使う。
///
/// Task #191 の訂正: ここは以前`.frame(minHeight: 32)`を持ち、「HIG の
/// 44pt タップターゲットを見た目の行高が下回るが、ユーザーの明示指示に
/// よるトレードオフ」というコメントが付いていたが、実測するとその32pt
/// が実際の行高になったことは一度も無かった (`body`の`List`側コメント
/// 参照 — `defaultMinListRowHeight`環境値の方が常に勝っていたため、実際
/// の行高はずっと約51ptだった)。そのため「44pt を下回らないぎりぎりまで
/// 詰める」という当初の意図に合わせて`minHeight`自体は`body`側の
/// `.environment(\.defaultMinListRowHeight, OtegamiTapTarget.minimum)`
/// (44pt) に一本化し、ここでの`.frame(minHeight:)`は削除した — 二重に
/// 管理すると数値がずれたときに気づきにくいため。
private extension View {
    func otegamiMenuRowChrome() -> some View {
        self
            .listRowInsets(EdgeInsets(
                top: OtegamiSpacing.xs, leading: OtegamiSpacing.lg,
                bottom: OtegamiSpacing.xs, trailing: OtegamiSpacing.lg
            ))
    }

    /// Task #191: `accountSection(for:)`が折りたたみ
    /// 中に見出し (`AccountSectionHeader`) を
    /// `Section(header:)`ではなくただの`List`行として描画するときに使う
    /// chrome。`Section(header:)`として描画されるときは`List`(この画面は
    /// `.listStyle(.plain)`) がヘッダーの水平マージンを自動で付け、背景も
    /// 素通し (ページの`OtegamiColor.background`がそのまま見える) になる
    /// — ただの行として描画するとどちらも既定値 (通常行と同じ水平
    /// insets・白い行背景) に変わってしまうため、この関数で明示的に
    /// 同じ見た目 (`OtegamiSpacing.lg`の水平マージン、透明背景) に揃える。
    /// 縦方向の insets は付けない — 見出し自身が内部で`.frame(minHeight:
    /// OtegamiTapTarget.minimum)`を持っているので、ここでさらに縦
    /// paddingを足すと二重に高さを持ってしまう。
    func otegamiMenuHeaderRowChrome() -> some View {
        self
            .listRowInsets(EdgeInsets(
                top: 0, leading: OtegamiSpacing.lg,
                bottom: 0, trailing: OtegamiSpacing.lg
            ))
            .listRowBackground(Color.clear)
    }
}
