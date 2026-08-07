import SwiftUI
import GRDB
import MailTransport
import OtegamiStore
import SyncEngine

/// M10's "下書き" list (plan: "Composer 閉じる時「下書きとして保存/破棄」→ ローカル
/// 保存"), extended by the Drafts IMAP sync milestone to show one unified
/// list of local *and* server-origin drafts (`DraftQuery.UnifiedRow` — see
/// its doc comment for how the two are merged/deduplicated). Mirrors
/// `OutboxView`'s shape, but rows are tappable — resuming a draft opens
/// `ComposerView` via `onOpenDraft` (local) or `onOpenServerDraft`
/// (server-origin), the same "presentation is `RootView`'s job" pattern
/// `SidebarView.onCompose` already uses, since Composer presentation
/// differs per platform — sheet on iOS, a separate window on macOS.
struct DraftsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var onOpenDraft: (Int64) -> Void = { _ in }
    var onOpenServerDraft: (Int64) -> Void = { _ in }

    @State private var items: [DraftQuery.UnifiedRow] = []
    @State private var pendingDeletion: DraftQuery.UnifiedRow?

    /// Task #165 (macOS 操作体系再設計、実機フィードバック「下書きの削除もで
    /// きない」): iOS の`.swipeActions`(下の`draftRow(_:)`内)は macOS の
    /// `List`では一切露出しない(スワイプというジェスチャー自体が存在しない)
    /// — 下書きフォルダで削除する手段が macOS に文字通り無かった、という
    /// のがこのバグの実体。`List(selection:)`でタグ付けした行を選択できる
    /// ようにし、右クリックのコンテキストメニュー・ツールバーのゴミ箱
    /// ボタン・⌫キー(`.onDeleteCommand`)の3経路すべてから同じ
    /// `pendingDeletion`確認フロー(既存、iOSのスワイプ削除と共有)を起動
    /// できるようにする。iOS 側はこのプロパティも`List(selection:)`も一切
    /// 参照しない(`listBody`の`#if os(macOS)`分岐)ので、iOS の挙動は不変。
    #if os(macOS)
    @State private var macSelection: String?
    #endif

    var body: some View {
        NavigationStack {
            listBody
            .navigationTitle("下書き")
            // Liquid Glass Phase 4 (`docs/design-system.md`「Liquid Glass
            // 方針」): 独自`background`塗りは廃止し標準の`List`背景へ委譲
            // — tint (意味を持つ色) だけは iOS 限定で維持する
            // (`SidebarView.sidebarList`と同じ判断)。
            #if os(iOS)
            .tint(OtegamiColor.accent)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                        .accessibilityIdentifier("drafts.closeButton")
                }
                #if os(macOS)
                ToolbarItem {
                    macDeleteToolbarButton
                }
                #endif
            }
            #if os(macOS)
            .onDeleteCommand { deleteSelectedViaKeyboard() }
            #endif
            .alert(
                "下書きを削除しますか？",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                presenting: pendingDeletion
            ) { item in
                Button("削除", role: .destructive) {
                    Task { await delete(item) }
                }
                Button("キャンセル", role: .cancel) {}
            } message: { item in
                Text(item.subject.isEmpty ? "この下書きを削除します。" : "「\(item.subject)」を削除します。")
            }
        }
        .accessibilityIdentifier("drafts.sheet")
        #if os(macOS)
        // M10 fix: see AccountTypeSelectionView's doc comment on why every
        // NavigationStack{List{...}}-shaped sheet in this app needs this.
        .frame(minWidth: 480, minHeight: 420)
        #endif
        .task(id: environment.accounts.map(\.id)) { await observe() }
    }

    /// Split out of `body` per `docs/ci.md`'s "keep the `List`'s own
    /// modifier chain and the platform-varying `List(selection:)` overload
    /// itself as their own small expression" discipline — this file already
    /// grew a `#if os(macOS)`-gated toolbar item/`.onDeleteCommand` above,
    /// and `List(selection:)`/`List` are genuinely different initializer
    /// overloads, not just a modifier difference, so they can't be unified
    /// into one expression with a ternary the way most of this app's other
    /// platform splits are.
    @ViewBuilder
    private var listBody: some View {
        #if os(macOS)
        List(selection: $macSelection) {
            listRows
        }
        #else
        List {
            listRows
        }
        #endif
    }

    @ViewBuilder
    private var listRows: some View {
        if items.isEmpty {
            ContentUnavailableView("下書きはありません", systemImage: "doc")
                .accessibilityIdentifier("drafts.emptyState")
        } else {
            ForEach(items) { item in
                draftRow(item)
            }
        }
    }

    /// One row — pulled out of `listRows` for the same "keep the `ForEach`
    /// closure itself down to one call" reason `docs/ci.md` documents
    /// everywhere else in this app (this row grew a `.tag`, `.swipeActions`,
    /// and a macOS-only `.contextMenu`).
    @ViewBuilder
    private func draftRow(_ item: DraftQuery.UnifiedRow) -> some View {
        Button {
            dismiss()
            open(item)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.subject.isEmpty ? "(件名なし)" : item.subject)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if !item.toAddresses.isEmpty {
                    Text(item.toAddresses.map(\.description).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !item.snippet.isEmpty {
                    Text(item.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drafts.row.\(item.id)")
        // macOS-only `List(selection: $macSelection)` needs this to know
        // which row a click/arrow-key selects — a no-op on iOS (`listBody`'s
        // plain, selection-less `List` there).
        .tag(item.id)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDeletion = item
            } label: {
                Label("削除", systemImage: "trash")
            }
            .accessibilityIdentifier("drafts.row.\(item.id).delete")
        }
        #if os(macOS)
        .contextMenu {
            Button("編集") {
                dismiss()
                open(item)
            }
            Button("削除", role: .destructive) {
                pendingDeletion = item
            }
        }
        #endif
    }

    #if os(macOS)
    private var macDeleteToolbarButton: some View {
        Button {
            deleteSelectedViaKeyboard()
        } label: {
            Label("削除", systemImage: "trash")
        }
        .disabled(macSelection == nil)
        .accessibilityIdentifier("drafts.toolbar.deleteButton")
        .help("選択中の下書きを削除")
    }

    /// `.onDeleteCommand`(⌫キー)とツールバーのゴミ箱ボタン両方の実体 —
    /// どちらも「今選択中の行を`pendingDeletion`へ渡して確認アラートを
    /// 起動する」という同じことをするだけなので、1箇所にまとめてある。
    private func deleteSelectedViaKeyboard() {
        guard let macSelection, let item = items.first(where: { $0.id == macSelection }) else { return }
        pendingDeletion = item
    }
    #endif

    private func open(_ item: DraftQuery.UnifiedRow) {
        switch item {
        case .local(let draft):
            guard let draftId = draft.id else { return }
            onOpenDraft(draftId)
        case .server(let message, _, _):
            guard let messageId = message.id else { return }
            onOpenServerDraft(messageId)
        }
    }

    private func observe() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = DraftQuery.unifiedObservation(accountIds: accountIds)
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                items = fetched
            }
        } catch {
            // A failing observation just stops the list from updating further.
        }
    }

    /// Deletes `item` from both the local list (immediately, optimistic)
    /// and — best-effort, via `OpQueueKind.deleteDraft` — the server's
    /// Drafts mailbox, if it has a known server copy at all. A purely local
    /// draft never yet uploaded (`.local` with `serverUid == nil`) has
    /// nothing server-side to enqueue, matching the pre-sync M10 behavior
    /// exactly for that case.
    private func delete(_ item: DraftQuery.UnifiedRow) async {
        switch item {
        case .local(let draft):
            guard let draftId = draft.id else { return }
            let enqueuedServerDelete = (try? await environment.database.dbWriter.write { db -> Bool in
                var enqueued = false
                if let mailboxId = draft.serverMailboxId, let uid = draft.serverUid, let uidValidity = draft.serverUidValidity {
                    enqueued = true
                    try OpQueue.enqueueDeleteDraft(
                        accountId: draft.accountId, mailboxId: mailboxId, uidValidity: uidValidity,
                        uid: UInt32(truncatingIfNeeded: uid), db: db
                    )
                }
                _ = try DraftMessageRecord.deleteOne(db, key: draftId)
                return enqueued
            }) ?? false
            if enqueuedServerDelete {
                await replayOpQueueBestEffort(accountId: draft.accountId)
            }

        case .server(let message, let accountId, _):
            guard let messageId = message.id else { return }
            let fetchedMailboxInfo = try? await environment.database.dbWriter.read { db -> (id: Int64, uidValidity: Int64)? in
                guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId), let mailboxId = mailbox.id else { return nil }
                return (mailboxId, mailbox.uidValidity)
            }
            guard let mailboxInfo = fetchedMailboxInfo else { return }

            try? await environment.database.dbWriter.write { db in
                try OpQueue.enqueueDeleteDraft(
                    accountId: accountId, mailboxId: mailboxInfo.id, uidValidity: mailboxInfo.uidValidity,
                    uid: UInt32(truncatingIfNeeded: message.uid), db: db
                )
                // Optimistic local removal (this app's usual "ローカル DB
                // 即時反映 + enqueue" pattern) — the same cleanup
                // `MailboxSyncer`'s server-side-expunge diff already does
                // for any other deleted message.
                try FTSIndexer.deleteAll(messageIds: [messageId], db: db)
                let threadId = message.threadId
                try MessageRecord.deleteOne(db, key: messageId)
                if let threadId {
                    try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
                }
            }
            await replayOpQueueBestEffort(accountId: accountId)
        }
    }

    private func replayOpQueueBestEffort(accountId: String) async {
        guard let account = environment.accounts.first(where: { $0.id == accountId }),
              let auth = try? await environment.auth(for: account)
        else { return }
        _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
    }
}
