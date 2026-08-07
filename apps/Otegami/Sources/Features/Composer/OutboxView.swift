import SwiftUI
import GRDB
import OtegamiStore
import SyncEngine

/// M5's "送信待ち" list (plan verification (c): "「送信待ち」がUIで見える" while
/// offline). Reads `OutboxQuery.itemsObservation` — a row here means
/// `OpQueueKind.send`'s replay hasn't succeeded yet, whether that's because
/// the device is offline, still waiting its next backoff window, has
/// exhausted `OpQueueProcessor.maxAttempts`, or (an orphan — no `.send` op
/// left at all) can never be picked up automatically again. Task「送信失敗
/// メールの再送・削除」: the latter two cases used to leave a row here
/// forever with no way for the user to do anything about it — this view now
/// surfaces "送信失敗" for them and offers "再送"/"削除", mirroring
/// `FailedOperationsView`'s row actions.
struct OutboxView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var items: [OutboxQuery.Item] = []

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    ContentUnavailableView("送信待ちのメールはありません", systemImage: "tray")
                        .accessibilityIdentifier("outbox.emptyState")
                } else {
                    ForEach(items) { item in
                        OutboxRowView(
                            item: item,
                            onResend: { Task { await resend(item) } },
                            onDelete: { Task { await delete(item) } }
                        )
                        .accessibilityIdentifier("outbox.row.\(item.id)")
                    }
                }
            }
            .navigationTitle("送信待ち")
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
                        .accessibilityIdentifier("outbox.closeButton")
                }
            }
        }
        .accessibilityIdentifier("outbox.sheet")
        #if os(macOS)
        // M10 fix: see AccountTypeSelectionView's doc comment on why every
        // NavigationStack{List{...}}-shaped sheet in this app needs this.
        .frame(minWidth: 480, minHeight: 420)
        #endif
        .task(id: environment.accounts.map(\.id)) { await observe() }
    }

    private func observe() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = OutboxQuery.itemsObservation(accountIds: accountIds)
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                items = fetched
            }
        } catch {
            // A failing observation just stops the list from updating
            // further; it doesn't clear what's already shown.
        }
    }

    /// "再送": undoes both of the ways a `.send` op can be permanently
    /// stuck, in one write transaction, then immediately kicks a replay —
    /// the same "reset → replay" shape as `FailedOperationsView.retry`,
    /// plus one thing that view's ops never need: clearing
    /// `OutboxMessageRecord.sendStartedAt` (Task #124's 二重送信防止 claim).
    /// Without that reset, resending after a previous attempt whose
    /// process died *mid-SMTP-call* (rather than cleanly returning an
    /// error — the case `releaseSendClaim` can't cover) would still be
    /// refused by `duplicateSendBlocked` even after the op itself is reset
    /// to `attempts = 0`. Clearing the claim here is safe specifically
    /// *because* this is a user-initiated resend: unlike an automatic
    /// retry, a human just explicitly decided the previous attempt is
    /// truly abandoned, not silently still in flight.
    private func resend(_ item: OutboxQuery.Item) async {
        guard let messageId = item.message.id else { return }
        try? await environment.database.dbWriter.write { db in
            guard var outbox = try OutboxMessageRecord.fetchOne(db, key: messageId) else { return }
            outbox.sendStartedAt = nil
            try outbox.update(db, columns: [Column("sendStartedAt")])

            if let opId = item.opId, var op = try OpQueueRecord.fetchOne(db, key: opId) {
                op.attempts = 0
                op.nextRetryAt = nil
                op.lastError = nil
                try op.update(db)
            } else {
                // Orphaned row (no `.send` op survived) — nothing left to
                // reset, so enqueue a fresh one via the same helper
                // `ComposerView.send()` uses.
                try OpQueue.enqueueSend(accountId: item.message.accountId, outboxMessageId: messageId, db: db)
            }
        }
        guard let account = environment.accounts.first(where: { $0.id == item.message.accountId }) else { return }
        guard let auth = try? await environment.auth(for: account) else { return }
        _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
    }

    /// "削除": gives up on this send entirely — reuses
    /// `PendingSendCoordinator.deleteOutboxMessage`, the same logic
    /// "送信を取り消す" already relies on to undo `ComposerView.send()`'s
    /// durable write (outbox row + its attachments + the matching `.send`
    /// opQueue row + staged attachment files).
    private func delete(_ item: OutboxQuery.Item) async {
        guard let messageId = item.message.id else { return }
        await PendingSendCoordinator.deleteOutboxMessage(id: messageId, accountId: item.message.accountId, database: environment.database)
    }
}

/// One `OutboxView` row, its own `View` type per this repo's CI
/// type-check-timeout guidance (`CLAUDE.md`: keep `body` expressions small,
/// extract `ForEach` row content into a separate type) — `OutboxView.body`
/// above stays a plain `ForEach { OutboxRowView(...) }` call.
private struct OutboxRowView: View {
    let item: OutboxQuery.Item
    let onResend: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Text(verbatim:) for every dynamic string here — via
            // LocalizedStringKey, Markdown interpretation turns the email
            // addresses into mailto: links (AccountFilterChip.swift の教訓).
            Text(verbatim: item.message.subject.isEmpty ? "(件名なし)" : item.message.subject)
                .font(.headline)
            Text(verbatim: item.message.toAddresses.map(\.description).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
            statusLabel
            if isFailed, let lastError = item.lastError, !lastError.isEmpty {
                Text(verbatim: lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 12) {
                Button("再送", action: onResend)
                    .accessibilityIdentifier("outbox.row.\(item.id).resend")
                Button("削除", role: .destructive, action: onDelete)
                    .accessibilityIdentifier("outbox.row.\(item.id).delete")
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }

    private var isFailed: Bool {
        item.isFailed(maxAttempts: OpQueueProcessor.maxAttempts)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if isFailed {
            Label("送信失敗", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(OtegamiColor.destructive)
        } else {
            Label("送信待ち", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
