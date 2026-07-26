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
    /// M5/design-phase-3: forwarded to each expanded `MessageView` — see
    /// its `onReply` doc comment.
    var onReply: (Int64, Bool, Bool) -> Void = { _, _, _ in }

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
                // open. That produced two real, reported bugs: (1)
                // collapsing every message (shrinking the content well
                // below the viewport height) re-pinned the now-short
                // content to the bottom edge, leaving a large blank band
                // at the top instead of a natural top-aligned layout; (2)
                // opening any thread whose content taller than the
                // viewport (the common case — `expandedMessageHeight(in:)`
                // reserves most of the screen for the expanded row) always
                // started already scrolled past the top, hiding the first
                // message's header/the navigation title's expanded state
                // before the user ever touched the screen. A plain
                // (default top-anchored) `ScrollView` fixes both — content
                // shorter than the viewport now naturally sits at the top
                // — while `scrollProxy.scrollTo(newestId, anchor: .top)`
                // (fired exactly once per thread load, from `.onChange(of:
                // hasPinnedInitialExpansion)` below) still brings a long
                // thread's newest expanded message into view on open
                // without permanently pinning the view to the bottom.
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
    }

    /// A real-device layout bug (observed on iPhone 17 Pro/iOS 26: the top
    /// ~2/3 of the screen rendering as empty background with every message
    /// row pressed to the bottom, the expanded message's body cut off at
    /// the bottom edge) traced back to `HTMLMessageView` giving its
    /// `WKWebView` `.frame(maxWidth: .infinity, maxHeight: .infinity)` — a
    /// request to "fill available space" that only means something when the
    /// immediate parent actually proposes a bounded height, which was true
    /// in M2 (this view alone filling `NavigationSplitView`'s `detail`
    /// column) but stopped being true once M4 nested `MessageView` inside
    /// this view's own `ScrollView`/`LazyVStack`: a `ScrollView` proposes a
    /// *nil* height along its scroll axis by design, so "fill available
    /// space" resolves to the child's own ideal size instead — and a
    /// `WKWebView` configured to scroll internally (this view's own doc
    /// comment explains why: simpler/more robust than measuring rendered
    /// HTML height via injected JavaScript) has no meaningful intrinsic
    /// content size of its own, so it collapsed to close to zero. The
    /// previous `.frame(minHeight: 240)` around the whole `MessageView`
    /// masked this just enough to be easy to miss in a quick look (240pt
    /// total budget, header eating most of it) while still leaving the
    /// HTML body a sliver too short to show more than its first couple of
    /// lines, and the *thread's* total content height far shorter than the
    /// screen — which is exactly what turned into "empty space above,
    /// everything pinned to the bottom" once combined with the
    /// bottom-anchored scroll behavior this view used at the time (since
    /// replaced — see `body`'s doc comment on `.onChange(of:
    /// hasPinnedInitialExpansion)`).
    ///
    /// Sizing directly off the container's own measured height (from the
    /// enclosing `GeometryReader`) fixes both symptoms at once: the web
    /// view gets a real, concrete budget to render and internally scroll
    /// within, and an expanded message reliably takes up most of the
    /// visible screen — the normal "current message dominates, tap an
    /// older header to read more" thread-reading layout, not a special
    /// case to keep tuning. `360` is a floor for pathologically short
    /// containers (e.g. a narrow macOS split); the `- 160` leaves room for
    /// the collapsed summary rows above an expanded message without the
    /// expanded row overflowing past the visible area on typical phone
    /// screens.
    private func expandedMessageHeight(in containerSize: CGSize) -> CGFloat {
        max(360, containerSize.height - 160)
    }

    /// Builds one row for the `ForEach` in `body` — pulled into its own
    /// `@ViewBuilder` method, and the row's `Button`/summary/conditional
    /// `MessageView` content into `ThreadMessageRow` below, for the same
    /// reason `SidebarView`'s `mailboxRow(for:in:)`/`MailboxRow` split
    /// exists (see that pair's doc comments and docs/ci.md's
    /// troubleshooting notes): an `if let` binding, a second nested
    /// conditional binding, a multi-argument view initializer, and chained
    /// modifiers all inline inside one `ForEach` row closure is the same
    /// shape that hit `error: the compiler is unable to type-check this
    /// expression in reasonable time` on CI's toolchain for `SidebarView`.
    /// Splitting it here preemptively rather than waiting for the same
    /// failure to reproduce on this file.
    @ViewBuilder
    private func messageRow(for message: MessageRecord, containerSize: CGSize) -> some View {
        if let messageId = message.id {
            ThreadMessageRow(
                message: message,
                messageId: messageId,
                isExpanded: expandedMessageIds.contains(messageId),
                accountId: accountId,
                expandedHeight: expandedMessageHeight(in: containerSize),
                onReply: onReply,
                onToggleExpanded: toggleExpanded
            )
            // Design system: a 1pt dashed row separator (`OtegamiStroke
            // .secondary`/`OtegamiColor.dividerSubtle`), matching the
            // handoff's "行間 1px dashed" spacing spec — a standalone
            // sibling view here rather than `.otegamiRowDivider()`'s
            // overlay form, since that modifier is meant for a *single*
            // row's own bottom edge and this divider needs to sit below
            // whichever content this row currently shows (a collapsed
            // header alone, or the header plus its expanded `MessageView`).
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
    /// M5/design-phase-3: forwarded straight through to the expanded
    /// `MessageView` — see its `onReply` doc comment.
    let onReply: (Int64, Bool, Bool) -> Void
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
                MessageView(accountId: accountId, messageId: messageId, onReply: onReply)
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
