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
    @State private var showingMailboxSyncFailures = false
    @State private var mailboxesByAccountId: [String: [MailboxRecord]] = [:]
    @State private var outboxCount = 0
    @State private var draftCount = 0
    @State private var failedOpCount = 0
    @State private var mailboxSyncFailureCount = 0
    // M10: unread badges. `unreadByMailboxId` groups by mailbox id (spans
    // every account — a plain `[Int64: Int]` is enough since `MailboxRecord
    // .id` is a global autoincrement primary key, not scoped per account).
    // `unifiedInboxUnread` is its own separately-observed total rather than
    // derived by summing `unreadByMailboxId` client-side, since it's scoped
    // to inbox-role mailboxes only (`MessageQuery.unifiedInboxUnreadCount`'s
    // doc comment) — deriving it here would need this view to also know
    // each mailbox's role, duplicating logic the query already encodes.
    @State private var unreadByMailboxId: [Int64: Int] = [:]
    @State private var unifiedInboxUnread = 0

    #if os(macOS)
    /// Task #181: どのカテゴリ (role) セクションが折りたたまれているか —
    /// `FolderListSheet.collapsedCategoryRoles`と同じ発想だが、永続キーは
    /// 別 (`SidebarCategoryCollapseStore`)。iOS のドロワーは開くたびに
    /// 「選択中のセクションだけ展開」へリセットする特別な挙動を持つ
    /// (`FolderListSheet.resetCollapseStateToCurrentSelection()`) が、この
    /// サイドバーは常設表示でその種のリセット契機が無いため、単純に
    /// ユーザーの最後の開閉状態をそのまま復元する。デフォルト (未設定) は
    /// 全展開 — 追加前は折りたたみという概念自体が無く常に全部見えていた
    /// ので、既定値を「全展開」にすることで既存ユーザーの見え方を後退
    /// させない。
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
    #endif

    var body: some View {
        // A plain `List`, not `List(selection:)` — selection is driven
        // explicitly by each row's own `Button` action below, the same
        // pattern `MessageListView` already uses (its own doc comment: "By
        // id... Set directly from a `Button` action per row"). This isn't
        // stylistic parity for its own sake: `List(selection:)`'s binding
        // is independently documented as flaky in this project's
        // simulator/toolchain (M2's pitfall #2, `.claude/skills/verify/
        // SKILL.md`) — a real-device investigation (docs/verify.md) traced
        // an "sidebar → INBOX をタップすると一覧に何も出ない" bug all the way
        // down to this: tapping a `List(selection:)`-tagged row here made
        // `selection` oscillate through `nil` and back rather than
        // settling once, which tore `MessageListView` down and rebuilt it
        // (confirmed via a `CancellationError` on an in-flight database
        // read, mid-rebuild) faster than its very first `ValueObservation`
        // fetch could ever complete — a livelock, not a one-time glitch,
        // that never resolved on its own. `List(selection:)` was
        // previously *this* view's only remaining use of the pattern
        // `MessageListView` had already worked around for the exact same
        // reason.
        List {
            if environment.accounts.isEmpty {
                ContentUnavailableView {
                    Label("アカウントがありません", systemImage: "envelope.badge")
                } description: {
                    Text("メールアカウントを追加してください。")
                } actions: {
                    Button("アカウントを追加") { accountEntryRoute = .typeSelection }
                        .accessibilityIdentifier("sidebar.addAccountButton")
                }
            } else {
                Section {
                    // Task #181: macOS はこの単独行を廃止し、下の「受信トレイ」
                    // カテゴリ見出し (`categoryOrder`の先頭、`macCategorySection
                    // (for: .inbox)`) がタップで全く同じ選択を兼ねる — iOS の
                    // `FolderListSheet`が Task #126 で行った統合と同じ判断
                    // (重複した入口を残さない)。iOS (この`#if`の対象ではない、
                    // 実際には未到達コード — 型doc comment参照) はこの単独行を
                    // 引き続き持つ。
                    #if os(iOS)
                    Button {
                        selection = .unifiedInbox
                        onSelected(.unifiedInbox)
                    } label: {
                        HStack {
                            Label("すべての受信トレイ", systemImage: "tray.2")
                            Spacer()
                            if unifiedInboxUnread > 0 {
                                UnreadCountBadge(count: unifiedInboxUnread)
                                    .accessibilityIdentifier("sidebar.unifiedInbox.unreadBadge")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selection == .unifiedInbox ? OtegamiColor.paleBase : nil)
                    .accessibilityIdentifier("sidebar.unifiedInbox")
                    #endif

                    if outboxCount > 0 {
                        Button {
                            showingOutbox = true
                        } label: {
                            Label("送信待ち (\(outboxCount))", systemImage: "tray.and.arrow.up")
                        }
                        .accessibilityIdentifier("sidebar.outbox")
                    }

                    if draftCount > 0 {
                        Button {
                            showingDrafts = true
                        } label: {
                            Label("下書き (\(draftCount))", systemImage: "doc")
                        }
                        .accessibilityIdentifier("sidebar.drafts")
                    }

                    if failedOpCount > 0 {
                        Button {
                            showingFailedOps = true
                        } label: {
                            Label("同期エラー (\(failedOpCount))", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        .accessibilityIdentifier("sidebar.failedOps")
                    }

                    if mailboxSyncFailureCount > 0 {
                        Button {
                            showingMailboxSyncFailures = true
                        } label: {
                            Label("メールボックス同期エラー (\(mailboxSyncFailureCount))", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        .accessibilityIdentifier("sidebar.mailboxSyncFailures")
                    }
                }

                // Task #181: macOS はカテゴリセクション (受信トレイ/アーカイブ/
                // 送信済み等、`FolderListSheet`と共通の`categoryOrder`) を
                // アカウント別ツリーの**上**に積む — iOS の `FolderListSheet`
                // が Task #52 追記で確立した「カテゴリ群 (上) → アカウント群
                // (下)」の縦積み構成と同じ並びにする。
                #if os(macOS)
                ForEach(categoryOrder, id: \.self) { role in
                    macCategorySection(for: role)
                }
                #endif

                ForEach(environment.accounts) { account in
                    #if os(macOS)
                    macAccountSection(for: account)
                    #else
                    Section(account.displayName) {
                        ForEach(mailboxesByAccountId[account.id] ?? []) { mailbox in
                            mailboxRow(for: mailbox, in: account)
                        }
                    }
                    .task(id: account.id) {
                        await observeMailboxes(accountId: account.id)
                    }
                    .task(id: account.id) {
                        await observeUnreadCounts(accountId: account.id)
                    }
                    #endif
                }
            }
        }
        .accessibilityIdentifier("sidebar.list")
        .navigationTitle("Otegami")
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
        .toolbar {
            ToolbarItem {
                Button {
                    onCompose()
                } label: {
                    Label("作成", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("sidebar.composeButton")
                .disabled(environment.accounts.isEmpty)
            }
            ToolbarItem {
                Button {
                    accountEntryRoute = .typeSelection
                } label: {
                    Label("アカウントを追加", systemImage: "plus")
                }
                .accessibilityIdentifier("sidebar.addAccountToolbarButton")
            }
            ToolbarItem {
                Button {
                    showingSettings = true
                } label: {
                    Label("設定", systemImage: "gearshape")
                }
                .accessibilityIdentifier("sidebar.settingsButton")
            }
        }
        .sheet(item: $accountEntryRoute) { route in
            accountEntryDestination(for: route, binding: $accountEntryRoute)
        }
        .sheet(isPresented: $showingSettings) {
            AccountsSettingsView()
        }
        .sheet(isPresented: $showingOutbox) {
            OutboxView()
        }
        .sheet(isPresented: $showingDrafts) {
            DraftsView(onOpenDraft: onOpenDraft, onOpenServerDraft: onOpenServerDraft)
        }
        .sheet(isPresented: $showingFailedOps) {
            FailedOperationsView()
        }
        .sheet(isPresented: $showingMailboxSyncFailures) {
            MailboxSyncFailuresView()
        }
        .task(id: environment.accounts.map(\.id)) { await observeOutbox() }
        .task(id: environment.accounts.map(\.id)) { await observeDraftCount() }
        .task(id: environment.accounts.map(\.id)) { await observeFailedOpCount() }
        .task(id: environment.accounts.map(\.id)) { await observeMailboxSyncFailureCount() }
        .task(id: environment.accounts.map(\.id)) { await observeUnifiedInboxUnreadCount() }
    }

    /// Builds one `MailboxRow` for the inner `ForEach` in `body` — pulled
    /// out into its own `@ViewBuilder` method (not just an inline closure
    /// body) so the `ForEach(mailboxesByAccountId[account.id] ?? []) {
    /// mailbox in ... }` closure in `body` is a single trivial function
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
            let unreadCount = unreadByMailboxId[mailboxId]
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
        let entries = MailboxCategoryGrouping.entries(for: role, accounts: environment.accounts, mailboxesByAccountId: mailboxesByAccountId)
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
            unifiedInboxUnread
        case .all:
            MailboxCategoryGrouping.unreadCountForAllMailCategory(
                entries: entries, accounts: environment.accounts,
                mailboxesByAccountId: mailboxesByAccountId, unreadByMailboxId: unreadByMailboxId
            )
        default:
            entries.reduce(0) { $0 + (unreadByMailboxId[$1.mailboxId] ?? 0) }
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
                    if let count = unreadByMailboxId[entry.mailboxId], count > 0 {
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
            ForEach(mailboxesByAccountId[account.id] ?? []) { mailbox in
                mailboxRow(for: mailbox, in: account)
            }
        } label: {
            Text(verbatim: account.displayName)
        }
        .task(id: account.id) {
            await observeMailboxes(accountId: account.id)
        }
        .task(id: account.id) {
            await observeUnreadCounts(accountId: account.id)
        }
    }

    private func macCategoryExpandedBinding(for role: MailboxRoleRecord) -> Binding<Bool> {
        Binding(
            get: { !collapsedCategoryRoles.contains(role.rawValue) },
            set: { isExpanded in
                if isExpanded {
                    collapsedCategoryRoles.remove(role.rawValue)
                } else {
                    collapsedCategoryRoles.insert(role.rawValue)
                }
                SidebarCategoryCollapseStore.replaceAll(collapsedCategoryRoles)
            }
        )
    }

    private func macAccountExpandedBinding(for accountId: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedAccountIds.contains(accountId) },
            set: { isExpanded in
                if isExpanded {
                    collapsedAccountIds.remove(accountId)
                } else {
                    collapsedAccountIds.insert(accountId)
                }
                SidebarAccountCollapseStore.replaceAll(collapsedAccountIds)
            }
        )
    }
    #endif

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

    /// `docs/qa-findings.md`'s partial-sync-failure visibility — see
    /// `MailboxSyncFailuresView`'s doc comment for the full rationale.
    /// Separate `Section` row from `sidebar.failedOps` deliberately: an
    /// `opQueue` failure (a *user action* like a delete/flag-change that
    /// couldn't be applied) and a mailbox sync failure (the *background
    /// list-refresh itself* not working for that mailbox) are different
    /// problems with different retry semantics, so collapsing them into one
    /// counter/sheet would blur what's actually wrong.
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

    /// Drafts IMAP sync: counts the same unified list `DraftsView` shows
    /// (local + server-origin, deduplicated) — `DraftQuery.observation`'s
    /// local-only count would otherwise undercount whenever a
    /// server-origin draft (written by another client) hasn't been opened/
    /// saved in this app yet.
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

    /// M10: the "すべての受信トレイ" badge — re-observed whenever the
    /// account list changes (adding/removing an account widens/narrows
    /// which inbox-role mailboxes count toward the total), same trigger
    /// `observeOutbox()` already uses.
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

    /// Per-mailbox unread badges for one account's section — runs
    /// alongside `observeMailboxes(accountId:)` (same lifetime, via a
    /// second `.task(id:)` on the same `Section`) rather than folded into
    /// it, since the two observe different tables (`mailbox` vs. `message`)
    /// and there's no reason a `mailbox` row change should wait on/block a
    /// `message` count re-fetch or vice versa.
    private func observeUnreadCounts(accountId: String) async {
        let observation = MessageQuery.unreadCountsObservation(accountId: accountId)
        do {
            for try await counts in observation.values(in: environment.database.dbWriter) {
                for (mailboxId, count) in counts {
                    unreadByMailboxId[mailboxId] = count
                }
                // A mailbox that just went from "has unread" to "fully
                // read" drops out of `counts` entirely (`MessageQuery
                // .unreadCounts`'s doc comment) — without this, its badge
                // would keep showing the last-known nonzero count forever.
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

    /// Runs for as long as `SidebarView` shows `accountId`'s section
    /// (cancelled automatically by `.task(id:)` when the account
    /// disappears from the list). Also claims "すべての受信トレイ" as the
    /// *data* selection the first time any account's mailboxes appear (M4)
    /// — so the content column is ready to show a populated, threaded list
    /// the instant the user does navigate into it.
    ///
    /// Deliberately does **not** also navigate there (i.e. does not push
    /// `preferredCompactColumn` forward) — that used to happen implicitly
    /// via `RootView`'s `onChange(of: selection)`, and on a compact-width
    /// device (iPhone) that meant a *cold launch* jumped straight past the
    /// sidebar into the message list with no tap at all (docs/verify.md,
    /// "コールドランチが統合受信トレイから始まる"): this same background
    /// data-load path fires on every launch once an account exists, so
    /// there was structurally no way to land on the sidebar root first.
    /// `RootView.onSelected`/`SidebarView.onSelected` is the only path that
    /// pushes the column forward now, and it only fires from a real row
    /// tap — this auto-select stays data-only so macOS/iPadOS's
    /// always-three-column layout (where there is no "column" to push,
    /// `preferredCompactColumn` is simply ignored) is unaffected either
    /// way.
    private func observeMailboxes(accountId: String) async {
        // メールボックス単位の非表示: `includeHidden: false` keeps a hidden
        // mailbox out of the sidebar tree entirely — see
        // `MailboxQuery.request(accountId:includeHidden:)`'s doc comment.
        let observation = MailboxQuery.observation(accountId: accountId, includeHidden: false)
        do {
            for try await mailboxes in observation.values(in: environment.database.dbWriter) {
                mailboxesByAccountId[accountId] = mailboxes
                if selection == nil {
                    selection = .unifiedInbox
                }
            }
        } catch {
            // A failing mailbox observation for one account shouldn't take
            // down the sidebar; that account's section just stops updating.
        }
    }

}

/// One mailbox row inside an account's `Section` in `SidebarView`. Pulled
/// out of `SidebarView.body`'s `ForEach` (which used to build this inline)
/// specifically to keep the type-checker's job small: the inline version —
/// nested `ForEach` + `Button` + `HStack` + a conditional badge + a chain of
/// modifiers, all as one expression — compiled fine on a fast local Mac but
/// exceeded the type-checker's time budget on CI's slower runner
/// (`docs/ci.md`'s troubleshooting notes; the actual failure was `error:
/// the compiler is unable to type-check this expression in reasonable
/// time`). Splitting it into its own `View` gives each piece (this row,
/// `SidebarView.body`) a small expression to check independently instead of
/// one combinatorially large one. Visual output, accessibility identifiers,
/// and tap behavior are unchanged from the inline version.
private struct MailboxRow: View {
    let accountId: String
    let mailbox: MailboxRecord
    let mailboxId: Int64
    let isSelected: Bool
    let unreadCount: Int?
    /// Called with the row's own `SidebarSelection` on tap; `SidebarView`
    /// both writes `selection` and invokes its `onSelected` callback from
    /// here, mirroring what the inline `Button` action used to do directly.
    let onTap: (SidebarSelection) -> Void

    private var mailboxSelection: SidebarSelection {
        .mailbox(MailboxSelection(accountId: accountId, mailboxId: mailboxId))
    }

    var body: some View {
        Button {
            onTap(mailboxSelection)
        } label: {
            HStack {
                Label(mailbox.displayPath, systemImage: icon(for: mailbox.role))
                Spacer()
                if let unreadCount, unreadCount > 0 {
                    UnreadCountBadge(count: unreadCount)
                        .accessibilityIdentifier("sidebar.mailbox.\(accountId).\(mailbox.path).unreadBadge")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? OtegamiColor.paleBase : nil)
        .accessibilityIdentifier("sidebar.mailbox.\(accountId).\(mailbox.path)")
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

/// M10: unread-count pill for a sidebar row — matches the system Mail app's
/// look (a filled capsule, not a plain number) closely enough to read as
/// "standard" rather than a bespoke control. Caps the displayed text at
/// "99+" rather than ever showing an unbounded number: a three-figure badge
/// starts fighting the row's trailing edge for space, and "exactly how many
/// hundred" isn't information worth that cost once it's already "a lot."
private struct UnreadCountBadge: View {
    let count: Int

    private var displayText: String {
        count > 99 ? "99+" : "\(count)"
    }

    var body: some View {
        Text(displayText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(OtegamiColor.accent))
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
