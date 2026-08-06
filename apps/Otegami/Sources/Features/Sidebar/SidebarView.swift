import SwiftUI
import GRDB
import OtegamiStore
import SyncEngine

/// Unified inbox + account/mailbox tree, backed by live `ValueObservation`s.
/// One mailbox observation per visible account (started/stopped as accounts
/// appear — `.task(id:)` handles that automatically).
///
/// Task #181 (実機フィードバック「macOS のサイドバーにも iOS と同じ統合
/// フォルダのグルーピングが欲しい」): macOS では本文が `#if os(macOS)` の
/// 専用ブランチを持ち、iOS の `FolderListSheet` と同じカテゴリ優先グルー
/// ピング (受信トレイ/アーカイブ/送信済み等の role ごとのセクション、開くと
/// アカウント別に分かれる) を、`List` + `DisclosureGroup` という macOS
/// ネイティブな見せ方で描く。カテゴリの定義・重複排除・Gmail アーカイブ
/// 特例は `FolderListSheet` と共有 (`MailboxCategoryGrouping`、
/// `Support/MailboxCategoryEntries.swift`) — 複製していない。トップの
/// "すべての受信トレイ" 単独行 (M4) は macOS では廃止し、「受信トレイ」
/// カテゴリの見出し (`categoryOrder`の先頭) がタップでその選択を兼ねる
/// (iOS の `FolderListSheet` が Task #126 で行った統合と同じ判断)。iOS
/// (`#else`分岐) は旧来どおり — この型自体は `OtegamiApp.swift.RootView`
/// の macOS 専用 `NavigationSplitView` からしか実際には描画されない
/// (`OtegamiRootView`の doc comment参照) が、明示的に `#if os(macOS)` で
/// 分岐しておくことで「iOS の挙動は変えない」という要件をソース上でも
/// 保証する。
struct SidebarView: View {
    @Environment(AppEnvironment.self) private var environment
    #if os(macOS)
    /// 2026-08-07: 歯車ボタン → ネイティブ設定ウィンドウ (`openSettings()`
    /// の doc comment 参照)。
    @Environment(\.openWindow) private var openWindow
    #endif
    @Binding var selection: SidebarSelection?
    /// Called whenever a row's own `Button` action is tapped (unified inbox
    /// or a specific mailbox) — *in addition to* writing `selection`
    /// directly, not instead of it. `RootView` uses this to unconditionally
    /// push `preferredCompactColumn` forward to `.content` on every tap,
    /// deliberately not gated on whether `selection`'s value actually
    /// changed. That distinction matters for a real bug (docs/verify.md,
    /// "「直前に選択していた行」だけタップ不能"): re-tapping the *same* row
    /// after popping back via the system back button (e.g. unified inbox →
    /// back → unified inbox again) leaves `selection` unchanged, so an
    /// `onChange(of: selection)`-driven push never fires a second time —
    /// this callback fires on every tap regardless, so `RootView` can
    /// always force the column forward. See also `MessageListView
    /// .onThreadSelected`, which needs the identical treatment for its own
    /// selection.
    var onSelected: (SidebarSelection) -> Void = { _ in }
    /// M5: opens `ComposerView` for a brand-new message — presentation
    /// itself (sheet on iOS, a separate window on macOS) is `RootView`'s
    /// job, since it's the common ancestor of both the sidebar's "作成"
    /// button and `ThreadDetailView`'s "返信"/"全員に返信" buttons.
    var onCompose: () -> Void = {}
    /// M10: resumes a saved draft — see `DraftsView`'s doc comment for why
    /// this is a callback owned by `RootView` rather than something
    /// `DraftsView` presents itself.
    var onOpenDraft: (Int64) -> Void = { _ in }
    /// Drafts IMAP sync: resumes a server-origin draft (`DraftQuery
    /// .UnifiedRow.server`) — same rationale as `onOpenDraft`.
    var onOpenServerDraft: (Int64) -> Void = { _ in }

    /// M6: drives the whole add-account flow (type picker → the chosen
    /// form) as a single `.sheet(item:)` — see `AccountEntryRoute`'s doc
    /// comment for why a route enum rather than a `Bool`.
    @State private var accountEntryRoute: AccountEntryRoute?
    @State private var showingSettings = false
    @State private var showingOutbox = false
    @State private var showingDrafts = false
    @State private var showingFailedOps = false
    /// The mailbox tree + badge counts this view shows — see
    /// `MailboxCountsObserver`'s doc comment for why the observation logic
    /// itself lives there rather than directly in this view (shared with
    /// `FolderListSheet`, which owns its own separate instance).
    @State private var countsObserver = MailboxCountsObserver()

    #if os(macOS)
    /// Task #181: どのカテゴリ (role) セクションが折りたたまれているか —
    /// `FolderListSheet.collapsedCategoryRoles`と同じ発想だが、永続キーは
    /// 別 (`SidebarCategoryCollapseStore`)。ここでは保存されていた最後の
    /// 開閉状態をひとまず復元する (デフォルト = 全展開) が、初期値のまま
    /// 使われることは無い — `body`の`.task(id:)`が表示直後に
    /// `normalizeCollapseStateToSingleExpansion()`を一度呼び、Task #195
    /// (「常に1つだけ開く」) の要件に沿って最大1セクションへ正規化する。
    /// 以降の手動開閉は`macCategoryExpandedBinding(for:)`/
    /// `macAccountExpandedBinding(for:)`の排他ロジックが担う。
    @State private var collapsedCategoryRoles: Set<String> = SidebarCategoryCollapseStore.collapsedRoleRawValues
    /// Task #181: `collapsedCategoryRoles`のアカウント別ツリー版 —
    /// `FolderListSheet.collapsedAccountIds`と同じ発想、永続キーは別
    /// (`SidebarAccountCollapseStore`)。
    @State private var collapsedAccountIds: Set<String> = SidebarAccountCollapseStore.collapsedAccountIds
    /// カテゴリセクションの並び順 — 設定画面 (`FolderCategoryOrderSettingsView`)
    /// で変更できる、iOS のハンバーガーメニューと共有の永続設定
    /// (`FolderCategoryOrderStore`) をそのまま使う。同じアカウント構成に
    /// 対する「見せ方の好み」なので、プラットフォームごとに別の順序を
    /// 持たせる理由が無いと判断した。`FolderListSheet`と同じ理由
    /// (`@AppStorage`で生の文字列を直接監視することで、常設マウントの
    /// このビューも設定変更に反応的に追従する) で`@AppStorage`を直接使う。
    @AppStorage(FolderCategoryOrderStore.key) private var categoryOrderRaw = ""
    private var categoryOrder: [MailboxRoleRecord] {
        FolderCategoryOrderStore.loadOrder(from: categoryOrderRaw)
    }
    /// Task #195 (実機フィードバック「mac 版でも iOS と同じようにハンバー
    /// ガーメニューが一つしか開かないようにしてほしい」): `.task(id:)`の
    /// ガードに使う一度きりのフラグ — `normalizeCollapseStateToSingleExpansion()`
    /// をアカウント一覧が最初に埋まったタイミングで一度だけ走らせる
    /// (`body`のコメント参照)。
    @State private var hasNormalizedInitialCollapseState = false
    #endif

    var body: some View {
        sidebarList
            .modifier(
                SidebarSheetPresentationModifier(
                    accountEntryRoute: $accountEntryRoute,
                    showingSettings: $showingSettings,
                    showingOutbox: $showingOutbox,
                    showingDrafts: $showingDrafts,
                    showingFailedOps: $showingFailedOps,
                    onOpenDraft: onOpenDraft,
                    onOpenServerDraft: onOpenServerDraft
                )
            )
            .task(id: environment.accounts.map(\.id)) {
                await countsObserver.observeOutbox(accountIds: environment.accounts.map(\.id), dbWriter: environment.database.dbWriter)
            }
            .task(id: environment.accounts.map(\.id)) {
                await countsObserver.observeDraftCount(accountIds: environment.accounts.map(\.id), dbWriter: environment.database.dbWriter)
            }
            .task(id: environment.accounts.map(\.id)) {
                await countsObserver.observeFailedOpCount(accountIds: environment.accounts.map(\.id), dbWriter: environment.database.dbWriter)
            }
            .task(id: environment.accounts.map(\.id)) {
                await countsObserver.observeUnifiedInboxUnreadCount(accountIds: environment.accounts.map(\.id), dbWriter: environment.database.dbWriter)
            }
            #if os(macOS)
            .task(id: selection) { normalizeInitialCollapseStateIfNeeded() }
            #endif
    }

    /// A plain `List`, not `List(selection:)` — selection is driven
    /// explicitly by each row's own `Button` action, the same pattern
    /// `MessageListView` already uses. `List(selection:)` is independently
    /// documented as flaky in this project's simulator/toolchain (M2's
    /// pitfall #2, `.claude/skills/verify/SKILL.md`): tapping a tagged row
    /// made `selection` oscillate through `nil` and back, repeatedly tearing
    /// down `MessageListView` before its first observation completed.
    private var sidebarList: some View {
        List {
            sidebarListContent
        }
        .accessibilityIdentifier("sidebar.list")
        .navigationTitle("Otegami")
        // 2026-08-07 (メイン UI の macOS ネイティブ化、実機フィードバック
        // 「設定画面以外の UI も mac ネイティブに」): macOS は独自の背景
        // 塗り・アクセント tint を外し、標準のサイドバー素材 (vibrancy
        // ベースの半透明) に任せる — 不透明なネイビー一色のサイドバーが
        // 「iOS アプリの移植」に見える最大の要因だった。iOS は従来どおり。
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
        #endif
        .toolbar {
            SidebarToolbarContent(
                isComposeDisabled: environment.accounts.isEmpty,
                onCompose: onCompose,
                onAddAccount: beginAccountEntry,
                onOpenSettings: openSettings
            )
        }
    }

    @ViewBuilder
    private var sidebarListContent: some View {
        if environment.accounts.isEmpty {
            SidebarEmptyAccountsView(onAddAccount: beginAccountEntry)
        } else {
            Section {
                #if os(iOS)
                SidebarUnifiedInboxRow(
                    isSelected: selection == .unifiedInbox,
                    unreadCount: countsObserver.unifiedInboxUnread,
                    onTap: selectUnifiedInbox
                )
                #endif

                if countsObserver.outboxCount > 0 {
                    SidebarStatusRow(
                        title: "送信待ち (\(countsObserver.outboxCount))",
                        systemImage: "tray.and.arrow.up",
                        accessibilityIdentifier: "sidebar.outbox",
                        isError: false,
                        onTap: openOutbox
                    )
                }
                if countsObserver.draftCount > 0 {
                    SidebarStatusRow(
                        title: "下書き (\(countsObserver.draftCount))",
                        systemImage: "doc",
                        accessibilityIdentifier: "sidebar.drafts",
                        isError: false,
                        onTap: openDrafts
                    )
                }
                if countsObserver.failedOpCount > 0 {
                    SidebarStatusRow(
                        title: "同期エラー (\(countsObserver.failedOpCount))",
                        systemImage: "exclamationmark.triangle",
                        accessibilityIdentifier: "sidebar.failedOps",
                        isError: true,
                        onTap: openFailedOps
                    )
                }
            }

            #if os(macOS)
            ForEach(categoryOrder, id: \.self) { role in
                macCategorySection(for: role)
            }
            #endif

            ForEach(environment.accounts) { account in
                accountSection(for: account)
            }
        }
    }

    @ViewBuilder
    private func accountSection(for account: AccountRecord) -> some View {
        #if os(macOS)
        macAccountSection(for: account)
        #else
        Section(account.displayName) {
            ForEach(countsObserver.mailboxesByAccountId[account.id] ?? []) { mailbox in
                mailboxRow(for: mailbox, in: account)
            }
        }
        .task(id: account.id) {
            await observeMailboxes(accountId: account.id)
        }
        .task(id: account.id) {
            await countsObserver.observeUnreadCounts(accountId: account.id, dbWriter: environment.database.dbWriter)
        }
        #endif
    }

    private func beginAccountEntry() {
        accountEntryRoute = .typeSelection
    }

    private func selectUnifiedInbox() {
        selection = .unifiedInbox
        onSelected(.unifiedInbox)
    }

    private func openSettings() {
        #if os(macOS)
        // 2026-08-07 (macOS 設定画面ネイティブ化): 歯車ボタンからも ⌘, と
        // 同じネイティブ設定ウィンドウ (`OtegamiApp`の`Window(id:
        // "settings")`) を開く — 以前はここだけ iOS 由来の
        // `AccountsSettingsView`シートを開いていて、⌘, の設定ウィンドウと
        // 見た目も構成も違う「もう1つの設定画面」が存在していた。
        openWindow(id: "settings")
        #else
        showingSettings = true
        #endif
    }

    private func openOutbox() {
        showingOutbox = true
    }

    private func openDrafts() {
        showingDrafts = true
    }

    private func openFailedOps() {
        showingFailedOps = true
    }

    #if os(macOS)
    /// Task #195: normalize only after `selection` changes from `nil`.
    /// Using the initially-empty account list as the task id previously
    /// marked normalization complete before all account ids were known,
    /// leaving later-loaded account sections expanded indefinitely.
    private func normalizeInitialCollapseStateIfNeeded() {
        guard !hasNormalizedInitialCollapseState, selection != nil else { return }
        hasNormalizedInitialCollapseState = true
        normalizeCollapseStateToSingleExpansion()
    }
    #endif

    /// Builds one `MailboxRow` for the inner `ForEach` in `accountSection`,
    /// pulled out into its own `@ViewBuilder` method (not just an inline closure
    /// body) so the `ForEach(mailboxesByAccountId[account.id] ?? []) {
    /// mailbox in ... }` closure in `accountSection` is a single trivial function
    /// call rather than an `if let` binding plus a multi-argument
    /// initializer call with an inline trailing closure. Splitting
    /// `SidebarView`/`MailboxRow` alone (this file's earlier fix) still
    /// left `body`'s `ForEach` closure itself too large to type-check in
    /// reasonable time on CI's toolchain (`docs/ci.md`'s troubleshooting
    /// notes: this reproduced even after that first fix, and even though
    /// it type-checked in well under CI's diagnostic threshold on a local
    /// machine — CI's older Xcode/Swift toolchain hit the same expression
    /// harder than a newer local one did, so "fast machine, low ms
    /// locally" wasn't sufficient signal on its own here). `onTap` binds
    /// `handleMailboxSelected` by reference instead of an inline closure
    /// literal for the same reason: a named function reference needs no
    /// closure-literal type inference at the call site.
    @ViewBuilder
    private func mailboxRow(for mailbox: MailboxRecord, in account: AccountRecord) -> some View {
        if let mailboxId = mailbox.id {
            let mailboxSelection = SidebarSelection.mailbox(MailboxSelection(accountId: account.id, mailboxId: mailboxId))
            let isSelected = selection == mailboxSelection
            let unreadCount = countsObserver.unreadByMailboxId[mailboxId]
            MailboxRow(
                accountId: account.id,
                mailbox: mailbox,
                mailboxId: mailboxId,
                isSelected: isSelected,
                unreadCount: unreadCount,
                onTap: handleMailboxSelected
            )
        }
    }

    /// `MailboxRow.onTap`'s target — writes `selection` and forwards to
    /// `onSelected`, the same two steps the inline closure this replaced
    /// used to do directly (`mailboxRow(for:in:)`'s doc comment for why a
    /// named method rather than a closure literal).
    private func handleMailboxSelected(_ newSelection: SidebarSelection) {
        selection = newSelection
        onSelected(newSelection)
    }

    // MARK: - Task #181: macOS のカテゴリ優先グルーピング

    #if os(macOS)
    /// 1 role分のセクション — `FolderListSheet.categorySection(for:)`の
    /// macOS版。見出し (`macCategoryHeaderLabel(for:entries:)`) 自身が
    /// タップで統合ビュー選択を兼ね、`DisclosureGroup`のネイティブな
    /// 三角形が展開/折りたたみだけを担う (iOS のように見出しとシェブロンを
    /// 別ボタンへ手動で分割する必要が macOS の`DisclosureGroup`には無い)。
    /// どの account にも`role`のメールボックスが1つも無ければセクション
    /// 自体を出さない (`.all`だけは例外 — `FolderListSheet`と同じ理由、
    /// `MailboxCategoryGrouping`のdoc comment参照)。
    @ViewBuilder
    private func macCategorySection(for role: MailboxRoleRecord) -> some View {
        let entries = MailboxCategoryGrouping.entries(for: role, accounts: environment.accounts, mailboxesByAccountId: countsObserver.mailboxesByAccountId)
        if !entries.isEmpty || role == .all {
            DisclosureGroup(isExpanded: macCategoryExpandedBinding(for: role)) {
                ForEach(entries) { entry in
                    macCategoryAccountRow(for: entry)
                }
            } label: {
                macCategoryHeaderLabel(for: role, entries: entries)
            }
            .listRowBackground(isCategorySelected(role) ? OtegamiColor.paleBase : nil)
        }
    }

    /// カテゴリ見出しのラベル内容 — role名 + アイコン + 未読バッジ、タップで
    /// 統合ビュー選択 (`handleMailboxSelected(_:)`、`.inbox`だけ`.unifiedInbox`
    /// でそれ以外は`.unifiedRole(role)`、`FolderListSheet.selectUnifiedView
    /// (for:)`と同じ判断)。
    private func macCategoryHeaderLabel(for role: MailboxRoleRecord, entries: [MailboxCategoryEntry]) -> some View {
        Button {
            handleMailboxSelected(role == .inbox ? .unifiedInbox : .unifiedRole(role))
        } label: {
            HStack {
                Label(role.categoryDisplayName, systemImage: role.categorySystemImage)
                Spacer()
                let unread = macCategoryUnreadCount(for: role, entries: entries)
                if unread > 0 {
                    UnreadCountBadge(count: unread)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.category.\(role.rawValue).header")
    }

    /// `.inbox`は`unifiedInboxUnread`(メールボックス単位の合算とは別の、
    /// 統合受信トレイ自身の未読数)、`.all`は`MailboxCategoryGrouping
    /// .unreadCountForAllMailCategory(_:)`(Gmail以外のアカウント分も含む
    /// 特別な集計)、それ以外は`entries`のメールボックス単位の合算 —
    /// `FolderListSheet.categorySection(for:)`の未読集計と同じ判断。
    private func macCategoryUnreadCount(for role: MailboxRoleRecord, entries: [MailboxCategoryEntry]) -> Int {
        switch role {
        case .inbox:
            countsObserver.unifiedInboxUnread
        case .all:
            MailboxCategoryGrouping.unreadCountForAllMailCategory(
                entries: entries, accounts: environment.accounts,
                mailboxesByAccountId: countsObserver.mailboxesByAccountId, unreadByMailboxId: countsObserver.unreadByMailboxId
            )
        default:
            entries.reduce(0) { $0 + (countsObserver.unreadByMailboxId[$1.mailboxId] ?? 0) }
        }
    }

    private func isCategorySelected(_ role: MailboxRoleRecord) -> Bool {
        if role == .inbox, selection == .unifiedInbox { return true }
        if case .unifiedRole(let selectedRole) = selection { return selectedRole == role }
        return false
    }

    /// 1カテゴリ内、1アカウントぶんの行 — `FolderListSheet.CategoryAccountRow`
    /// の macOS版 (`AccountColorRail`を同じく再利用)。フォルダ名自体は出さ
    /// ない (同じ理由、`FolderListSheet.categoryAccountRow(for:)`のdoc
    /// comment参照)。
    private func macCategoryAccountRow(for entry: MailboxCategoryEntry) -> some View {
        let mailboxSelection = SidebarSelection.mailbox(MailboxSelection(accountId: entry.account.id, mailboxId: entry.mailboxId))
        let isSelected = selection == mailboxSelection
        return Button {
            handleMailboxSelected(mailboxSelection)
        } label: {
            HStack(spacing: 0) {
                AccountColorRail(accountId: entry.account.id, labelColorKey: entry.account.labelColorKey)
                HStack {
                    Text(verbatim: entry.account.displayName)
                    Spacer()
                    if let count = countsObserver.unreadByMailboxId[entry.mailboxId], count > 0 {
                        UnreadCountBadge(count: count)
                    }
                }
                .padding(.leading, OtegamiSpacing.sm)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? OtegamiColor.paleBase : nil)
        .accessibilityIdentifier("sidebar.category.account.\(entry.account.id).\(entry.mailbox.path)")
    }

    /// アカウント別ツリー1本ぶん — 既存の`Section(account.displayName)`を
    /// `DisclosureGroup`に置き換え、折りたたみ (`collapsedAccountIds`) を
    /// 追加しただけで、中身 (`mailboxRow(for:in:)`) 自体・観測タスクの
    /// アタッチ先は無変更。
    @ViewBuilder
    private func macAccountSection(for account: AccountRecord) -> some View {
        DisclosureGroup(isExpanded: macAccountExpandedBinding(for: account.id)) {
            ForEach(countsObserver.mailboxesByAccountId[account.id] ?? []) { mailbox in
                mailboxRow(for: mailbox, in: account)
            }
        } label: {
            Text(verbatim: account.displayName)
        }
        .task(id: account.id) {
            await observeMailboxes(accountId: account.id)
        }
        .task(id: account.id) {
            await countsObserver.observeUnreadCounts(accountId: account.id, dbWriter: environment.database.dbWriter)
        }
    }

    /// Task #195: 開く方 (`isExpanded == true`) は`expandOnlyCategory(_:)`
    /// に委譲して他の全セクション (カテゴリ・アカウント両方) を閉じる —
    /// 「常に1つだけ」を保つのはここ (と`macAccountExpandedBinding`) の
    /// 排他ロジックだけで、閉じる方 (`isExpanded == false`) は単純に自分
    /// だけを畳む (誰も開いていない状態を許す — 「最大1つ」であって
    /// 「必ず1つ」ではない)。
    private func macCategoryExpandedBinding(for role: MailboxRoleRecord) -> Binding<Bool> {
        Binding(
            get: { !collapsedCategoryRoles.contains(role.rawValue) },
            set: { isExpanded in
                if isExpanded {
                    expandOnlyCategory(role)
                } else {
                    collapsedCategoryRoles.insert(role.rawValue)
                    SidebarCategoryCollapseStore.replaceAll(collapsedCategoryRoles)
                }
            }
        )
    }

    /// `macCategoryExpandedBinding(for:)`のアカウント版 —
    /// `expandOnlyAccount(_:)`に委譲する対称的な実装。
    private func macAccountExpandedBinding(for accountId: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedAccountIds.contains(accountId) },
            set: { isExpanded in
                if isExpanded {
                    expandOnlyAccount(accountId)
                } else {
                    collapsedAccountIds.insert(accountId)
                    SidebarAccountCollapseStore.replaceAll(collapsedAccountIds)
                }
            }
        )
    }

    /// Task #195: `role`のカテゴリセクションだけを展開し、それ以外の全
    /// カテゴリ・全アカウントセクションを畳む — `FolderListSheet
    /// .resetCollapseStateToCurrentSelection()`と同じ「1つだけ展開」の
    /// 考え方を、macOS では手動タップのたびに (iOS の「ドロワーを開く」に
    /// 相当する契機がここには無いため) 適用する。
    private func expandOnlyCategory(_ role: MailboxRoleRecord) {
        let allRoleValues = Set(categoryOrder.map(\.rawValue))
        let allAccountIds = Set(environment.accounts.map(\.id))
        withAnimation(.default) {
            collapsedCategoryRoles = allRoleValues.subtracting([role.rawValue])
            collapsedAccountIds = allAccountIds
        }
        SidebarCategoryCollapseStore.replaceAll(collapsedCategoryRoles)
        SidebarAccountCollapseStore.replaceAll(collapsedAccountIds)
    }

    /// `expandOnlyCategory(_:)`のアカウント版。
    private func expandOnlyAccount(_ accountId: String) {
        let allRoleValues = Set(categoryOrder.map(\.rawValue))
        let allAccountIds = Set(environment.accounts.map(\.id))
        withAnimation(.default) {
            collapsedCategoryRoles = allRoleValues
            collapsedAccountIds = allAccountIds.subtracting([accountId])
        }
        SidebarCategoryCollapseStore.replaceAll(collapsedCategoryRoles)
        SidebarAccountCollapseStore.replaceAll(collapsedAccountIds)
    }

    /// 現在の`selection`が属するカテゴリ (role) — `.unifiedInbox`は
    /// `.inbox`として扱う (`FolderListSheet.selectUnifiedView(for:)`と同じ
    /// 対応)。`normalizeCollapseStateToSingleExpansion()`専用。
    private var selectedCategoryRole: MailboxRoleRecord? {
        switch selection {
        case .unifiedInbox: .inbox
        case .unifiedRole(let role): role
        case .mailbox, nil: nil
        }
    }

    /// 現在の`selection`が特定のメールボックスなら、そのアカウントID。
    /// `normalizeCollapseStateToSingleExpansion()`専用。
    private var selectedAccountId: String? {
        if case .mailbox(let mailboxSelection) = selection { return mailboxSelection.accountId }
        return nil
    }

    /// Task #195: このビューが最初に実質表示されたタイミングで一度だけ
    /// 呼ばれ、保存されていた展開状態を「最大1つ」に正規化する
    /// (`body`の`.task(id:)`のコメント参照)。現在の選択があればそれに
    /// 対応するセクションを開き (`FolderListSheet`のリセットと同じ判断)、
    /// 選択がまだ無ければ (アカウント一覧が埋まった直後で`observeMailboxes
    /// (accountId:)`がまだ`.unifiedInbox`を確定させていない一瞬) 何も開か
    /// ずに畳むだけにする — この関数以前の保存値 (Task #195 以前は複数
    /// 同時展開が可能だった) が複数展開を含んでいても矛盾なく収束する。
    private func normalizeCollapseStateToSingleExpansion() {
        if let role = selectedCategoryRole {
            expandOnlyCategory(role)
        } else if let accountId = selectedAccountId {
            expandOnlyAccount(accountId)
        } else {
            let allRoleValues = Set(categoryOrder.map(\.rawValue))
            let allAccountIds = Set(environment.accounts.map(\.id))
            collapsedCategoryRoles = allRoleValues
            collapsedAccountIds = allAccountIds
            SidebarCategoryCollapseStore.replaceAll(collapsedCategoryRoles)
            SidebarAccountCollapseStore.replaceAll(collapsedAccountIds)
        }
    }
    #endif

    /// Runs for as long as `SidebarView` shows `accountId`'s section
    /// (cancelled automatically by `.task(id:)` when the account
    /// disappears from the list) — thin wrapper over `MailboxCountsObserver
    /// .observeMailboxes(accountId:dbWriter:onMailboxesLoaded:)` that
    /// supplies the one bit of behavior specific to this view: claiming
    /// "すべての受信トレイ" as the *data* selection the first time any
    /// account's mailboxes appear (M4) — so the content column is ready to
    /// show a populated, threaded list the instant the user does navigate
    /// into it. See `MailboxCountsObserver.observeMailboxes(...)`'s doc
    /// comment for the full rationale (including why this deliberately
    /// does **not** also navigate there) — preserved there since
    /// `FolderListSheet` calls the same observer method without this
    /// closure and has none of this behavior.
    private func observeMailboxes(accountId: String) async {
        await countsObserver.observeMailboxes(accountId: accountId, dbWriter: environment.database.dbWriter) {
            if selection == nil {
                selection = .unifiedInbox
            }
        }
    }

}

#if os(macOS)
// MARK: - Task #181: macOS サイドバーの折りたたみ状態の永続化

/// `FolderListSheet.FolderCategoryCollapseStore`のmacOSサイドバー版 —
/// 同じ役割 (role単位の折りたたみ) だが、iOS のドロワーとは開閉の意味付け
/// (常設 vs. 開くたびリセット) が違うため、永続キーは独立させている
/// (`SidebarView`のdoc comment参照)。
enum SidebarCategoryCollapseStore {
    static let key = "sidebar.mac.collapsedCategoryRoles"

    static var collapsedRoleRawValues: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func replaceAll(_ collapsedRoleRawValues: Set<String>) {
        UserDefaults.standard.set(Array(collapsedRoleRawValues), forKey: key)
    }
}

/// `FolderListSheet.FolderSectionCollapseStore`のmacOSサイドバー版 — 同じ
/// 理由で永続キーを独立させている。
enum SidebarAccountCollapseStore {
    static let key = "sidebar.mac.collapsedAccountIds"

    static var collapsedAccountIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func replaceAll(_ collapsedAccountIds: Set<String>) {
        UserDefaults.standard.set(Array(collapsedAccountIds), forKey: key)
    }
}
#endif
