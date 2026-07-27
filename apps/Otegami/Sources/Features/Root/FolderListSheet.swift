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
    var onSelectUnified: () -> Void
    var onSelectMailbox: (MailboxSelection, String) -> Void
    var onOpenOutbox: () -> Void
    var onOpenDrafts: () -> Void
    var onOpenFailedOps: () -> Void
    var onOpenMailboxSyncFailures: () -> Void
    var onAddAccount: () -> Void
    /// 新画面構成 (1): メニュー最下部の「設定」行。
    var onOpenSettings: () -> Void
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
                    ForEach(environment.accounts) { account in
                        accountSection(for: account)
                            .task(id: account.id) { await observeMailboxes(accountId: account.id) }
                            .task(id: account.id) { await observeUnreadCounts(accountId: account.id) }
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
        let observation = MailboxQuery.observation(accountId: accountId)
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

/// One mailbox row inside `FolderListSheet` — see `SidebarView.MailboxRow`'s
/// doc comment for why this is split out of the `ForEach` closure at all
/// (same CI type-check rationale, independently re-applied to this file).
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
