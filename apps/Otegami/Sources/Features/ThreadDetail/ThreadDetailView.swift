import SwiftUI
import GRDB
import OtegamiCore
import OtegamiStore

/// M4's thread reading view: every message in the thread laid out
/// vertically, newest expanded, everything older collapsed to a one-line
/// summary (plan: "スレッド内メッセージを縦列挙、最新以外は折り畳み（ヘッダタップ
/// で展開）"). A thread with exactly one message degenerates naturally to
/// "one expanded row, nothing to collapse" — the same view handles both
/// cases with no special-casing.
///
/// Only marks a message read once it's actually expanded (plan: "スレッドの
/// 既読化は展開したメッセージのみ") — `MessageView` (embedded per expanded row)
/// is what triggers a read, and it's only ever instantiated for the
/// currently-expanded message id, so a collapsed row's body is never even
/// fetched, let alone marked read.
struct ThreadDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    let threadId: Int64

    @State private var accountId: String?
    @State private var messages: [MessageRecord] = []
    // A `Set`, not a single optional id: each header toggles its own
    // message independently (the usual thread-view UX — think Gmail/Apple
    // Mail, where expanding an older message doesn't collapse the one you
    // were already reading), not an accordion where only one can be open
    // at a time.
    @State private var expandedMessageIds: Set<Int64> = []
    @State private var hasPinnedInitialExpansion = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(messages) { message in
                    if let messageId = message.id {
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                withAnimation(.default) {
                                    if expandedMessageIds.contains(messageId) {
                                        expandedMessageIds.remove(messageId)
                                    } else {
                                        expandedMessageIds.insert(messageId)
                                    }
                                }
                            } label: {
                                ThreadMessageSummaryRow(message: message, isExpanded: expandedMessageIds.contains(messageId))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("threadDetail.message.\(messageId).header")

                            if expandedMessageIds.contains(messageId), let accountId {
                                MessageView(accountId: accountId, messageId: messageId)
                                    .frame(minHeight: 240)
                                    .accessibilityIdentifier("threadDetail.message.\(messageId).body")
                            }
                        }
                        Divider()
                    }
                }
            }
        }
        .accessibilityIdentifier("threadDetail.scrollView")
        .navigationTitle(navigationTitle)
        .overlay {
            if messages.isEmpty, accountId != nil {
                ContentUnavailableView("メッセージが見つかりません", systemImage: "envelope.open")
                    .accessibilityIdentifier("threadDetail.emptyState")
            }
        }
        .task(id: threadId) { await load() }
    }

    private var navigationTitle: String {
        let subject = messages.last?.subject
        return subject?.isEmpty == false ? subject! : "(件名なし)"
    }

    private func load() async {
        accountId = nil
        messages = []
        expandedMessageIds = []
        hasPinnedInitialExpansion = false

        accountId = try? await environment.database.dbWriter.read { db in
            try ThreadRecord.fetchOne(db, key: threadId)?.accountId
        }

        let observation = ThreadQuery.messagesObservation(threadId: threadId)
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                messages = fetched
                // Pin the newest message expanded exactly once, the first
                // time this thread's messages load — after that, expansion
                // is entirely up to the user's own header taps, even as
                // the live observation keeps delivering updates (e.g. a
                // flag change from opQueue replay).
                if !hasPinnedInitialExpansion, let newestId = fetched.last?.id {
                    expandedMessageIds.insert(newestId)
                    hasPinnedInitialExpansion = true
                }
            }
        } catch {
            // A failing observation just stops the view from updating
            // further; it doesn't clear what's already shown.
        }
    }
}

/// The collapsed (or about-to-collapse) one-line summary for a single
/// message within `ThreadDetailView`: sender, a snippet when collapsed,
/// date, and a disclosure chevron. Tapping it (the enclosing `Button` in
/// `ThreadDetailView`) toggles expansion.
private struct ThreadMessageSummaryRow: View {
    let message: MessageRecord
    let isExpanded: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(message.flags.contains(.seen) ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(senderText)
                    .font(.subheadline)
                    .bold()
                    .lineLimit(1)
                if !isExpanded, let snippet = message.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(message.date ?? message.internalDate, format: .dateTime.month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .padding(.horizontal)
        .contentShape(Rectangle())
    }

    private var senderText: String {
        guard let from = message.fromAddresses.first else { return "(unknown)" }
        return from.name?.isEmpty == false ? from.name! : from.address
    }
}
