import SwiftUI
import OtegamiStore

/// M10's "下書き" list (plan: "Composer 閉じる時「下書きとして保存/破棄」→ ローカル
/// 保存"). Mirrors `OutboxView`'s shape, but rows are tappable — resuming a
/// draft opens `ComposerView(payload: .draft(draftId:))` via `onOpenDraft`
/// (the same "presentation is `RootView`'s job" pattern `SidebarView.onCompose`
/// already uses, since Composer presentation differs per platform — sheet on
/// iOS, a separate window on macOS).
struct DraftsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var onOpenDraft: (Int64) -> Void = { _ in }

    @State private var drafts: [DraftMessageRecord] = []
    @State private var pendingDeletion: DraftMessageRecord?

    var body: some View {
        NavigationStack {
            List {
                if drafts.isEmpty {
                    ContentUnavailableView("下書きはありません", systemImage: "doc")
                        .accessibilityIdentifier("drafts.emptyState")
                } else {
                    ForEach(drafts) { draft in
                        Button {
                            guard let draftId = draft.id else { return }
                            dismiss()
                            onOpenDraft(draftId)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(draft.subject.isEmpty ? "(件名なし)" : draft.subject)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                if !draft.toAddresses.isEmpty {
                                    Text(draft.toAddresses.map(\.description).joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if !draft.plainTextBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(draft.plainTextBody.trimmingCharacters(in: .whitespacesAndNewlines))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("drafts.row.\(draft.id ?? 0)")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDeletion = draft
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                            .accessibilityIdentifier("drafts.row.\(draft.id ?? 0).delete")
                        }
                    }
                }
            }
            .navigationTitle("下書き")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                        .accessibilityIdentifier("drafts.closeButton")
                }
            }
            .alert(
                "下書きを削除しますか？",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                presenting: pendingDeletion
            ) { draft in
                Button("削除", role: .destructive) {
                    Task { await delete(draft) }
                }
                Button("キャンセル", role: .cancel) {}
            } message: { draft in
                Text(draft.subject.isEmpty ? "この下書きを削除します。" : "「\(draft.subject)」を削除します。")
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

    private func observe() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = DraftQuery.observation(accountIds: accountIds)
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                drafts = fetched
            }
        } catch {
            // A failing observation just stops the list from updating further.
        }
    }

    private func delete(_ draft: DraftMessageRecord) async {
        guard let draftId = draft.id else { return }
        try? await environment.database.dbWriter.write { db in
            _ = try DraftMessageRecord.deleteOne(db, key: draftId)
        }
    }
}
