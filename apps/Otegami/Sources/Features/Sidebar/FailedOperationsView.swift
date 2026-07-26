import SwiftUI
import OtegamiStore
import SyncEngine

/// M10's "同期エラー" banner detail (plan: "opQueue failed 時のバナー (M3 で予定の
/// まま未実装なら)"). Lists every `opQueue` row that's hit
/// `OpQueueProcessor.maxAttempts` (`OpQueueQuery.failedOps`'s doc comment on
/// why the threshold is passed in rather than hardcoded here) — these are
/// operations `OpQueueProcessor.replay` has given up retrying automatically,
/// so the user needs a way to either try again (e.g. after fixing whatever
/// was wrong server-side) or give up on them explicitly.
struct FailedOperationsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var failedOps: [OpQueueRecord] = []

    var body: some View {
        NavigationStack {
            List {
                if failedOps.isEmpty {
                    ContentUnavailableView("失敗した操作はありません", systemImage: "checkmark.circle")
                        .accessibilityIdentifier("failedOps.emptyState")
                } else {
                    ForEach(failedOps) { op in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label(for: op))
                                .font(.headline)
                            if let lastError = op.lastError, !lastError.isEmpty {
                                Text(lastError)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            HStack(spacing: 12) {
                                Button("再試行") { Task { await retry(op) } }
                                    .accessibilityIdentifier("failedOps.row.\(op.id ?? 0).retry")
                                Button("破棄", role: .destructive) { Task { await discard(op) } }
                                    .accessibilityIdentifier("failedOps.row.\(op.id ?? 0).discard")
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                        .accessibilityIdentifier("failedOps.row.\(op.id ?? 0)")
                    }
                }
            }
            .navigationTitle("同期エラー")
            .scrollContentBackground(.hidden)
            .background(OtegamiColor.background)
            .tint(OtegamiColor.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                        .accessibilityIdentifier("failedOps.closeButton")
                }
            }
        }
        .accessibilityIdentifier("failedOps.sheet")
        #if os(macOS)
        // M10 fix: see AccountTypeSelectionView's doc comment on why every
        // NavigationStack{List{...}}-shaped sheet in this app needs this.
        .frame(minWidth: 480, minHeight: 420)
        #endif
        .task(id: environment.accounts.map(\.id)) { await observe() }
    }

    private func label(for op: OpQueueRecord) -> String {
        switch OpQueueKind(rawValue: op.kind) {
        case .setFlags: "フラグ変更に失敗しました"
        case .move: "メールの移動に失敗しました"
        case .delete: "メールの削除に失敗しました"
        case .junk: "迷惑メールへの移動に失敗しました"
        case .archive: "アーカイブに失敗しました"
        case .send: "メールの送信に失敗しました"
        case .saveDraft: "下書きの保存に失敗しました"
        case .deleteDraft: "下書きの削除に失敗しました"
        case nil: "操作に失敗しました (\(op.kind))"
        }
    }

    private func observe() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = OpQueueQuery.failedOpsObservation(accountIds: accountIds, minAttempts: OpQueueProcessor.maxAttempts)
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                failedOps = fetched
            }
        } catch {
            // A failing observation just stops the list from updating further.
        }
    }

    /// Resets the op back to "eligible now" (`attempts = 0`, `nextRetryAt =
    /// nil`) so the next `OpQueueProcessor.replay` (foreground activation,
    /// manual refresh, ...) picks it up again — useful after fixing
    /// whatever caused every prior attempt to fail (e.g. the account's
    /// password was wrong and has since been corrected).
    private func retry(_ op: OpQueueRecord) async {
        guard let opId = op.id else { return }
        try? await environment.database.dbWriter.write { db in
            guard var row = try OpQueueRecord.fetchOne(db, key: opId) else { return }
            row.attempts = 0
            row.nextRetryAt = nil
            try row.update(db)
        }
        guard let account = environment.accounts.first(where: { $0.id == op.accountId }) else { return }
        guard let auth = try? await environment.auth(for: account) else { return }
        _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
    }

    /// Gives up on this op entirely: deletes the `opQueue` row so it stops
    /// showing here, and — for a `.send` op specifically — also deletes the
    /// `outboxMessage` row it references (`SendOpPayload.outboxMessageId`).
    /// Without that second delete, a permanently-failed send would vanish
    /// from this list but its `outboxMessage` row (and the sidebar's "送信待ち"
    /// count reading it) would linger forever with no `opQueue` row left to
    /// ever retry it — an orphaned "still sending" state nothing could
    /// clear. Every other op kind (`setFlags`/`move`/`delete`) has no such
    /// side-table row to clean up: they only ever describe a change to
    /// apply to already-mutated local state.
    private func discard(_ op: OpQueueRecord) async {
        guard let opId = op.id else { return }
        try? await environment.database.dbWriter.write { db in
            if op.kind == OpQueueKind.send.rawValue,
               let payload = try? JSONDecoder().decode(SendOpPayload.self, from: op.payload) {
                _ = try OutboxMessageRecord.deleteOne(db, key: payload.outboxMessageId)
            }
            _ = try OpQueueRecord.deleteOne(db, key: opId)
        }
    }
}
