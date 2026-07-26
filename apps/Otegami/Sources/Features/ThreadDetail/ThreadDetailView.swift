import SwiftUI
import GRDB
import OtegamiCore
import OtegamiStore
import SyncEngine

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
///
/// 新画面構成 (3): owns the screen-level footer toolbar
/// (`MessageDetailFooterToolbar`, `.safeAreaInset(edge: .bottom)`) that
/// replaced `MessageView`'s old per-message 返信/全員に返信/英語で返信を
/// 下書き row. "返信"/"転送"/"検索" all act on the **newest** message in the
/// thread (`newestMessage`) — the same one `RootView`'s macOS ⌘R shortcut
/// already targets ("reply to whatever's currently showing expanded, not
/// an arbitrary message within the thread").
struct ThreadDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let threadId: Int64
    /// M5/design-phase-3: forwarded to each expanded `MessageView` — see
    /// its `onReply` doc comment.
    var onReply: (Int64, Bool, Bool) -> Void = { _, _, _ in }
    /// 新画面構成 (3): フッターツールバーの「転送」— see
    /// `ComposerLaunchPayload.Kind.forward`'s doc comment.
    var onForward: (Int64) -> Void = { _ in }
    /// 新画面構成 (3): フッターツールバーの「検索」— "そのメールの from で
    /// 絞り込まれた状態で開く"。`nil` だとアイコン自体を出さない
    /// (`MessageDetailFooterToolbar`'s doc comment — macOS では未配線)。
    var onSearchFromSender: ((String) -> Void)?

    @State private var accountId: String?
    @State private var messages: [MessageRecord] = []
    // A `Set`, not a single optional id: each header toggles its own
    // message independently (the usual thread-view UX — think Gmail/Apple
    // Mail, where expanding an older message doesn't collapse the one you
    // were already reading), not an accordion where only one can be open
    // at a time.
    @State private var expandedMessageIds: Set<Int64> = []
    @State private var hasPinnedInitialExpansion = false
    @State private var isThreadPinned = false
    @State private var isThreadMuted = false
    @State private var showingInfo = false
    @State private var showingToolbarSettings = false

    var body: some View {
        // `GeometryReader` here purely to hand `expandedMessageHeight(in:)`
        // a concrete size to compute off of — see its doc comment for why
        // an expanded row can't just say "fill available space" the way
        // `MessageView`/`HTMLMessageView` were originally designed to (M2,
        // before this view nested them inside a `ScrollView`).
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(messages) { message in
                            messageRow(for: message, containerSize: proxy.size)
                        }
                    }
                }
                // Bug fix: this view used to carry `.defaultScrollAnchor
                // (.bottom)` here instead of a normal top-anchored
                // `ScrollView` plus the one-shot `scrollProxy.scrollTo`
                // below. `.defaultScrollAnchor` doesn't only affect the
                // *initial* layout — SwiftUI re-applies it every time the
                // scrollable content's size changes, so it kept forcing the
                // view back to the bottom on every resize, not just once at
                // open. A plain (default top-anchored) `ScrollView` fixes
                // both — content shorter than the viewport now naturally
                // sits at the top — while `scrollProxy.scrollTo(newestId,
                // anchor: .top)` (fired exactly once per thread load, from
                // `.onChange(of: hasPinnedInitialExpansion)` below) still
                // brings a long thread's newest expanded message into view
                // on open without permanently pinning the view to the
                // bottom.
                .onChange(of: hasPinnedInitialExpansion) { _, pinned in
                    guard pinned, let newestId = messages.last?.id else { return }
                    scrollProxy.scrollTo(newestId, anchor: .top)
                }
            }
            .accessibilityIdentifier("threadDetail.scrollView")
            .background(OtegamiColor.background)
            .overlay {
                if messages.isEmpty, accountId != nil {
                    ContentUnavailableView("メッセージが見つかりません", systemImage: "envelope.open")
                        .accessibilityIdentifier("threadDetail.emptyState")
                }
            }
        }
        .navigationTitle(navigationTitle)
        .task(id: threadId) { await load() }
        .safeAreaInset(edge: .bottom) { footerToolbar }
        .sheet(isPresented: $showingInfo) { infoSheet }
        .sheet(isPresented: $showingToolbarSettings) {
            NavigationStack { MessageToolbarSettingsView() }
                .tint(OtegamiColor.accent)
        }
    }

    /// A real-device layout bug (observed on iPhone 17 Pro/iOS 26: the top
    /// ~2/3 of the screen rendering as empty background with every message
    /// row pressed to the bottom, the expanded message's body cut off at
    /// the bottom edge) traced back to `HTMLMessageView` giving its
    /// `WKWebView` `.frame(maxWidth: .infinity, maxHeight: .infinity)` — a
    /// request to "fill available space" that only means something when the
    /// immediate parent actually proposes a bounded height. Sizing directly
    /// off the container's own measured height (from the enclosing
    /// `GeometryReader`) fixes that: the web view gets a real, concrete
    /// budget to render and internally scroll within, and an expanded
    /// message reliably takes up most of the visible screen. `360` is a
    /// floor for pathologically short containers (e.g. a narrow macOS
    /// split); the `- 160` leaves room for the collapsed summary rows above
    /// an expanded message (and, 新画面構成 (3) 以降, the footer toolbar's
    /// `.safeAreaInset`, which is comfortably inside that existing margin)
    /// without the expanded row overflowing past the visible area on
    /// typical phone screens.
    private func expandedMessageHeight(in containerSize: CGSize) -> CGFloat {
        max(360, containerSize.height - 160)
    }

    /// Builds one row for the `ForEach` in `body` — pulled into its own
    /// `@ViewBuilder` method, and the row's `Button`/summary/conditional
    /// `MessageView` content into `ThreadMessageRow` below, for the same
    /// reason `SidebarView`'s `mailboxRow(for:in:)`/`MailboxRow` split
    /// exists (`docs/ci.md`'s troubleshooting notes).
    @ViewBuilder
    private func messageRow(for message: MessageRecord, containerSize: CGSize) -> some View {
        if let messageId = message.id {
            ThreadMessageRow(
                message: message,
                messageId: messageId,
                isExpanded: expandedMessageIds.contains(messageId),
                accountId: accountId,
                expandedHeight: expandedMessageHeight(in: containerSize),
                onToggleExpanded: toggleExpanded
            )
            // Design system: a 1pt dashed row separator (`OtegamiStroke
            // .secondary`/`OtegamiColor.dividerSubtle`), matching the
            // handoff's "行間 1px dashed" spacing spec.
            Rectangle()
                .fill(OtegamiColor.dividerSubtle)
                .frame(height: OtegamiStroke.secondary)
                .accessibilityHidden(true)
        }
    }

    /// `ThreadMessageRow.onToggleExpanded`'s target — the same
    /// insert-or-remove-from-`expandedMessageIds` toggle the inline
    /// `Button` action this replaced used to do directly.
    private func toggleExpanded(_ messageId: Int64) {
        withAnimation(.default) {
            if expandedMessageIds.contains(messageId) {
                expandedMessageIds.remove(messageId)
            } else {
                expandedMessageIds.insert(messageId)
            }
        }
    }

    private var navigationTitle: String {
        let subject = messages.last?.subject
        return subject?.isEmpty == false ? subject! : "(件名なし)"
    }

    /// 新画面構成 (3): "返信"/"転送"/"検索" が対象にするメッセージ — スレッド内
    /// 最新 (`messages` は oldest-first なので `.last`)。`RootView`'s macOS
    /// ⌘R が同じ規則を使っている (その doc comment 参照)。
    private var newestMessage: MessageRecord? {
        messages.last
    }

    private func load() async {
        accountId = nil
        messages = []
        expandedMessageIds = []
        hasPinnedInitialExpansion = false
        isThreadPinned = false
        isThreadMuted = false

        let thread = try? await environment.database.dbWriter.read { db in
            try ThreadRecord.fetchOne(db, key: threadId)
        }
        accountId = thread?.accountId
        isThreadPinned = thread?.isPinned ?? false
        isThreadMuted = thread?.isMuted ?? false

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

    // MARK: - 新画面構成 (3): フッターツールバー

    private var footerToolbar: some View {
        MessageDetailFooterToolbar(
            onReply: { replyToNewest(replyAll: false) },
            onReplyAll: { replyToNewest(replyAll: true) },
            onForward: forwardNewest,
            onSearch: onSearchFromSender.map { callback in { openSearchFromNewestSender(callback) } },
            onInfo: { showingInfo = true },
            onDraftEnglishReply: environment.isTranslationAvailable ? { draftEnglishReplyToNewest() } : nil,
            isMuted: isThreadMuted,
            onToggleMute: toggleMute,
            onMarkUnread: markUnread,
            onArchive: archiveThread,
            onJunk: junkThread,
            isPinned: isThreadPinned,
            onTogglePin: togglePin,
            onDelete: deleteThread,
            onCustomizeToolbar: { showingToolbarSettings = true }
        )
    }

    @ViewBuilder
    private var infoSheet: some View {
        if let message = newestMessage {
            MessageHeaderInfoView(
                message: message, references: infoReferences, mailboxPath: infoMailboxPath,
                contentType: infoContentType
            )
            .task { await loadInfoDetails(for: message) }
        }
    }

    private func replyToNewest(replyAll: Bool) {
        guard let id = newestMessage?.id else { return }
        onReply(id, replyAll, false)
    }

    private func draftEnglishReplyToNewest() {
        guard let id = newestMessage?.id else { return }
        onReply(id, false, true)
    }

    private func forwardNewest() {
        guard let id = newestMessage?.id else { return }
        onForward(id)
    }

    private func openSearchFromNewestSender(_ callback: (String) -> Void) {
        guard let address = newestMessage?.fromAddresses.first?.address else { return }
        callback("from:\(address)")
    }

    // MARK: - 新画面構成 (3): スレッド操作 ("…" メニュー)
    //
    // `MessageListView`'s equivalent row actions (`toggleRead`/
    // `archiveThread`/`junkThread`/`togglePin`/`deleteThread`) are tightly
    // coupled to that view's own undo-toast/search-results state
    // (`scheduleUndo`, `searchResults`), which this screen doesn't have —
    // rather than force this view to depend on that state just to reuse
    // the logic, these are independent, standalone implementations that
    // read `ThreadQuery`/write through `OpQueue` the exact same way, the
    // same "can't drift in behavior even though the code isn't literally
    // shared" tradeoff `RootView.deleteSelectedThread()` (macOS ⌘⌫) already
    // makes for the identical reason. Unlike `MessageListView`'s swipe
    // actions, none of these show an undo toast here — this screen instead
    // pops back to the list (`dismiss()`) once the thread's messages are
    // gone, which is itself an obvious, immediate confirmation the action
    // happened.

    private func toggleMute() {
        let muted = !isThreadMuted
        isThreadMuted = muted
        Task {
            try? await environment.database.dbWriter.write { db in
                try ThreadQuery.setMuted(threadId: threadId, muted: muted, db: db)
            }
        }
    }

    private func togglePin() {
        let pinning = !isThreadPinned
        isThreadPinned = pinning
        Task { await applyPinState(pinning: pinning) }
    }

    private func applyPinState(pinning: Bool) async {
        guard let accountId else { return }
        let syncEnabled = PinSettingsStore.isSyncWithFlaggedEnabled
        do {
            try await environment.database.dbWriter.write { db in
                let msgs = try ThreadQuery.messages(threadId: threadId, db: db)
                for var message in msgs {
                    guard message.isPinnedLocal != pinning else { continue }
                    message.isPinnedLocal = pinning
                    if syncEnabled {
                        if pinning { message.flags.insert(.flagged) } else { message.flags.remove(.flagged) }
                    }
                    message.updatedAt = Date()
                    try message.update(db)
                    guard syncEnabled, let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { continue }
                    try OpQueue.enqueueSetFlags(
                        accountId: accountId, mailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [UInt32(message.uid)], flags: message.flags, db: db
                    )
                }
                try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
            }
            if syncEnabled { await replaySoon() }
        } catch {
            // Best-effort — the toolbar's pin state just doesn't flip.
        }
    }

    private func markUnread() {
        Task { await applyReadState(markingRead: false) }
    }

    private func applyReadState(markingRead: Bool) async {
        guard let accountId else { return }
        do {
            try await environment.database.dbWriter.write { db in
                let msgs = try ThreadQuery.messages(threadId: threadId, db: db)
                for var message in msgs {
                    if markingRead {
                        guard !message.flags.contains(.seen) else { continue }
                        message.flags.insert(.seen)
                    } else {
                        guard message.flags.contains(.seen) else { continue }
                        message.flags.remove(.seen)
                    }
                    message.updatedAt = Date()
                    try message.update(db)
                    guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { continue }
                    try OpQueue.enqueueSetFlags(
                        accountId: accountId, mailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [UInt32(message.uid)], flags: message.flags, db: db
                    )
                }
                try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
            }
            await replaySoon()
        } catch {
            // Best-effort, matching every other opQueue-enqueuing path.
        }
    }

    private func archiveThread() {
        guard let accountId else { return }
        Task {
            do {
                let archived = try await environment.database.dbWriter.write { db -> Bool in
                    guard let archiveMailboxId = try MailboxRecord
                        .filter(Column("accountId") == accountId && Column("role") == MailboxRoleRecord.archive.rawValue)
                        .fetchOne(db)?.id
                    else { return false }
                    let msgs = try ThreadQuery.messages(threadId: threadId, db: db)
                    for message in msgs {
                        guard let messageId = message.id, let uid = UInt32(exactly: message.uid) else { continue }
                        guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId), mailbox.id != archiveMailboxId else { continue }
                        try OpQueue.enqueueMove(
                            accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                            uids: [uid], destinationMailboxId: archiveMailboxId, db: db
                        )
                        try FTSIndexer.delete(messageId: messageId, db: db)
                        try MessageRecord.deleteOne(db, key: messageId)
                    }
                    try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
                    return true
                }
                guard archived else { return }
                await replaySoon()
                dismiss()
            } catch {
                // Best-effort — the thread just stays if this fails.
            }
        }
    }

    private func junkThread() {
        guard let accountId else { return }
        Task {
            do {
                try await environment.database.dbWriter.write { db in
                    let msgs = try ThreadQuery.messages(threadId: threadId, db: db)
                    for message in msgs {
                        guard let messageId = message.id, let uid = UInt32(exactly: message.uid) else { continue }
                        guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { continue }
                        try OpQueue.enqueueJunk(
                            accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                            uids: [uid], db: db
                        )
                        try FTSIndexer.delete(messageId: messageId, db: db)
                        try MessageRecord.deleteOne(db, key: messageId)
                    }
                    try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
                }
                await replaySoon()
                dismiss()
            } catch {
                // Best-effort.
            }
        }
    }

    private func deleteThread() {
        guard let accountId else { return }
        Task {
            do {
                try await environment.database.dbWriter.write { db in
                    let msgs = try ThreadQuery.messages(threadId: threadId, db: db)
                    for message in msgs {
                        guard let messageId = message.id, let uid = UInt32(exactly: message.uid) else { continue }
                        guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { continue }
                        try OpQueue.enqueueDelete(
                            accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                            uids: [uid], db: db
                        )
                        try FTSIndexer.delete(messageId: messageId, db: db)
                        try MessageRecord.deleteOne(db, key: messageId)
                    }
                    try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
                }
                await replaySoon()
                dismiss()
            } catch {
                // Best-effort.
            }
        }
    }

    private func replaySoon() async {
        guard let accountId, let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
        guard let auth = try? await environment.auth(for: account) else { return }
        _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
    }

    // MARK: - 新画面構成 (3): 情報シート

    /// `MessageHeaderInfoView` の `references`/`contentType` を非同期で埋める
    /// — `infoSheet` は即座に (ネットワーク非依存の) `MessageRecord` だけで
    /// 描画してから、この `.task` で残りを補う。
    private func loadInfoDetails(for message: MessageRecord) async {
        guard let messageId = message.id else { return }
        let details = try? await environment.database.dbWriter.read { db -> (references: [String], mailboxPath: String?, isHTML: Bool) in
            let references = try MessageReferenceRecord
                .filter(Column("messageId") == messageId)
                .order(Column("position"))
                .fetchAll(db)
                .map(\.referenceValue)
            let mailboxPath = try MailboxRecord.fetchOne(db, key: message.mailboxId)?.path
            let bodyRecord = try MessageBodyRecord.fetchOne(db, key: messageId)
            let isHTML = bodyRecord?.html?.isEmpty == false
            return (references, mailboxPath, isHTML)
        }
        guard let details else { return }
        infoReferences = details.references
        infoMailboxPath = details.mailboxPath
        infoContentType = details.isHTML ? "text/html" : "text/plain"
    }

    @State private var infoReferences: [String] = []
    @State private var infoMailboxPath: String?
    @State private var infoContentType = "text/plain"
}

/// One message's row inside `ThreadDetailView`'s `LazyVStack` — the
/// `Button`/summary/conditional `MessageView` content pulled out of
/// `ThreadDetailView.body`'s `ForEach` closure (`messageRow(for:
/// containerSize:)`'s doc comment for why).
private struct ThreadMessageRow: View {
    let message: MessageRecord
    let messageId: Int64
    let isExpanded: Bool
    let accountId: String?
    let expandedHeight: CGFloat
    let onToggleExpanded: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                onToggleExpanded(messageId)
            } label: {
                ThreadMessageSummaryRow(message: message, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("threadDetail.message.\(messageId).header")

            if isExpanded, let accountId {
                MessageView(accountId: accountId, messageId: messageId)
                    .frame(height: expandedHeight)
                    .accessibilityIdentifier("threadDetail.message.\(messageId).body")
            }
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
        HStack(alignment: .top, spacing: OtegamiSpacing.sm) {
            UnreadDot(isUnread: !message.flags.contains(.seen))
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(senderText)
                    .font(OtegamiFont.headline())
                    .foregroundStyle(OtegamiColor.ink)
                    .lineLimit(1)
                if !isExpanded, let snippet = message.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(OtegamiFont.caption())
                        .foregroundStyle(OtegamiColor.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: OtegamiSpacing.sm)
            Text(message.date ?? message.internalDate, format: .dateTime.month().day().hour().minute())
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkTertiary)
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption)
                .foregroundStyle(OtegamiColor.inkTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, OtegamiSpacing.sm)
        .padding(.horizontal, OtegamiSpacing.md)
        .background(OtegamiColor.surface)
        .contentShape(Rectangle())
    }

    private var senderText: String {
        guard let from = message.fromAddresses.first else { return "(unknown)" }
        return from.name?.isEmpty == false ? from.name! : from.address
    }
}
