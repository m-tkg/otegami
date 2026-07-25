import SwiftUI
import OtegamiStore

/// M5's "送信待ち" list (plan verification (c): "「送信待ち」がUIで見える" while
/// offline). Reads `outboxMessage` directly — a row here means `OpQueueKind
/// .send`'s replay hasn't succeeded yet, whether that's because the device
/// is offline, still waiting its next backoff window, or has exhausted
/// `OpQueueProcessor.maxAttempts` (the row simply stays either way; see
/// `OutboxMessageRecord`'s doc comment for why no separate status field is
/// needed).
struct OutboxView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var pending: [OutboxMessageRecord] = []

    var body: some View {
        NavigationStack {
            List {
                if pending.isEmpty {
                    ContentUnavailableView("送信待ちのメールはありません", systemImage: "tray")
                        .accessibilityIdentifier("outbox.emptyState")
                } else {
                    ForEach(pending) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.subject.isEmpty ? "(件名なし)" : message.subject)
                                .font(.headline)
                            Text(message.toAddresses.map(\.description).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Label("送信待ち", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .accessibilityIdentifier("outbox.row.\(message.id ?? 0)")
                    }
                }
            }
            .navigationTitle("送信待ち")
            .scrollContentBackground(.hidden)
            .background(OtegamiColor.background)
            .tint(OtegamiColor.accent)
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
        let observation = OutboxQuery.observation(accountIds: accountIds)
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                pending = fetched
            }
        } catch {
            // A failing observation just stops the list from updating
            // further; it doesn't clear what's already shown.
        }
    }
}
