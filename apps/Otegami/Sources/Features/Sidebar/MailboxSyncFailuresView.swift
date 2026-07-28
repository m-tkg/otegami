import SwiftUI
import OtegamiStore
import SyncEngine

/// Partial-sync failure visibility (`docs/qa-findings.md`): before this,
/// `AccountSyncer`'s per-mailbox `do`/`catch` (both `performInitialSync` and
/// `performIncrementalSync`) swallowed one mailbox's sync failure entirely
/// (a bare `continue`, nothing recorded anywhere) so that *other* mailboxes
/// in the same account wouldn't get stuck behind it — but that also meant a
/// real, ongoing sync problem for *this* mailbox (bad credentials scoped to
/// one shared mailbox, a server-side quirk on just that folder, ...) was
/// invisible: the mailbox's message list would just silently stop updating,
/// with nothing in the UI to explain why. `AccountSyncer` now records the
/// failure onto `MailboxRecord.lastSyncError`/`lastSyncErrorAt` (see that
/// property's doc comment) instead of only `continue`-ing past it; this view
/// lists every mailbox currently in that state, following the same
/// list/retry shape `FailedOperationsView` already established for
/// `opQueue` failures — a deliberate stylistic match (`docs/qa-findings.md`
/// asked for this: "既存の FailedOperationsView ... と流儀を揃える").
///
/// Unlike `FailedOperationsView`, there's no "破棄" (discard) action: a
/// `MailboxRecord` isn't a retryable queued operation with a natural
/// "give up" terminal state, it's just this mailbox's *current* sync
/// status — the only way this list entry goes away is a subsequent sync of
/// that mailbox succeeding (automatic, via `AccountSyncer
/// .clearMailboxSyncFailureIfNeeded`) or the user retrying it here.
struct MailboxSyncFailuresView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var failedMailboxes: [MailboxRecord] = []
    @State private var retryingMailboxIds: Set<Int64> = []

    var body: some View {
        NavigationStack {
            List {
                if failedMailboxes.isEmpty {
                    ContentUnavailableView("同期に失敗したメールボックスはありません", systemImage: "checkmark.circle")
                        .accessibilityIdentifier("mailboxSyncFailures.emptyState")
                } else {
                    ForEach(failedMailboxes) { mailbox in
                        if let mailboxId = mailbox.id {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(title(for: mailbox))
                                    .font(.headline)
                                if let lastError = mailbox.lastSyncError, !lastError.isEmpty {
                                    Text(lastError)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Button("再試行") { Task { await retry(mailbox) } }
                                    .accessibilityIdentifier("mailboxSyncFailures.row.\(mailboxId).retry")
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                                    .disabled(retryingMailboxIds.contains(mailboxId))
                            }
                            .accessibilityIdentifier("mailboxSyncFailures.row.\(mailboxId)")
                        }
                    }
                }
            }
            .navigationTitle("メールボックス同期エラー")
            .scrollContentBackground(.hidden)
            .background(OtegamiColor.background)
            .tint(OtegamiColor.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                        .accessibilityIdentifier("mailboxSyncFailures.closeButton")
                }
            }
        }
        .accessibilityIdentifier("mailboxSyncFailures.sheet")
        #if os(macOS)
        // Same fix as every other NavigationStack{List{...}}-shaped sheet in
        // this app — see AccountTypeSelectionView's doc comment (M10).
        .frame(minWidth: 480, minHeight: 420)
        #endif
        .task(id: environment.accounts.map(\.id)) { await observe() }
    }

    private func title(for mailbox: MailboxRecord) -> String {
        let accountName = environment.accounts.first(where: { $0.id == mailbox.accountId })?.displayName ?? mailbox.accountId
        return "\(accountName) — \(mailbox.displayPath)"
    }

    private func observe() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = MailboxQuery.syncFailuresObservation(accountIds: accountIds)
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                failedMailboxes = fetched
            }
        } catch {
            // A failing observation just stops the list from updating further.
        }
    }

    /// Retries this one mailbox specifically (`SyncScope.mailbox(path:)`)
    /// rather than a full incremental sync of the whole account — the
    /// user's intent here is "try this failing mailbox again", and a
    /// broader sync would also touch mailboxes that are already fine.
    /// Success clears `lastSyncError` on its own (`AccountSyncer
    /// .clearMailboxSyncFailureIfNeeded`, via the same `ValueObservation`
    /// this view is already watching) — no separate "mark resolved" step
    /// needed here.
    private func retry(_ mailbox: MailboxRecord) async {
        guard let mailboxId = mailbox.id else { return }
        guard let account = environment.accounts.first(where: { $0.id == mailbox.accountId }) else { return }
        retryingMailboxIds.insert(mailboxId)
        defer { retryingMailboxIds.remove(mailboxId) }
        guard let auth = try? await environment.auth(for: account) else { return }
        // Task #69: `autoRetry: false` — this button is itself an explicit
        // "try this one mailbox again" user action, the same "immediate,
        // one attempt, show the result" spirit as `MessageListView`'s
        // manual pull-to-refresh (see `refresh(surfaceErrors:autoRetry:)`'s
        // doc comment). Auto-retrying here would risk the tap appearing to
        // do nothing: a single retried failure wouldn't re-record
        // `lastSyncError` until the streak reaches `maxAttempts`, leaving
        // this banner showing the old error with no visible feedback that
        // the button did anything.
        _ = try? await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth, scope: .mailbox(path: mailbox.path), autoRetry: false)
    }
}
