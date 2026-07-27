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
/// 下書き row. "返信"/"転送"/"検索" all act on **whichever message is
/// currently expanded** (`targetMessage`) — 実機フィードバック第2弾 (E)
/// made this unambiguous by turning message expansion into a strict
/// accordion (`expandedMessageId`, exactly one message expanded at a time),
/// so "the footer toolbar's target" and "the message you're currently
/// reading" are now always the same row. Before E, any collapsed message
/// could *also* be expanded independently (a Gmail/Apple-Mail-style
/// multi-expand thread view), so the footer toolbar's target was pinned to
/// the thread's newest message regardless of which row(s) were actually
/// open — `RootView`'s macOS ⌘R shortcut still documents that older
/// "newest message" rule for its own, `ThreadDetailView`-independent
/// implementation (`RootView.replyToSelectedThread()`'s doc comment).
struct ThreadDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let threadId: Int64
    /// 実機フィードバック第3弾 (A): non-`nil` when this screen was opened
    /// from a flat-mode row (`ListDisplaySettingsStore.threadingKey` OFF —
    /// `MessageListView`'s doc comment on why a flat row still carries its
    /// *real* underlying `threadId`) — restricts `load()` to just this one
    /// message instead of every message in `threadId`, so a real
    /// (possibly multi-message) conversation opened via a flat row shows
    /// only the tapped message, not the full accordion stack. A real-device
    /// report ("スレッドをオフにしてもスレッドになる") traced to this screen
    /// always loading the whole underlying thread regardless of the
    /// flat/grouped display setting. `nil` (the pre-existing behavior) for
    /// every other entry point: a grouped-mode row, a search result (search
    /// always shows grouped threads — `MessageListView`'s flat-mode doc
    /// comment), and macOS's restored "last opened thread" (which only ever
    /// remembers a thread id, not a message id — see `RootView
    /// .lastOpenedThreadIdBySelectionKey`'s doc comment on that narrower,
    /// accepted gap).
    var singleMessageId: Int64?
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
    /// G「削除・アーカイブ時の挙動」: called (instead of always popping back)
    /// once `archiveThread()`/`junkThread()`/`deleteThread()` successfully
    /// removes this thread — the caller (whichever screen owns the
    /// currently-displayed thread order and the `selectedThreadId`/
    /// equivalent binding: `MailScreenView` on iOS, `RootView` on macOS)
    /// resolves `MessagePostActionSettingsStore`'s setting against that
    /// order and either opens the next thread or pops back, by mutating its
    /// own selection state — `ThreadDetailView` itself has no access to
    /// sibling `MessageListView`'s live thread order, so it can only ever
    /// report "this thread is gone now", never decide what comes next.
    /// `nil` (the default — `SearchScreenView`'s push, which doesn't wire
    /// this) falls back to the pre-existing unconditional `dismiss()`, so
    /// this setting simply doesn't apply to a thread opened from a search
    /// result (a separate, less central browsing order this batch didn't
    /// extend the setting to).
    var onThreadRemoved: ((Int64) -> Void)?

    @State private var accountId: String?
    @State private var messages: [MessageRecord] = []
    /// 実機フィードバック第2弾 (E): a strict accordion — at most one message
    /// expanded at a time, unlike the previous `Set<Int64>` (which let
    /// several rows stay independently expanded, Gmail/Apple-Mail-style).
    /// Tapping a collapsed message's header expands it and collapses
    /// whatever was expanded before (`toggleExpanded(_:)`); tapping the
    /// already-expanded message's header is a no-op — this app never shows
    /// zero expanded messages once a thread has loaded (`load()` always
    /// pins one), so "collapse the last one open" isn't a reachable state.
    @State private var expandedMessageId: Int64?
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
        // 表示・操作改善バッチ「ヘッダにメール件名を表示しない」: the subject
        // already renders inside each message's own header
        // (`ThreadMessageSummaryRow`/`MessageView.header(for:)`), so
        // repeating it in the navigation bar was pure duplication —
        // replaced with a generic screen title.
        .navigationTitle("メール")
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
                isExpanded: expandedMessageId == messageId,
                accountId: accountId,
                accountLabelColorKey: accountId.flatMap { id in environment.accounts.first(where: { $0.id == id })?.labelColorKey },
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

    /// `ThreadMessageRow.onToggleExpanded`'s target — 実機フィードバック第2弾
    /// (E)「アコーディオン化」: expanding `messageId` always collapses
    /// whatever was expanded before (a plain assignment, not the previous
    /// insert-or-remove-from-a-`Set` toggle). Tapping the already-expanded
    /// row's own header is a no-op (see `expandedMessageId`'s doc comment
    /// for why "nothing expanded" is never a state this screen wants).
    private func toggleExpanded(_ messageId: Int64) {
        guard expandedMessageId != messageId else { return }
        withAnimation(.default) {
            expandedMessageId = messageId
        }
    }

    /// 新画面構成 (3) → 実機フィードバック第2弾 (E): "返信"/"転送"/"検索"/「情報」
    /// が対象にするメッセージ — 常に**現在展開中の1通** (accordion なので曖昧
    /// さがない)。`expandedMessageId` に対応する `MessageRecord` が
    /// `messages` の読み込みタイミングの隙間でまだ見つからない場合だけ、
    /// スレッド内最新へフォールバックする (`RootView`'s macOS ⌘R が使う規則
    /// と同じ — その doc comment 参照)。
    private var targetMessage: MessageRecord? {
        messages.first(where: { $0.id == expandedMessageId }) ?? messages.last
    }

    private func load() async {
        accountId = nil
        messages = []
        expandedMessageId = nil
        hasPinnedInitialExpansion = false
        isThreadPinned = false
        isThreadMuted = false

        let thread = try? await environment.database.dbWriter.read { db in
            try ThreadRecord.fetchOne(db, key: threadId)
        }
        accountId = thread?.accountId
        isThreadMuted = thread?.isMuted ?? false

        if let singleMessageId {
            await loadSingleMessage(singleMessageId)
            return
        }

        isThreadPinned = thread?.isPinned ?? false
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
                    expandedMessageId = newestId
                    hasPinnedInitialExpansion = true
                }
            }
        } catch {
            // A failing observation just stops the view from updating
            // further; it doesn't clear what's already shown.
        }
    }

    /// `singleMessageId`'s load path (実機フィードバック第3弾 (A)): a live
    /// observation of just the one message, instead of `ThreadQuery
    /// .messagesObservation(threadId:)`'s whole-thread query — mirrors that
    /// method's shape (one `for try await` loop pinning expansion exactly
    /// once) so this degenerates to the exact same "one row, always
    /// expanded" rendering `messageRow(for:containerSize:)`/`ThreadMessageRow`
    /// already give a real one-message thread, no view-layer changes
    /// needed there. `isThreadPinned` reflects this one message's own
    /// `isPinnedLocal` (not the thread aggregate `ThreadRecord.isPinned` the
    /// grouped-mode path reads) — see `togglePin()`/`applyPinState(pinning:)`'s
    /// doc comment for why the toolbar's pin toggle should only ever speak
    /// for the message actually on screen here.
    private func loadSingleMessage(_ messageId: Int64) async {
        let observation = ValueObservation.tracking { db in try MessageRecord.fetchOne(db, key: messageId) }
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                guard let fetched else {
                    messages = []
                    continue
                }
                messages = [fetched]
                isThreadPinned = fetched.isPinnedLocal
                if !hasPinnedInitialExpansion {
                    expandedMessageId = fetched.id
                    hasPinnedInitialExpansion = true
                }
            }
        } catch {
            // Same as the grouped-mode path: a failing observation just
            // stops updating, it doesn't clear what's already shown.
        }
    }

    // MARK: - 新画面構成 (3): フッターツールバー

    private var footerToolbar: some View {
        MessageDetailFooterToolbar(
            onReply: { replyToTarget(replyAll: false) },
            onReplyAll: { replyToTarget(replyAll: true) },
            onForward: forwardTarget,
            onSearch: onSearchFromSender.map { callback in { openSearchFromTargetSender(callback) } },
            onInfo: { showingInfo = true },
            onDraftEnglishReply: environment.isTranslationAvailable ? { draftEnglishReplyToTarget() } : nil,
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
        if let message = targetMessage {
            MessageHeaderInfoView(
                message: message, references: infoReferences, mailboxPath: infoMailboxPath,
                contentType: infoContentType
            )
            .task { await loadInfoDetails(for: message) }
        }
    }

    private func replyToTarget(replyAll: Bool) {
        guard let id = targetMessage?.id else { return }
        onReply(id, replyAll, false)
    }

    private func draftEnglishReplyToTarget() {
        guard let id = targetMessage?.id else { return }
        onReply(id, false, true)
    }

    private func forwardTarget() {
        guard let id = targetMessage?.id else { return }
        onForward(id)
    }

    private func openSearchFromTargetSender(_ callback: (String) -> Void) {
        guard let address = targetMessage?.fromAddresses.first?.address else { return }
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
                let msgs = try Self.targetMessageRecords(threadId: threadId, singleMessageId: singleMessageId, db: db)
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
                let msgs = try Self.targetMessageRecords(threadId: threadId, singleMessageId: singleMessageId, db: db)
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

    /// Enqueues one `archive` op per message, resolved at *replay* time (not
    /// here) by `OpQueueProcessor` — same "self-heal against current server
    /// state, and branch on `account.kind` for Gmail" behavior
    /// `MessageListView.commitArchive(_:)` uses; see `OpQueueKind.archive`'s
    /// doc comment for why a pre-resolved local Archive-role mailbox lookup
    /// (this method's previous implementation) silently did nothing on a
    /// real Gmail account.
    private func archiveThread() {
        guard let accountId else { return }
        Task {
            do {
                let archived = try await environment.database.dbWriter.write { db -> Bool in
                    let msgs = try Self.targetMessageRecords(threadId: threadId, singleMessageId: singleMessageId, db: db)
                    var didArchiveAny = false
                    for message in msgs {
                        guard let messageId = message.id, let uid = UInt32(exactly: message.uid) else { continue }
                        guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId), mailbox.role != .archive else { continue }
                        try OpQueue.enqueueArchive(
                            accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                            uids: [uid], db: db
                        )
                        try FTSIndexer.delete(messageId: messageId, db: db)
                        try MessageRecord.deleteOne(db, key: messageId)
                        didArchiveAny = true
                    }
                    try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
                    return didArchiveAny
                }
                guard archived else { return }
                await replaySoon()
                notifyThreadRemoved()
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
                    let msgs = try Self.targetMessageRecords(threadId: threadId, singleMessageId: singleMessageId, db: db)
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
                notifyThreadRemoved()
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
                    let msgs = try Self.targetMessageRecords(threadId: threadId, singleMessageId: singleMessageId, db: db)
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
                notifyThreadRemoved()
            } catch {
                // Best-effort.
            }
        }
    }

    /// 実機フィードバック第3弾 (A): what "…" menu's archive/junk/delete
    /// operations should actually touch — every message in `threadId` for
    /// a grouped-mode open (unchanged), or just `singleMessageId` for a
    /// flat-mode one. Mirrors `OtegamiStore.ThreadQuery.actionTargets(for:
    /// db:)`'s exact same narrowing for `MessageListView`'s row actions —
    /// see that method's doc comment for the real-device report both fix.
    ///
    /// `nonisolated static`, taking `threadId`/`singleMessageId` as plain
    /// `Int64`/`Int64?` parameters rather than reading `self` — an
    /// *instance* method called from inside a `dbWriter.write { db in ... }`
    /// closure implicitly captures `self` (a non-`Sendable` `View`) to
    /// resolve the call, which Swift 6 strict concurrency flags as "sending
    /// 'db' risks causing data races". Plain `static` alone isn't enough
    /// either — every member of a `View`-conforming type, `static` methods
    /// included, is implicitly `@MainActor`-isolated (confirmed by `make
    /// mac`'s error switching from blaming `self` to blaming a `static`
    /// method call once this was first made `static`, then finally
    /// compiling once `nonisolated` was added), while the closure passed to
    /// `dbWriter.write` runs task-isolated, not main-actor-isolated — the
    /// exact mismatch "sending 'db' risks causing data races" describes.
    private nonisolated static func targetMessageRecords(threadId: Int64, singleMessageId: Int64?, db: Database) throws -> [MessageRecord] {
        if let singleMessageId {
            return try MessageRecord.fetchOne(db, key: singleMessageId).map { [$0] } ?? []
        }
        return try ThreadQuery.messages(threadId: threadId, db: db)
    }

    /// See `onThreadRemoved`'s doc comment: reports the removal upward when
    /// wired, falling back to this screen's own pre-existing `dismiss()`
    /// otherwise.
    ///
    /// 実機フィードバック第3弾 (A): always just `dismiss()`s for a flat-mode
    /// open (`singleMessageId != nil`), never calling `onThreadRemoved` even
    /// when it's wired — `MessagePostActionSettingsStore.nextThreadId`'s
    /// "次のメールを開く" resolves against `currentThreadOrder`, an ordered
    /// list of *real* thread ids (`MessageListView.onSummariesChanged`), not
    /// per-message ids; the caller has no way to know *which* message within
    /// the resolved next thread id should open in single-message mode, so
    /// honoring "次のメールを開く" here would silently reopen the right
    /// thread but in the wrong (full accordion) mode. Falling back to "戻る"
    /// unconditionally for this entry point is a deliberate, documented
    /// scope limit rather than an attempt to thread per-message ordering
    /// through every caller for a setting whose default is already
    /// "メール一覧に戻る".
    private func notifyThreadRemoved() {
        if let onThreadRemoved, singleMessageId == nil {
            onThreadRemoved(threadId)
        } else {
            dismiss()
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
    /// Forwarded straight to `ThreadMessageSummaryRow` — see its own doc
    /// comment on `accountLabelColorKey`.
    let accountLabelColorKey: String?
    let expandedHeight: CGFloat
    let onToggleExpanded: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                onToggleExpanded(messageId)
            } label: {
                ThreadMessageSummaryRow(message: message, isExpanded: isExpanded, accountId: accountId, accountLabelColorKey: accountLabelColorKey)
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
/// message within `ThreadDetailView`: sender (+ avatar), a snippet when
/// collapsed, date, and a disclosure chevron. Tapping it (the enclosing
/// `Button` in `ThreadDetailView`) toggles expansion.
///
/// 表示・操作改善バッチ「スレッド詳細の行にもプレビュー/アイコン」: this row
/// already showed a one-line snippet when collapsed; it now also shows
/// `SenderAvatar` (gated by the same `ListDisplaySettingsStore
/// .showAvatarInDetailKey` setting `MessageView`'s own expanded header
/// already reads — this row and that header are the same "detail screen"
/// surface from the user's point of view). Styled to read as visually
/// distinct from the top-level message list rather than identical to it —
/// per `CLAUDE.md`'s explicit requirement — via a softer `paleBase` tint
/// (vs. the list row's `surface`) and extra leading indent, rather than the
/// list row's bordered card look (`ThreadRowView.otegamiCardBackground(_:)`):
/// these rows already sit inside one continuous thread rather than being
/// separately-scannable inbox entries, so a card border here would read as
/// a contradictory "these are independent items" signal.
private struct ThreadMessageSummaryRow: View {
    let message: MessageRecord
    let isExpanded: Bool
    let accountId: String?
    /// D「アカウントのラベル色を変更可能に」: `AccountRecord.labelColorKey` for
    /// `accountId`, forwarded to `SenderAvatar` as-is.
    let accountLabelColorKey: String?

    @AppStorage(ListDisplaySettingsStore.showAvatarInDetailKey) private var showAvatar = ListDisplaySettingsStore.defaultShowAvatarInDetail

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 実機フィードバック第2弾 (E)「展開中メッセージの視覚的強調」: a 3pt
            // `OtegamiColor.accent` leading rail, present only on the
            // expanded row — the same width/treatment `AccountColorRail`
            // uses for its own "this row means something specific" signal,
            // reused here for "this is the one row the footer toolbar acts
            // on" instead of "this row's account". Laid out as a real
            // (if empty-when-collapsed) leading element rather than an
            // `.overlay`, so it never shifts this row's own content
            // horizontally when it appears/disappears.
            Rectangle()
                .fill(isExpanded ? OtegamiColor.accent : Color.clear)
                .frame(width: AccountColorRail.width)
                .accessibilityHidden(true)
            HStack(alignment: .top, spacing: OtegamiSpacing.sm) {
                UnreadDot(isUnread: !message.flags.contains(.seen))
                    .padding(.top, 6)
                if showAvatar, let accountId {
                    SenderAvatar(
                        displayName: message.fromAddresses.first?.name,
                        address: message.fromAddresses.first?.address ?? "",
                        accountId: accountId,
                        labelColorKey: accountLabelColorKey,
                        diameter: 24
                    )
                }
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
                OtegamiDateFormat.listRowText(for: message.date ?? message.internalDate)
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkTertiary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(OtegamiColor.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, OtegamiSpacing.sm)
            // `.sm` here, not the pre-E `.lg` this row used to apply to its
            // single top-level `HStack` — the leading accent rail
            // (`AccountColorRail.width`, 3pt) now accounts for part of that
            // same "extra indent vs. the top-level list row" visual
            // language (rail width + `.sm` ≈ the old `.lg`), so the total
            // indent reads about the same as before regardless of whether
            // a given row happens to be expanded (the rail's *width* is
            // always reserved; only its *color* toggles).
            .padding(.leading, OtegamiSpacing.sm)
            .padding(.trailing, OtegamiSpacing.md)
        }
        // 実機フィードバック第2弾 (E): `paleBaseStrong` (the same "強い強調地"
        // token `ThreadRowView`'s selected-row state uses) instead of the
        // collapsed default `paleBase` — see the accent rail comment above
        // for why this row specifically needs to read as visually distinct
        // from its (also `paleBase`-tinted) collapsed siblings.
        .background(isExpanded ? OtegamiColor.paleBaseStrong : OtegamiColor.paleBase)
        .contentShape(Rectangle())
    }

    private var senderText: String {
        guard let from = message.fromAddresses.first else { return "(unknown)" }
        return from.name?.isEmpty == false ? from.name! : from.address
    }
}
