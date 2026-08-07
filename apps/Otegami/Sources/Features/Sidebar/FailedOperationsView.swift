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
    /// 実機報告「Gmail で既読化/アーカイブしてもサーバに反映されず、
    /// 再読込でサーバ状態に巻き戻る」の調査可能化: `OpQueueProcessor
    /// .replay`が`.staleDiscarded`(対象メールボックスの`uidValidity`が
    /// enqueue時と変わっており再送不可能)と判定し`opQueue`から削除した
    /// 操作の記録 — `failedOps`(まだ再試行できる恒久失敗)とは別に持つのは
    /// 「再試行」ボタンが意味を持たないため (`OpQueueStaleDiscardRecord`の
    /// doc comment参照)。
    @State private var staleDiscards: [OpQueueStaleDiscardRecord] = []

    var body: some View {
        NavigationStack {
            List {
                if failedOps.isEmpty && staleDiscards.isEmpty {
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
                    if !staleDiscards.isEmpty {
                        Section {
                            ForEach(staleDiscards) { discard in
                                StaleDiscardRow(discard: discard, label: label(forKind: discard.kind)) {
                                    Task { await dismissStaleDiscard(discard) }
                                }
                            }
                        } header: {
                            Text("送信できなかった操作")
                        } footer: {
                            Text("メールボックスの構成が変わったため、サーバーへ送信できずに取り消された操作です。再試行はできません。")
                        }
                    }
                }
            }
            .navigationTitle("同期エラー")
            // 2026-08-07 (メイン UI の macOS ネイティブ化): 独自の背景
            // 塗り・tint は iOS のみ (`SidebarView.sidebarList` と同じ判断)。
            #if os(iOS)
            .tint(OtegamiColor.accent)
            #endif
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
        label(forKind: op.kind)
    }

    /// Same wording `label(for:)` always used, factored out so
    /// `staleDiscards`(生の`kind`文字列しか持たない`OpQueueStaleDiscardRecord`)
    /// も同じ文言で表示できる。
    private func label(forKind kind: String) -> String {
        switch OpQueueKind(rawValue: kind) {
        case .setFlags: "フラグ変更に失敗しました"
        case .move: "メールの移動に失敗しました"
        case .delete: "メールの削除に失敗しました"
        case .junk: "迷惑メールへの移動に失敗しました"
        case .archive: "アーカイブに失敗しました"
        // Task #87 (1): "アーカイブ解除" の失敗表示 — 他の kind と同じ文言パターン。
        case .unarchive: "アーカイブの解除に失敗しました"
        case .send: "メールの送信に失敗しました"
        case .saveDraft: "下書きの保存に失敗しました"
        case .deleteDraft: "下書きの削除に失敗しました"
        case nil: "操作に失敗しました (\(kind))"
        }
    }

    private func observe() async {
        let accountIds = environment.accounts.map(\.id)
        async let failedOpsTask: Void = observeFailedOps(accountIds: accountIds)
        async let staleDiscardsTask: Void = observeStaleDiscards()
        _ = await (failedOpsTask, staleDiscardsTask)
    }

    private func observeFailedOps(accountIds: [String]) async {
        let observation = OpQueueQuery.failedOpsObservation(accountIds: accountIds, minAttempts: OpQueueProcessor.maxAttempts)
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                failedOps = fetched
            }
        } catch {
            // A failing observation just stops the list from updating further.
        }
    }

    /// 実機報告「Gmail で既読化/アーカイブしてもサーバに反映されず、
    /// 再読込でサーバ状態に巻き戻る」の調査可能化: 直近の
    /// `.staleDiscarded`記録も`failedOps`と並行して購読する — アカウント
    /// 絞り込みはせず全件表示 (`recentStaleDiscardsObservation`はアカウント
    /// 単位のフィルタを持たない。この画面自体が複数アカウント横断の
    /// 「同期エラー」一覧のため、`failedOps`同様どのアカウントの分でも
    /// ここに出すのが一貫している)。
    private func observeStaleDiscards() async {
        let observation = OpQueueDiagnosticsQuery.recentStaleDiscardsObservation(limit: 20)
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                staleDiscards = fetched
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

    /// Gives up on this op entirely — `OpQueue.discard(opId:db:)`が
    /// `opQueue`行の削除と`.send`op の`outboxMessage`後始末をまとめて行う
    /// (この画面がインラインで持っていた処理を、診断画面の「未送信の操作を
    /// 破棄」と共有するため`SyncEngine`側へ移した。副作用の判断理由は
    /// そちらのdoc comment参照)。
    private func discard(_ op: OpQueueRecord) async {
        guard let opId = op.id else { return }
        try? await environment.database.dbWriter.write { db in
            try OpQueue.discard(opId: opId, db: db)
        }
    }

    /// Clears one `opQueueStaleDiscard` row — unlike `discard(_:)`, there's
    /// no `opQueue`/`outboxMessage` row left to clean up at this point
    /// (`OpQueueProcessor.recordStaleDiscardAndDelete` already removed the
    /// `opQueue` row atomically when it wrote this record); this just lets
    /// the user acknowledge and clear the notice once they've seen it.
    private func dismissStaleDiscard(_ discard: OpQueueStaleDiscardRecord) async {
        guard let id = discard.id else { return }
        try? await environment.database.dbWriter.write { db in
            _ = try OpQueueStaleDiscardRecord.deleteOne(db, key: id)
        }
    }
}

/// One `opQueueStaleDiscard`行の表示 — `CLAUDE.md`の「1つの`body`を長く
/// 書かない」方針に沿って独立させた (SwiftUIビューの型チェックタイムアウト
/// 対策)。
private struct StaleDiscardRow: View {
    let discard: OpQueueStaleDiscardRecord
    let label: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.headline)
            // `discard.reason`は`OpQueueProcessor`が生成する固定の日本語文
            // だが実行時の値であることに変わりはないため、他の診断画面と
            // 同じく`Text(verbatim:)`(`AccountFilterChip.swift`の教訓)。
            Text(verbatim: discard.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Button("消去", role: .destructive, action: onDismiss)
                .font(.caption)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("failedOps.staleDiscard.\(discard.id ?? 0).dismiss")
        }
        .accessibilityIdentifier("failedOps.staleDiscard.\(discard.id ?? 0)")
    }
}
