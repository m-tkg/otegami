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
    let isUnifiedInboxSelected: Bool
    /// 画面構造改修バッチ (Task #33, 3): カテゴリ優先メニューの「横断ビュー」行
    /// (例:「すべてのアーカイブ」)がハイライトされるべき role — 現在の
    /// `MailScreenView.mailSelection`が`.unifiedRole(role)`ならその`role`、
    /// それ以外 (`.mailbox`/`.unifiedInbox`) なら`nil`。`selectedMailboxId`が
    /// `.mailbox`専用なのと対になる、もう一つの「今どれが選ばれているか」入力。
    let selectedUnifiedRole: MailboxRoleRecord?
    var onSelectUnified: () -> Void
    var onSelectMailbox: (MailboxSelection, String) -> Void
    /// 画面構造改修バッチ (Task #33, 3): カテゴリ優先メニューの「横断ビュー」行
    /// — タップされた role を渡す。`onSelectMailbox`が特定の1メールボックス
    /// (`MailboxSelection`)を渡すのに対し、こちらは「この role のメールボックス
    /// を持つ全アカウントをまとめて見る」という role 単位の選択。
    var onSelectUnifiedRole: (MailboxRoleRecord) -> Void
    var onOpenOutbox: () -> Void
    var onOpenDrafts: () -> Void
    var onOpenFailedOps: () -> Void
    var onOpenMailboxSyncFailures: () -> Void
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

    @State private var mailboxesByAccountId: [String: [MailboxRecord]] = [:]
    @State private var outboxCount = 0
    @State private var draftCount = 0
    @State private var failedOpCount = 0
    @State private var mailboxSyncFailureCount = 0
    @State private var unreadByMailboxId: [Int64: Int] = [:]
    @State private var unifiedInboxUnread = 0
    /// K (実機フィードバック第3弾): which accounts' mailbox trees are
    /// currently collapsed — seeded once from `FolderSectionCollapseStore`
    /// (persisted `UserDefaults`) so a relaunch remembers what the user
    /// last chose, then kept in sync with every toggle
    /// (`toggleAccountCollapsed(_:)`). Not present in the set = expanded
    /// (the default for an account never explicitly collapsed).
    @State private var collapsedAccountIds: Set<String> = FolderSectionCollapseStore.collapsedAccountIds
    /// 画面構造改修バッチ (Task #33, 3): カテゴリ優先メニューの折りたたみ状態 —
    /// `collapsedAccountIds`(アカウント優先メニュー用)とは別の永続キーで管理
    /// する。「既存の折りたたみ(FolderSectionCollapseStore)…を尊重」の要件は
    /// アカウント優先モード自身の折りたたみ状態を変えない、という意味であって、
    /// 表示単位そのものが違うカテゴリ優先モードに同じ折りたたみ状態を無理に
    /// 使い回す理由にはならない。
    @State private var collapsedCategoryRoles: Set<String> = FolderCategoryCollapseStore.collapsedRoleRawValues
    /// Task #52 追記: 「カテゴリ優先/アカウント優先のセグメント切替
    /// (`FolderGroupingMode`)」は廃止し、Spark と同じく1枚のリストにカテゴリ
    /// 群 (上) →アカウント群 (下、従来のアカウント優先表示の内容そのまま)を
    /// 縦に積む構成にした。カテゴリセクション自体の並び順だけがユーザーに
    /// 開放されている (`FolderCategoryOrderStore`) — `@AppStorage`で生の
    /// 文字列を直接監視するのは`FolderCategoryOrderStore.loadOrder(from:)`
    /// のdoc comment参照 (このビューは常設マウントのドロワーで再生成され
    /// ないため、設定画面での変更を反応的に拾う必要がある)。
    @AppStorage(FolderCategoryOrderStore.key) private var categoryOrderRaw = ""
    private var categoryOrder: [MailboxRoleRecord] {
        FolderCategoryOrderStore.loadOrder(from: categoryOrderRaw)
    }

    var body: some View {
        NavigationStack {
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
                    // Task #52 追記: カテゴリ群 (上) →アカウント群 (下) の
                    // 縦積み構成 — Spark のメニューと同じ (旧セグメント切替
                    // 廃止の経緯は`categoryOrder`のdoc comment参照)。
                    ForEach(categoryOrder, id: \.self) { role in
                        categorySection(for: role)
                    }
                    uncategorizedSection
                    ForEach(environment.accounts) { account in
                        accountSection(for: account)
                    }
                }
            }
            .accessibilityIdentifier("folderSheet.list")
            .scrollContentBackground(.hidden)
            .background(OtegamiColor.background)
            // 実機フィードバック: 設定ボタンはリストの最終行 (スクロールしないと
            // 見えない) ではなく、スクロール位置に関わらず常に左下に浮いている
            // フローティングボタンにする。`safeAreaInset` ではなく `overlay` を
            // 使うのは「リストの上に浮いている」見た目の指定のため — リスト末尾
            // が隠れないよう `contentMargins` で下端に余白を足す。
            .overlay(alignment: .bottomLeading) {
                floatingSettingsButton
            }
            .contentMargins(.bottom, OtegamiSpacing.xxl + OtegamiSpacing.lg, for: .scrollContent)
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
            }
        }
        .tint(OtegamiColor.accent)
        .accessibilityIdentifier("folderSheet.sheet")
        .task(id: environment.accounts.map(\.id)) { await observeOutbox() }
        .task(id: environment.accounts.map(\.id)) { await observeDraftCount() }
        .task(id: environment.accounts.map(\.id)) { await observeFailedOpCount() }
        .task(id: environment.accounts.map(\.id)) { await observeMailboxSyncFailureCount() }
        .task(id: environment.accounts.map(\.id)) { await observeUnifiedInboxUnreadCount() }
        // 画面構造改修バッチ (Task #33, 3): これまで`accountSection(for:)`の
        // `.task(id: account.id)`としてアカウント単位のSectionにぶら下がって
        // いた2つの観測を、ここへ引き上げてある — Task #52 追記でカテゴリ群/
        // アカウント群を常に両方描画する構成になった今も、`categorySection
        // (for:)`(カテゴリ群) 自体はアカウント単位のSectionを描画しない
        // (`mailboxEntries(for:)`が`mailboxesByAccountId`を横断的に読むだけ)
        // ため、この位置に置いたままにしている。
        .task(id: environment.accounts.map(\.id)) { await observeAllMailboxes() }
        .task(id: environment.accounts.map(\.id)) { await observeAllUnreadCounts() }
        // Task #73: 「開いた時は全折りたたみ＋選択中のみ展開」— ドロワーが
        // 閉→開に切り替わるたびリセットする。開いている間の手動開閉
        // (`toggleAccountCollapsed`/`toggleCategoryCollapsed`) はここでは
        // 一切妨げない (このビューは常設マウントのため、閉じている間の
        // 手動操作もそのまま次に活きてしまうが、次に開いた瞬間に必ずここで
        // 上書きされるので実害はない)。
        .onChange(of: isMenuOpen) { _, newValue in
            if newValue {
                resetCollapseStateToCurrentSelection()
            }
        }
    }

    /// Task #73: ドロワーが開かれた瞬間に呼ばれる — 現在の選択
    /// (`selectedUnifiedRole`/`selectedMailboxId`) が属するセクションだけを
    /// 展開状態にし、それ以外の全セクション (カテゴリ・アカウント両方) を
    /// 折りたたむ。`.unifiedInbox`が選択中 (どちらの入力も`nil`) の場合は
    /// 展開対象が無い = 全折りたたみになる。
    private func resetCollapseStateToCurrentSelection() {
        var expandedRoles: Set<String> = []
        var expandedAccountIds: Set<String> = []

        if let selectedUnifiedRole {
            expandedRoles.insert(selectedUnifiedRole.rawValue)
        }

        if let selectedMailboxId, let entry = accountAndMailbox(forMailboxId: selectedMailboxId) {
            expandedAccountIds.insert(entry.account.id)
            // 「該当roleのカテゴリにも属するならそちらも」— `matchesCategory`
            // は Gmail の All Mail→アーカイブ読み替え含め、実際にカテゴリ
            // セクションがこのメールボックスをどう表示するかの唯一の判定
            // 元 (`categorySection(for:)`/`uncategorizedSection`と同じ関数)
            // なので、ここでも同じ関数で判定する。
            for role in categoryOrder + [.none] where matchesCategory(mailbox: entry.mailbox, account: entry.account, role: role) {
                expandedRoles.insert(role.rawValue)
            }
        }

        let allRoleValues = Set((categoryOrder + [.none]).map(\.rawValue))
        let allAccountIds = Set(environment.accounts.map(\.id))

        withAnimation(.default) {
            collapsedCategoryRoles = allRoleValues.subtracting(expandedRoles)
            collapsedAccountIds = allAccountIds.subtracting(expandedAccountIds)
        }
        FolderCategoryCollapseStore.replaceAll(collapsedRoleRawValues: collapsedCategoryRoles)
        FolderSectionCollapseStore.replaceAll(collapsedAccountIds: collapsedAccountIds)
    }

    /// 現在選択中の`mailboxId`がどのアカウント・メールボックスのものかを
    /// `mailboxesByAccountId`から引く — `resetCollapseStateToCurrentSelection()`
    /// 専用のヘルパー。
    private func accountAndMailbox(forMailboxId mailboxId: Int64) -> (account: AccountRecord, mailbox: MailboxRecord)? {
        for account in environment.accounts {
            if let mailbox = (mailboxesByAccountId[account.id] ?? []).first(where: { $0.id == mailboxId }) {
                return (account, mailbox)
            }
        }
        return nil
    }

    private func observeAllMailboxes() async {
        await withTaskGroup(of: Void.self) { group in
            for account in environment.accounts {
                group.addTask { await observeMailboxes(accountId: account.id) }
            }
        }
    }

    private func observeAllUnreadCounts() async {
        await withTaskGroup(of: Void.self) { group in
            for account in environment.accounts {
                group.addTask { await observeUnreadCounts(accountId: account.id) }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            Button {
                onSelectUnified()
            } label: {
                HStack {
                    Label("すべての受信トレイ", systemImage: "tray.2")
                    Spacer()
                    if unifiedInboxUnread > 0 {
                        Text("\(unifiedInboxUnread)")
                            .font(OtegamiFont.badge())
                            .accessibilityIdentifier("folderSheet.unifiedInbox.unreadBadge")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(isUnifiedInboxSelected ? OtegamiColor.paleBase : nil)
            .accessibilityIdentifier("folderSheet.unifiedInbox")

            if outboxCount > 0 {
                Button {
                    onOpenOutbox()
                } label: {
                    Label("送信待ち (\(outboxCount))", systemImage: "tray.and.arrow.up")
                }
                .accessibilityIdentifier("folderSheet.outbox")
            }
            if draftCount > 0 {
                Button {
                    onOpenDrafts()
                } label: {
                    Label("下書き (\(draftCount))", systemImage: "doc")
                }
                .accessibilityIdentifier("folderSheet.drafts")
            }
            if failedOpCount > 0 {
                Button {
                    onOpenFailedOps()
                } label: {
                    Label("同期エラー (\(failedOpCount))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(OtegamiColor.destructive)
                }
                .accessibilityIdentifier("folderSheet.failedOps")
            }
            if mailboxSyncFailureCount > 0 {
                Button {
                    onOpenMailboxSyncFailures()
                } label: {
                    Label("メールボックス同期エラー (\(mailboxSyncFailureCount))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(OtegamiColor.destructive)
                }
                .accessibilityIdentifier("folderSheet.mailboxSyncFailures")
            }
        }
    }

    /// 新画面構成 (1)→実機フィードバック改: 設定はメニュー最下部の「行」では
    /// なく、スクロール位置に関わらず常に見えている左下のフローティング
    /// ボタン。丸い面 (カードと同じ radius 世界観) + 影で「浮いている」ことを
    /// 示す。accessibilityIdentifier は旧実装から据え置き (XCUITest 互換)。
    private var floatingSettingsButton: some View {
        Button {
            onOpenSettings()
        } label: {
            // アイコンのみ (実機フィードバック: 文字は不要)。VoiceOver 向けの
            // タイトルは Label が保持する — ハンバーガーの閉じるボタンと同じ
            // .iconOnly パターン。
            Label("設定", systemImage: "gearshape")
                .labelStyle(.iconOnly)
                .font(OtegamiFont.body())
                .padding(OtegamiSpacing.md + OtegamiSpacing.xs)
                .background(OtegamiColor.surface, in: Circle())
                .overlay(Circle().stroke(OtegamiColor.dividerSubtle, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.leading, OtegamiSpacing.lg)
        .padding(.bottom, OtegamiSpacing.lg)
        .accessibilityIdentifier("folderSheet.settings")
    }

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
        Section {
            if !isCollapsed {
                ForEach(mailboxesByAccountId[account.id] ?? []) { mailbox in
                    folderMailboxRow(for: mailbox, in: account)
                }
            }
        } header: {
            AccountSectionHeader(
                accountId: account.id,
                title: account.displayName,
                unreadCount: accountUnreadCount(for: account.id),
                isCollapsed: isCollapsed,
                onToggle: { toggleAccountCollapsed(account.id) }
            )
        }
    }

    /// K: the badge a collapsed account's header shows — every mailbox's
    /// unread count summed, not just the inbox's, so collapsing an account
    /// never hides unread mail the way a single-mailbox badge would.
    private func accountUnreadCount(for accountId: String) -> Int {
        (mailboxesByAccountId[accountId] ?? [])
            .compactMap(\.id)
            .reduce(0) { $0 + (unreadByMailboxId[$1] ?? 0) }
    }

    private func toggleAccountCollapsed(_ accountId: String) {
        let collapsing = !collapsedAccountIds.contains(accountId)
        withAnimation(.default) {
            if collapsing {
                collapsedAccountIds.insert(accountId)
            } else {
                collapsedAccountIds.remove(accountId)
            }
        }
        FolderSectionCollapseStore.setCollapsed(collapsing, accountId: accountId)
    }

    // MARK: - 画面構造改修バッチ (Task #33, 3): カテゴリ優先グルーピング

    /// 1 role分のセクション — 「受信トレイ/アーカイブ/送信済み/下書き/ゴミ箱等の
    /// roleごとにセクションを作り、その中に各アカウントを並べる + 横断ビュー」。
    /// どの account にも `role` のメールボックスが1つも無ければセクション自体を
    /// 出さない (空の「送信済み」セクション等が並ぶのを避ける)。
    @ViewBuilder
    private func categorySection(for role: MailboxRoleRecord) -> some View {
        let entries = mailboxEntries(for: role)
        if !entries.isEmpty {
            let isCollapsed = collapsedCategoryRoles.contains(role.rawValue)
            Section {
                if !isCollapsed {
                    // 複数アカウントが同じ role を持つ場合だけ「横断ビュー」を
                    // 出す — 1アカウントしか無ければ、直後に並ぶそのアカウント
                    // 自身の行と全く同じ中身になり冗長 (`showsAccountAccent`が
                    // `MessageListView`で同じ理由により`environment.accounts
                    // .count > 1`を要求しているのと同じ判断)。
                    if environment.accounts.count > 1 {
                        categoryUnifiedRow(for: role, entries: entries)
                    }
                    ForEach(entries) { entry in
                        categoryAccountRow(for: entry)
                    }
                }
            } header: {
                CategorySectionHeader(
                    role: role,
                    unreadCount: entries.compactMap(\.mailboxId).reduce(0) { $0 + (unreadByMailboxId[$1] ?? 0) },
                    isCollapsed: isCollapsed,
                    onToggle: { toggleCategoryCollapsed(role) }
                )
            }
        }
    }

    /// カテゴリ優先セクション内、role単位の「横断ビュー」行 —
    /// 「全アカウントの該当roleをまとめて見る」。`SidebarSelection
    /// .unifiedRole(role)`を選択する — `MessageListView`側の観測は
    /// `ThreadQuery.unifiedInboxSummariesObservation(accountIds:role:...)`
    /// (既定`role: .inbox`を一般化したもの)。
    private func categoryUnifiedRow(for role: MailboxRoleRecord, entries: [MailboxEntry]) -> some View {
        let unreadTotal = entries.compactMap(\.mailboxId).reduce(0) { $0 + (unreadByMailboxId[$1] ?? 0) }
        return Button {
            onSelectUnifiedRole(role)
        } label: {
            HStack {
                Label(String(localized: "すべての\(role.categoryDisplayName)"), systemImage: role.categorySystemImage)
                Spacer()
                if unreadTotal > 0 {
                    Text("\(unreadTotal)")
                        .font(OtegamiFont.badge())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selectedUnifiedRole == role ? OtegamiColor.paleBase : nil)
        .accessibilityIdentifier("folderSheet.category.\(role.rawValue).unified")
    }

    /// role で分類できるカテゴリセクション (受信トレイ/アーカイブ/送信済み
    /// 等) 内、1アカウントぶんの行 — Task #52, 1: Spark を参考に「アカウント
    /// の表示名 + アカウント色の縦罫」を主表示にする (`AccountColorRail`と
    /// 同じ罫線、`ThreadRowView`が1d一覧行で使っているのと同じ組み方)。
    /// フォルダ名 (`mailbox.displayPath`) 自体は表示しない — 同じカテゴリ内で
    /// は「どの役割か」はセクション見出しがすでに示しており、複数アカウントを
    /// 見分けたいだけの場面でフォルダの生パス名 (IMAP実装依存の命名, 例:
    /// "[Gmail]/All Mail") を出すのはノイズという判断。role で分類できない
    /// `.none`セクション (`uncategorizedSection`) は逆にフォルダ名こそが
    /// 差分なので、そちらは引き続き`categoryMailboxRow(for:)`
    /// (フォルダ名主表示 + アカウント名併記) を使う。
    private func categoryAccountRow(for entry: MailboxEntry) -> some View {
        let mailboxSelection = MailboxSelection(accountId: entry.account.id, mailboxId: entry.mailboxId)
        let isSelected = selectedMailboxId == entry.mailboxId
        return CategoryAccountRow(
            accountId: entry.account.id,
            mailboxPath: entry.mailbox.path,
            accountDisplayName: entry.account.displayName,
            labelColorKey: entry.account.labelColorKey,
            unreadCount: unreadByMailboxId[entry.mailboxId],
            isSelected: isSelected,
            onTap: { onSelectMailbox(mailboxSelection, entry.account.displayName) }
        )
    }

    /// role で分類**できない**メールボックス (`.none`、`uncategorizedSection`)
    /// 専用、1メールボックスぶんの行 — アカウント優先モードの
    /// `folderMailboxRow(for:in:)`と違い、複数アカウントが同じセクションに
    /// 混ざるため、どのアカウントの行かを`accountLabelText`で併記する
    /// (`FolderMailboxRow`のdoc comment参照)。role で分類できるセクション
    /// (受信トレイ/アーカイブ等) は`categoryAccountRow(for:)`を使う —
    /// 使い分けの理由はそちらのdoc comment参照。
    private func categoryMailboxRow(for entry: MailboxEntry) -> some View {
        let mailboxSelection = MailboxSelection(accountId: entry.account.id, mailboxId: entry.mailboxId)
        let isSelected = selectedMailboxId == entry.mailboxId
        return FolderMailboxRow(
            accountId: entry.account.id,
            mailbox: entry.mailbox,
            unreadCount: unreadByMailboxId[entry.mailboxId],
            isSelected: isSelected,
            accountLabelText: entry.account.displayName,
            onTap: { onSelectMailbox(mailboxSelection, entry.mailbox.displayPath) }
        )
    }

    /// role で分類できないメールボックス (`.none` — ユーザーが作成した独自
    /// フォルダ) をまとめる最終セクション。役割で束ねられないぶん「横断ビュー」
    /// は作らず (アカウントを跨いで同じ意味を持つ folder ではないため)、各
    /// アカウントの行をそのまま並べる。
    @ViewBuilder
    private var uncategorizedSection: some View {
        let entries = mailboxEntries(for: .none)
        if !entries.isEmpty {
            let isCollapsed = collapsedCategoryRoles.contains(MailboxRoleRecord.none.rawValue)
            Section {
                if !isCollapsed {
                    ForEach(entries) { entry in
                        categoryMailboxRow(for: entry)
                    }
                }
            } header: {
                CategorySectionHeader(
                    role: .none,
                    unreadCount: entries.compactMap(\.mailboxId).reduce(0) { $0 + (unreadByMailboxId[$1] ?? 0) },
                    isCollapsed: isCollapsed,
                    onToggle: { toggleCategoryCollapsed(.none) }
                )
            }
        }
    }

    /// 全アカウントを横断して`role`のメールボックスを集める — `account`ごとに
    /// 独立して保持している`mailboxesByAccountId`から、この画面のカテゴリ優先
    /// セクションが必要とする形 (どのアカウントの、どのメールボックスか) へ
    /// フラット化する。
    private func mailboxEntries(for role: MailboxRoleRecord) -> [MailboxEntry] {
        environment.accounts.flatMap { account -> [MailboxEntry] in
            (mailboxesByAccountId[account.id] ?? [])
                .filter { matchesCategory(mailbox: $0, account: account, role: role) }
                .compactMap { mailbox in
                    mailbox.id.map { MailboxEntry(account: account, mailbox: mailbox, mailboxId: $0) }
                }
        }
    }

    /// Task #52, 2: Gmail は`\Archive`special-useフォルダを持たないため、
    /// 「アーカイブ」カテゴリの実体を Gmail アカウントに限り All Mail
    /// (role`.all`)とする — メニュー表示側 (どのメールボックスを「アーカイブ」
    /// 行として出すか) のマッピング。対になる`OtegamiStore.MailboxRoleRecord
    /// .gmailArchiveQueryRole`/`GmailArchiveFilter`は、その行を実際に開いた
    /// 時のスレッド一覧側の定義 (`docs/design-system.md`記載の Gmail 検索式
    /// と等価な集合、単純な All Mail 全件ではない) を担う — 役割が違うので
    /// 別々に実装している。`MailboxRoleRecord.categoryOrder`が`.all`自体を
    /// 独立カテゴリとして持たない (`.all`を渡してこの関数が呼ばれることは
    /// 無い) ことで、Gmail の All Mail が「アーカイブ」と「すべてのメール」
    /// の2箇所に重複表示されることを避けている。
    private func matchesCategory(mailbox: MailboxRecord, account: AccountRecord, role: MailboxRoleRecord) -> Bool {
        if mailbox.role == role { return true }
        if role == .archive, mailbox.role == .all, account.kind == .gmail { return true }
        return false
    }

    private func toggleCategoryCollapsed(_ role: MailboxRoleRecord) {
        let collapsing = !collapsedCategoryRoles.contains(role.rawValue)
        withAnimation(.default) {
            if collapsing {
                collapsedCategoryRoles.insert(role.rawValue)
            } else {
                collapsedCategoryRoles.remove(role.rawValue)
            }
        }
        FolderCategoryCollapseStore.setCollapsed(collapsing, role: role)
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
                unreadCount: unreadByMailboxId[mailboxId],
                isSelected: isSelected,
                onTap: { onSelectMailbox(mailboxSelection, mailbox.displayPath) }
            )
        }
    }

    private func observeMailboxes(accountId: String) async {
        // メールボックス単位の非表示: `includeHidden: false` keeps a hidden
        // mailbox out of the hamburger tree entirely — see
        // `MailboxQuery.request(accountId:includeHidden:)`'s doc comment.
        let observation = MailboxQuery.observation(accountId: accountId, includeHidden: false)
        do {
            for try await mailboxes in observation.values(in: environment.database.dbWriter) {
                mailboxesByAccountId[accountId] = mailboxes
            }
        } catch {
            // A failing observation for one account shouldn't take down the sheet.
        }
    }

    private func observeUnreadCounts(accountId: String) async {
        let observation = MessageQuery.unreadCountsObservation(accountId: accountId)
        do {
            for try await counts in observation.values(in: environment.database.dbWriter) {
                for (mailboxId, count) in counts {
                    unreadByMailboxId[mailboxId] = count
                }
                let staleMailboxIds = (mailboxesByAccountId[accountId] ?? [])
                    .compactMap(\.id)
                    .filter { counts[$0] == nil }
                for mailboxId in staleMailboxIds {
                    unreadByMailboxId.removeValue(forKey: mailboxId)
                }
            }
        } catch {
            // A failing observation just stops that account's badges from updating.
        }
    }

    private func observeOutbox() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = OutboxQuery.observation(accountIds: accountIds)
        do {
            for try await pending in observation.values(in: environment.database.dbWriter) {
                outboxCount = pending.count
            }
        } catch {
            // A failing observation just stops the badge from updating.
        }
    }

    private func observeDraftCount() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = DraftQuery.unifiedObservation(accountIds: accountIds)
        do {
            for try await drafts in observation.values(in: environment.database.dbWriter) {
                draftCount = drafts.count
            }
        } catch {
            // A failing observation just stops the badge from updating.
        }
    }

    private func observeFailedOpCount() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = OpQueueQuery.failedOpsObservation(accountIds: accountIds, minAttempts: OpQueueProcessor.maxAttempts)
        do {
            for try await ops in observation.values(in: environment.database.dbWriter) {
                failedOpCount = ops.count
            }
        } catch {
            // A failing observation just stops the badge from updating.
        }
    }

    private func observeMailboxSyncFailureCount() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = MailboxQuery.syncFailuresObservation(accountIds: accountIds)
        do {
            for try await mailboxes in observation.values(in: environment.database.dbWriter) {
                mailboxSyncFailureCount = mailboxes.count
            }
        } catch {
            // A failing observation just stops the badge from updating.
        }
    }

    private func observeUnifiedInboxUnreadCount() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = MessageQuery.unifiedInboxUnreadCountObservation(accountIds: accountIds)
        do {
            for try await count in observation.values(in: environment.database.dbWriter) {
                unifiedInboxUnread = count
            }
        } catch {
            // A failing observation just stops the badge from updating.
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
    let title: String
    let unreadCount: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Text(title)
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
        .accessibilityIdentifier("folderSheet.account.\(accountId).header")
        // VoiceOver: the chevron's rotation alone communicates nothing to
        // VoiceOver, so the collapsed/expanded state is spelled out in the
        // trait/label instead — standard `DisclosureGroup` accessibility
        // behavior, reproduced here since this is a hand-rolled substitute.
        .accessibilityAddTraits(isCollapsed ? [] : .isSelected)
        .accessibilityValue(isCollapsed ? "折りたたみ" : "展開")
    }
}

/// Task #52, 1: one account's row inside a role-based category section
/// (`FolderListSheet.categoryAccountRow(for:)`) — `AccountColorRail` +
/// the account's display name, mirroring Spark's "アーカイブ" category
/// screenshot (色付きバー + アカウント名の並び, `docs/design-system.md`参照)
/// rather than a mailbox path. Split out of the `ForEach` closure for the
/// same CI type-check reason every other row-shaped closure in this file
/// already is (`docs/ci.md`).
private struct CategoryAccountRow: View {
    let accountId: String
    /// アクセシビリティ識別子の一意性のためだけの値 — 同じアカウントが
    /// 複数のカテゴリセクション (例: Gmail が「受信トレイ」と「アーカイブ」
    /// 両方) に現れうるので、`accountId`単独では識別子が重複する。行の
    /// マッピング元メールボックスの`path`まで含めれば一意になる
    /// (`FolderMailboxRow`の`folderSheet.mailbox.<accountId>.<path>`と同じ
    /// 発想)。
    let mailboxPath: String
    let accountDisplayName: String
    /// D「アカウントのラベル色を変更可能に」: `AccountRecord.labelColorKey`,
    /// forwarded to `AccountColorRail` as-is (`nil` = automatic FNV-1a
    /// assignment) — same as `ThreadRowView`'s own use of this field.
    let labelColorKey: String?
    let unreadCount: Int?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 0) {
                AccountColorRail(accountId: accountId, labelColorKey: labelColorKey)
                HStack {
                    // `AccountFilterChip.label`のdoc comment参照: 表示名は
                    // `LocalizedStringKey`経由に流すと(表示名がメールアドレス
                    // そのものの場合に) SwiftUIがMarkdownの自動リンクとして
                    // 解釈し、タップで`mailto:`が開く実機バグを踏む —
                    // `Text(verbatim:)`で素通しする。
                    Text(verbatim: accountDisplayName)
                    Spacer()
                    if let unreadCount, unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(OtegamiFont.badge())
                    }
                }
                .padding(.leading, OtegamiSpacing.sm)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? OtegamiColor.paleBase : nil)
        .accessibilityIdentifier("folderSheet.category.account.\(accountId).\(mailboxPath)")
    }
}

/// One mailbox row inside `FolderListSheet` — see `SidebarView.MailboxRow`'s
/// doc comment for why this is split out of the `ForEach` closure at all
/// (same CI type-check rationale, independently re-applied to this file).
private struct FolderMailboxRow: View {
    let accountId: String
    let mailbox: MailboxRecord
    let unreadCount: Int?
    let isSelected: Bool
    /// 画面構造改修バッチ (Task #33, 3): カテゴリ優先モードでは複数アカウント
    /// の行が同じセクションに混ざる (`FolderListSheet.categoryMailboxRow(for:)`)
    /// ため、どのアカウントの行かをフォルダ名の下に小さく併記する —
    /// アカウント優先モード (アカウント自身がすでにSection見出しになっている)
    /// では`nil`のまま、見た目は変わらない。
    var accountLabelText: String? = nil
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Label(mailbox.displayPath, systemImage: icon(for: mailbox.role))
                    if let accountLabelText {
                        Text(accountLabelText)
                            .font(OtegamiFont.caption())
                            .foregroundStyle(OtegamiColor.inkTertiary)
                    }
                }
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

// MARK: - 画面構造改修バッチ (Task #33, 3): カテゴリ優先グルーピング

/// `FolderSectionCollapseStore`のrole版 — カテゴリ優先モードのセクション
/// (role単位)の折りたたみ状態を、アカウント優先モードのそれとは独立して
/// 永続化する(`FolderListSheet.collapsedCategoryRoles`のdoc comment参照)。
enum FolderCategoryCollapseStore {
    static let collapsedRolesKey = "folderSheet.collapsedCategoryRoles"

    static var collapsedRoleRawValues: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedRolesKey) ?? [])
    }

    static func setCollapsed(_ collapsed: Bool, role: MailboxRoleRecord) {
        var values = collapsedRoleRawValues
        if collapsed {
            values.insert(role.rawValue)
        } else {
            values.remove(role.rawValue)
        }
        UserDefaults.standard.set(Array(values), forKey: collapsedRolesKey)
    }

    /// Task #73: `FolderSectionCollapseStore.replaceAll(collapsedAccountIds:)`
    /// と同じ理由の一括版。
    static func replaceAll(collapsedRoleRawValues: Set<String>) {
        UserDefaults.standard.set(Array(collapsedRoleRawValues), forKey: collapsedRolesKey)
    }
}

/// カテゴリ優先モードの1行ぶん — どのアカウントの、どのメールボックスか
/// (`FolderListSheet.mailboxEntries(for:)`が`mailboxesByAccountId`から
/// フラット化して作る)。`mailboxId`を`Identifiable`の`id`に使う —
/// `MailboxRecord.id`自体は`Int64?`(未保存の場合`nil`)だが、この画面が
/// 扱うのは常にDBから読み込み済みの(=idを持つ)行なので、`mailboxEntries(for:)`
/// 側で`nil`を弾いてから渡す。
private struct MailboxEntry: Identifiable {
    let account: AccountRecord
    let mailbox: MailboxRecord
    let mailboxId: Int64

    var id: Int64 { mailboxId }
}

/// `AccountSectionHeader`のrole版 — カテゴリ優先モードの1セクション見出し。
/// 「折りたたみ中も見えること」の要件は`AccountSectionHeader`と同じ理由で
/// ここでも踏襲。
private struct CategorySectionHeader: View {
    let role: MailboxRoleRecord
    let unreadCount: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Label(role.categoryDisplayName, systemImage: role.categorySystemImage)
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
        .accessibilityIdentifier("folderSheet.category.\(role.rawValue).header")
        .accessibilityAddTraits(isCollapsed ? [] : .isSelected)
        .accessibilityValue(isCollapsed ? "折りたたみ" : "展開")
    }
}
