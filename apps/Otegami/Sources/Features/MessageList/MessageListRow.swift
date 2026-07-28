import SwiftUI
import OtegamiStore
#if os(iOS)
import UIKit
#endif

/// One row inside `MessageListView`'s `List` (and, unchanged, reused by
/// `SearchTabView`'s result list) — the interactive wrapper around
/// `ThreadRowView`: tap-to-open-or-toggle-selection, D8's swipe actions,
/// 1h's long-press-to-select, and (macOS only) the right-click context
/// menu. Pulled out of `MessageListView.swift` into its own file, on top of
/// the `docs/ci.md` "keep row-shaped views small, and keep the `ForEach`
/// call site itself down to one function call" discipline that file's own
/// history already established — this row grew two swipe-related gesture
/// layers, a long-press gesture, and a conditional context menu on top of
/// what was already flagged as risky before design-phase-2, so isolating it
/// in its own file keeps `MessageListView.swift`'s own body-adjacent code
/// smaller too.
///
/// A real XCUITest regression while building this (`OtegamiM3SwipeActionsUITests
/// .testSwipeMarksMessageRead`, `row.swipeRight()` no longer revealing the
/// leading swipe action) turned out to have nothing to do with this row's
/// own code — see that test's updated doc comment: the new bottom tab bar
/// (1a, absent before design-phase-2) shrinks the message list's visible
/// height, and the specific seeded row that test targets ended up sitting
/// too close to the now-closer bottom edge for `swipeRight()` to reveal
/// reliably, the same "row too close to a viewport edge" class of issue
/// `testSwipeDeletesMessageOffline` already had to nudge around for a
/// different row. Recorded here too since it cost significant investigation
/// time to isolate from a genuine code regression.
///
/// **しきい値で自動実行バッチ**: iOS's swipe UI was rewritten from SwiftUI's
/// built-in `.swipeActions` (button-reveal, tap-to-confirm) to a custom
/// `DragGesture`-driven row that fires the action the instant the finger
/// lifts past a threshold — no button, nothing to tap. `.swipeActions` can
/// only ever auto-fire the *first declared* action in a group on a full
/// swipe (no public API for two independent distance thresholds each firing
/// a different action), which was the whole reason design-phase-2 settled
/// for "long swipe reveals a button, tap it" instead of "long swipe just
/// does it". A hand-rolled `DragGesture` has no such limitation: the row
/// tracks its own horizontal offset directly and switches which
/// `SwipeAction` is "armed" as the drag crosses `shortSwipeThreshold`/
/// `longSwipeThreshold`. See `docs/design-system.md`'s dedicated section for
/// the full design writeup (threshold values, gesture-vs-scroll
/// disambiguation, haptics, XCUITest approach) and `docs/settings.md`'s
/// "スワイプの割り当て" section for the resulting user-facing behavior
/// (delete/迷惑メール now auto-fire too — the previous "always tap to
/// confirm" guard for those two actions is gone; the undo toast is the
/// safety net instead).
struct MessageListRow: View {
    /// D8 「スワイプの割り当て」— see `SwipeActionSettingsStore`'s doc comment.
    /// Read directly via `@AppStorage` rather than threaded in as
    /// parameters (same reasoning as that type's doc comment).
    @AppStorage(SwipeActionSettingsStore.leadingShortActionKey) private var leadingShortRaw = SwipeActionSettingsStore.defaultLeadingShort.rawValue
    @AppStorage(SwipeActionSettingsStore.leadingLongActionKey) private var leadingLongRaw = SwipeActionSettingsStore.defaultLeadingLong.rawValue
    @AppStorage(SwipeActionSettingsStore.trailingShortActionKey) private var trailingShortRaw = SwipeActionSettingsStore.defaultTrailingShort.rawValue
    @AppStorage(SwipeActionSettingsStore.trailingLongActionKey) private var trailingLongRaw = SwipeActionSettingsStore.defaultTrailingLong.rawValue

    private var leadingShort: SwipeAction { SwipeAction(rawValue: leadingShortRaw) ?? SwipeActionSettingsStore.defaultLeadingShort }
    private var leadingLong: SwipeAction { SwipeAction(rawValue: leadingLongRaw) ?? SwipeActionSettingsStore.defaultLeadingLong }
    private var trailingShort: SwipeAction { SwipeAction(rawValue: trailingShortRaw) ?? SwipeActionSettingsStore.defaultTrailingShort }
    private var trailingLong: SwipeAction { SwipeAction(rawValue: trailingLongRaw) ?? SwipeActionSettingsStore.defaultTrailingLong }

    let summary: ThreadSummary
    let threadId: Int64
    /// Forwarded straight to `ThreadRowView` — see its own doc comment on
    /// `showsAccountAccent`/`accountDisplayName`.
    let accountDisplayName: String?
    /// Forwarded straight to `ThreadRowView` — see its own doc comment on
    /// `accountLabelColorKey`.
    let accountLabelColorKey: String?
    let showsAccountAccent: Bool
    let isSelecting: Bool
    let isSelected: Bool
    /// Normal (not-selecting) tap: open the thread (or, 実機フィードバック
    /// 第3弾 (A), just this one message for a flat-mode row) — takes the
    /// whole `summary` rather than just `threadId` so the caller can also
    /// read `summary.singleMessageId`.
    let onSelect: (ThreadSummary) -> Void
    /// A tap while already in selection mode: toggle this row's checkbox
    /// instead of navigating.
    let onToggleSelection: (Int64) -> Void
    /// Long press: enter selection mode with this row pre-selected. A no-op
    /// on macOS (the gesture itself is `#if os(iOS)`-only below — macOS
    /// keeps its existing right-click context menu instead, per `CLAUDE.md`
    /// ’s "macOS は既存のコンテキストメニューを維持").
    let onEnterSelection: (Int64) -> Void
    let onToggleRead: (ThreadSummary) -> Void
    let onArchive: (ThreadSummary) -> Void
    let onDelete: (ThreadSummary) -> Void
    /// D8: 迷惑メールにする — moves to the account's Junk-role mailbox (self-
    /// healing to a freshly-created "Junk" mailbox the same way delete
    /// self-heals to Trash — see `OpQueueProcessor.resolveOrCreateJunkMailbox`).
    let onJunk: (ThreadSummary) -> Void
    /// E9: ピン留め — see `MessageListView.togglePin(_:)`'s doc comment for
    /// why this toggles every message in the thread together rather than
    /// just the row's own `latestMessage`.
    let onPin: (ThreadSummary) -> Void
    let onAppear: (ThreadSummary) -> Void

    #if os(iOS)
    /// Live horizontal offset of the tappable row content while a swipe
    /// drag is in progress; `0` at rest. Positive = dragged right (leading
    /// edge revealed), negative = dragged left (trailing edge revealed).
    /// Reset to `0` (animated) the instant a drag ends, whether or not it
    /// crossed `shortSwipeThreshold` — there is no "stays revealed" state
    /// anymore, unlike the old button-reveal `.swipeActions` UI.
    @State private var dragTranslation: CGFloat = 0
    /// The last `SwipeReveal` a haptic was fired for, tracked separately
    /// from `dragTranslation` purely so `swipeGesture`'s `onChanged` can
    /// tell "did the armed action just change" apart from "the drag moved a
    /// little further within the same armed action" — only the former
    /// should buzz.
    @State private var lastHapticReveal: SwipeReveal = .none
    /// This row's own measured width (via `swipeableRow`'s `GeometryReader`
    /// background) — `commitReveal(action:direction:)` slides the row this
    /// far past its own edge so it fully leaves its own clip bounds before
    /// `perform(action)` actually removes it from the list (see that
    /// method's doc comment). Defaults to a generous placeholder so a
    /// commit that somehow lands before the first layout pass still exits
    /// convincingly rather than stopping short.
    @State private var rowWidth: CGFloat = 400
    /// スワイプ滑らかさ改善: `true` from the moment a swipe crosses its
    /// threshold and commits until `commitReveal`'s exit animation settles
    /// and `perform(action)` has run — blocks a second drag from
    /// interrupting the exit animation (the row is on its way out either
    /// way, whether or not `perform` ends up actually removing it).
    @State private var isCommitting = false
    /// Task #53 回帰修正: which action/icon `swipeActionBackground` draws —
    /// deliberately a *separate* piece of state from `dragTranslation`, only
    /// ever written from a raw (un-animated) gesture value (`onChanged`'s
    /// `value.translation`, or `commitSwipe`'s final `translation` at
    /// release) and otherwise left untouched. `dragTranslation` itself is
    /// *also* used to drive the exit-slide animation in `commitRemoval`
    /// (past the row's own edge, `Self.exitOvershoot` beyond `rowWidth` —
    /// see `commitRemoval`'s doc comment), which routinely animates it to a
    /// magnitude far past `longSwipeThreshold` even for a short swipe (e.g.
    /// a 80pt archive swipe still slides out to ~400pt+). Before this fix,
    /// `swipeActionBackground` read `reveal(for: dragTranslation)` directly,
    /// so it kept re-evaluating against that animated, spring-interpolated
    /// value as it climbed through the exit slide — crossing
    /// `longSwipeThreshold` partway through made the background/icon flip
    /// to the *long* action mid-exit even though the swipe that triggered it
    /// never came close to `longSwipeThreshold`, a real-device-reported
    /// regression from the スワイプの滑らかさ改善 pass that introduced the
    /// slide (`docs/design-system.md`'s dedicated section). Freezing this to
    /// the release-time decision (see `commitSwipe(translation:)`) instead
    /// keeps the displayed icon/color pinned to what was actually decided,
    /// independent of how far `dragTranslation` is subsequently animated for
    /// purely visual reasons.
    @State private var armedReveal: SwipeReveal = .none

    /// Below this many points of horizontal drag, releasing does nothing
    /// (the row springs back) — but the short action's color/icon already
    /// previews underneath from the very start of the drag, per the D8
    /// batch's "ドラッグ中は行の下からアクションの色 + アイコンが現れ" requirement.
    private let shortSwipeThreshold: CGFloat = 72
    /// Past this many points, the *long* action is armed instead (color +
    /// icon switch to it, plus a stronger haptic) — releasing here fires
    /// the long action.
    private let longSwipeThreshold: CGFloat = 152
    /// How far past `longSwipeThreshold` the drag may still visually
    /// rubber-band before being clamped — keeps a very fast/long drag from
    /// sliding the row content off the far edge of the screen.
    private let maxDragOvershoot: CGFloat = 40
    /// How far past this row's own trailing/leading edge `commitReveal`
    /// slides it on commit — past `rowWidth` so the content is fully
    /// clipped out of view (not just touching the edge) before the row
    /// disappears from the list for real.
    private static let exitOvershoot: CGFloat = 80
    /// How long `commitReveal`'s exit animation is given to visually
    /// settle before `perform(action)` actually mutates the database (and
    /// so removes this row from `MessageListView.summaries`) — long enough
    /// that the row is already off-screen by the time the list's own
    /// height-collapse animation (`MessageListView.applySummaries`) takes
    /// over, so the two never visibly fight each other.
    private static let exitSettleDuration: Duration = .milliseconds(240)
    #endif

    var body: some View {
        rowContent
            .accessibilityIdentifier("messageList.row.\(threadId)")
            // Design system: `List` draws its own default (system-styled)
            // separators and gives each row standard insets/background — both
            // fight `ThreadRowView`'s own flat/full-bleed styling, so this row
            // opts out of both and lets `ThreadRowView` own its full visual
            // bounds. 表示・操作改善バッチ「カード状表示」: `.listRowInsets` used to
            // carry real horizontal/vertical margin instead of `.zero` on every
            // platform — that margin *was* the gap between cards (and from the
            // screen edge), replacing the previous full-bleed-row +
            // dashed-divider look (`.otegamiRowDivider()`) with
            // `ThreadRowView.otegamiCardBackground(_:)`'s rounded, borderless
            // "面" per row (実機フィードバック第2弾 C).
            //
            // Task #67 ("メール一覧のカードの幅を画面幅に広げて欲しい", iOS
            // only per `CLAUDE.md`'s macOS-stays-as-is guidance): iOS drops
            // back to `.zero` insets so the row reaches the true screen edge —
            // `ThreadRowView.rowCornerRadius` squares off the corners to match,
            // and its own `.otegamiRowDivider()` hairline takes back over as
            // the inter-row separator now that there's no margin gap to read
            // as one. macOS is unchanged: it keeps the real margin (and the
            // rounded card it was introduced for).
            #if os(iOS)
            .listRowInsets(EdgeInsets())
            #else
            .listRowInsets(EdgeInsets(top: OtegamiSpacing.xs, leading: OtegamiSpacing.sm, bottom: OtegamiSpacing.xs, trailing: OtegamiSpacing.sm))
            #endif
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            #if os(macOS)
            .contextMenu {
                contextMenuContent
            }
            #endif
            #if os(iOS)
            // 1h: long-press enters bulk-selection mode. `.simultaneousGesture`
            // rather than `.onLongPressGesture`/`.gesture` deliberately — the
            // latter two exclusively claim the touch, which risks starving
            // this row's own `swipeGesture` (also `.simultaneousGesture`,
            // below) of the same touch-down event. `.simultaneousGesture`
            // lets both recognizers race normally — a long, mostly-vertical-
            // or-stationary press still recognizes as a long press, while a
            // horizontal drag still gets recognized by `swipeGesture` as
            // before design-phase-2 established for the (now-removed)
            // built-in `.swipeActions` recognizer.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    onEnterSelection(threadId)
                }
            )
            .onChange(of: isSelecting) { _, nowSelecting in
                // Bulk-selection mode disables swiping entirely (see
                // `swipeGesture`'s own guards) — also snap any in-flight
                // drag back to rest so a row doesn't visually stay offset
                // once selection mode takes over mid-swipe.
                if nowSelecting {
                    dragTranslation = 0
                    lastHapticReveal = .none
                    armedReveal = .none
                    isCommitting = false
                }
            }
            #endif
            .onAppear {
                onAppear(summary)
            }
    }

    @ViewBuilder
    private var rowContent: some View {
        #if os(iOS)
        swipeableRow
        #else
        rowButton
        #endif
    }

    private var rowButton: some View {
        Button(action: handleTap) {
            ThreadRowView(
                summary: summary,
                accountDisplayName: accountDisplayName,
                accountLabelColorKey: accountLabelColorKey,
                showsAccountAccent: showsAccountAccent,
                isSelecting: isSelecting,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
    }

    private func handleTap() {
        if isSelecting {
            onToggleSelection(threadId)
        } else {
            onSelect(summary)
        }
    }

    @ViewBuilder
    private var toggleReadLabel: some View {
        if summary.thread.unreadCount > 0 {
            Label("既読にする", systemImage: "envelope.open")
        } else {
            Label("未読にする", systemImage: "envelope.badge")
        }
    }

    @ViewBuilder
    private var pinLabel: some View {
        if summary.thread.isPinned {
            Label("ピン留めを解除", systemImage: "pin.slash")
        } else {
            Label("ピン留め", systemImage: "pin")
        }
    }

    /// Executes one `SwipeAction` against this row's callbacks — the iOS
    /// drag gesture's counterpart to `swipeButton(for:)` below (which
    /// builds a macOS context-menu *row*, not an executor); kept separate
    /// since the drag gesture has nothing to build a `View` for.
    private func perform(_ action: SwipeAction) {
        switch action {
        case .toggleRead: onToggleRead(summary)
        case .archive: onArchive(summary)
        case .junk: onJunk(summary)
        case .pin: onPin(summary)
        case .delete: onDelete(summary)
        }
    }

    #if os(macOS)
    /// D8: macOS has no swipe gesture, so every assignable action (not just
    /// whatever's currently assigned to a swipe slot) is always available
    /// here — `CLAUDE.md`'s "スワイプが無い macOS ではコンテキストメニューに反映する"
    /// requirement.
    @ViewBuilder
    private var contextMenuContent: some View {
        ForEach(SwipeAction.allCases) { action in
            swipeButton(for: action)
        }
    }

    /// Dispatches one `SwipeAction` to its callback/label — macOS-only now
    /// that iOS fires actions directly via `perform(_:)` instead of
    /// building a tappable `Button` per action.
    @ViewBuilder
    private func swipeButton(for action: SwipeAction) -> some View {
        switch action {
        case .toggleRead:
            Button { onToggleRead(summary) } label: { toggleReadLabel }
        case .archive:
            Button { onArchive(summary) } label: { Label(action.title, systemImage: action.systemImage) }
        case .junk:
            Button { onJunk(summary) } label: { Label(action.title, systemImage: action.systemImage) }
        case .pin:
            Button { onPin(summary) } label: { pinLabel }
        case .delete:
            Button(role: .destructive) { onDelete(summary) } label: { Label(action.title, systemImage: action.systemImage) }
        }
    }
    #endif
}

#if os(iOS)
extension MessageListRow {
    /// Which action is currently "armed" by the live drag distance — `.none`
    /// below any threshold (drag too small to have started yet), otherwise
    /// the short or long action for whichever edge the drag is headed
    /// toward. Also doubles as the value compared against
    /// `lastHapticReveal` to decide when to buzz.
    enum SwipeReveal: Equatable {
        case none
        case leading(SwipeAction, isLong: Bool)
        case trailing(SwipeAction, isLong: Bool)

        var isLong: Bool {
            switch self {
            case .none: false
            case .leading(_, let isLong), .trailing(_, let isLong): isLong
            }
        }
    }

    /// The row content (colored action background + the tappable card,
    /// offset by the live drag) plus the gesture that drives both. Split out
    /// of `body` per `docs/ci.md`'s "keep each row-shaped view's `body`
    /// small" discipline — this got noticeably larger than the old
    /// `.swipeActions`-based version, which pushed all of this complexity
    /// into SwiftUI's own implementation instead.
    var swipeableRow: some View {
        ZStack {
            swipeActionBackground
            rowButton
                .offset(x: dragTranslation)
        }
        // Task #67: square corners on iOS now that the row is full-width —
        // matches `ThreadRowView.rowCornerRadius`'s own `OtegamiRadius.none`
        // (see its doc comment). This clip itself isn't just about rounding
        // though — it's what keeps `rowButton`'s drag-offset content (and
        // `swipeActionBackground`'s full-bleed fill) from visually spilling
        // past this row's own bounds mid-swipe, so it stays even at radius 0.
        .clipShape(RoundedRectangle(cornerRadius: OtegamiRadius.none, style: .continuous))
        // スワイプ滑らかさ改善: measures this row's own width so
        // `commitReveal(action:direction:)` knows how far past its edge to
        // slide on commit (`Self.exitOvershoot` beyond it) — a
        // `GeometryReader` background rather than threading a width down
        // from `MessageListView` since every row can legitimately differ
        // (Dynamic Type, `List` insets), and this only fires on layout
        // changes (`onAppear`/`onChange`), not per drag frame.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { rowWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newValue in rowWidth = newValue }
            }
        )
        // 実機バグ報告 (動画確認済み): `.simultaneousGesture` を使っていた旧実装は
        // 「行の中身 (`rowButton`) をドラッグ量ぶんそのまま `.offset` で追従させる」
        // という表現方法のせいで、`Button` 自身の標準ドラッグキャンセル判定 (指の
        // 移動量が一定を超えたらタップを不成立にする) が働かなかった —
        // ボタンの見た目が指に完全追従するため、ボタン自身から見ると「タップ位置が
        // 一度も動いていない」ように見えてしまう。結果、スワイプでアクションが
        // 発火した直後に行のタップ (`handleTap`) も成立し、アーカイブ/削除で
        // 消えたスレッドを開こうとして本文が「見つかりません」になっていた。
        // `.highPriorityGesture` に変更: `DragGesture(minimumDistance: 20)` が
        // 実際に認識される (=しきい値以上ドラッグされる) 場合のみ `Button` 自身の
        // 既定ジェスチャーより優先され、その回のタップは完全に握り潰される。
        // `minimumDistance` 未満の本物のタップは `DragGesture` がそもそも認識
        // しないため、`Button` の通常のタップは今まで通り遷移する。`List` 側の
        // 縦スクロール用パンジェスチャーは SwiftUI の外側 (UIKit) の別レイヤーで
        // 調停されるため、ここでの優先度変更には影響されない — `onChanged` が
        // 縦方向優位のドラッグでは `dragTranslation` を更新しないことと合わせて、
        // スクロールは変わらず機能する。
        .highPriorityGesture(swipeGesture)
    }

    @ViewBuilder
    private var swipeActionBackground: some View {
        switch armedReveal {
        case .none:
            Color.clear
        case .leading(let action, let isLong):
            SwipeRevealBackground(systemImage: effectiveSystemImage(for: action), tint: effectiveTint(for: action), isLong: isLong, edge: .leading)
        case .trailing(let action, let isLong):
            SwipeRevealBackground(systemImage: effectiveSystemImage(for: action), tint: effectiveTint(for: action), isLong: isLong, edge: .trailing)
        }
    }

    /// 実機フィードバック: ピン留め済みの行をスワイプすると、プレビューの
    /// アイコンが (これから起きること = ピン留め「解除」を示す) `pin.slash` に
    /// 切り替わる — macOS コンテキストメニューの `pinLabel`/`toggleReadLabel` が
    /// 既に確立している「現在の状態に応じてラベル/アイコンを変える」流儀を
    /// iOS のスワイププレビューにも揃えた。他のアクションは状態を持たないので
    /// `SwipeAction.systemImage` をそのまま使う。
    private func effectiveSystemImage(for action: SwipeAction) -> String {
        switch action {
        case .pin: summary.thread.isPinned ? "pin.slash" : "pin"
        case .toggleRead: summary.thread.unreadCount > 0 ? "envelope.open" : "envelope.badge"
        case .archive, .junk, .delete: action.systemImage
        }
    }

    /// ピン留め済み（＝これからやるのは「解除」）は、他の色と混同しないよう
    /// 意図的に別トーンにする — 実機フィードバックの「ピン留め済みの行は別の色で
    /// 表示すること」要件。それ以外のアクションは既存の固定トーンのまま
    /// (`SwipeRevealBackground`が以前直接持っていたマッピングをここに移設)。
    private func effectiveTint(for action: SwipeAction) -> Color {
        switch action {
        case .toggleRead: OtegamiColor.accent
        case .archive: OtegamiColor.paleBaseStrongest
        case .junk: OtegamiColor.destructive
        case .pin: summary.thread.isPinned ? OtegamiColor.inkTertiary : OtegamiColor.accentText
        case .delete: OtegamiColor.destructive
        }
    }

    /// Classifies a horizontal translation into an armed action: `.none` at
    /// rest, otherwise the short action below `longSwipeThreshold` or the
    /// long action past it, on whichever edge the sign of `translationWidth`
    /// points toward. A pure function of whatever raw value is passed in —
    /// callers (`swipeGesture`'s `onChanged`, `commitSwipe(translation:)`)
    /// are what guarantee that value is always the actual gesture
    /// translation, never an animated/interpolated one; see `armedReveal`'s
    /// doc comment for why that distinction matters.
    private func reveal(for translationWidth: CGFloat) -> SwipeReveal {
        guard translationWidth != 0 else { return .none }
        let magnitude = abs(translationWidth)
        let isLongReveal = magnitude >= longSwipeThreshold
        if translationWidth > 0 {
            return .leading(isLongReveal ? leadingLong : leadingShort, isLong: isLongReveal)
        } else {
            return .trailing(isLongReveal ? trailingLong : trailingShort, isLong: isLongReveal)
        }
    }

    private func clampedTranslation(_ raw: CGFloat) -> CGFloat {
        let maxMagnitude = longSwipeThreshold + maxDragOvershoot
        return max(-maxMagnitude, min(maxMagnitude, raw))
    }

    /// D8 「しきい値で自動実行」: a plain `DragGesture` instead of
    /// `.swipeActions` — see the type's own doc comment for why. `minimumDistance:
    /// 20` keeps a plain tap (and the long-press gesture above) from ever
    /// reaching `onChanged` at all, and keeps an *actual* vertical scroll
    /// drag's very first few points from being misread as the start of a
    /// swipe before `onChanged`'s own width-vs-height check even runs.
    /// `isCommitting` additionally locks the gesture out entirely once a
    /// previous swipe has committed and is mid-exit (`commitReveal`) — a
    /// second drag on a row that's already on its way out would fight that
    /// animation instead of feeling like a fresh gesture.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { value in
                guard !isSelecting, !isCommitting else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragTranslation = clampedTranslation(value.translation.width)
                // Task #53: derived from the raw gesture value on this same
                // line, not from `dragTranslation` after it's potentially
                // been driven somewhere else by an animation — see
                // `armedReveal`'s doc comment.
                let current = reveal(for: value.translation.width)
                armedReveal = current
                if current != lastHapticReveal {
                    lastHapticReveal = current
                    if current != .none {
                        UIImpactFeedbackGenerator(style: current.isLong ? .medium : .light).impactOccurred()
                    }
                }
            }
            .onEnded { value in
                guard !isSelecting, !isCommitting else { return }
                lastHapticReveal = .none
                commitSwipe(translation: value.translation)
            }
    }

    /// Decides cancel vs. commit once the finger lifts — 「止まらずに処理
    /// して欲しい」が D8 バッチの主旨そのもの: no button, no confirmation tap.
    /// Below `shortSwipeThreshold` (or a drag that ended up more vertical
    /// than horizontal) cancels back to rest, including for delete/
    /// 迷惑メール, which used to be guarded to "tap only" via
    /// `SwipeAction.isGuardedFromFullSwipe` (removed; the undo toast
    /// `MessageListView.scheduleUndo` schedules is the safety net now, per
    /// `docs/settings.md`).
    private func commitSwipe(translation: CGSize) {
        guard abs(translation.width) > abs(translation.height), abs(translation.width) >= shortSwipeThreshold else {
            cancelSwipe()
            return
        }
        // Task #53: re-decide from the raw, final gesture translation (not
        // `dragTranslation`, which `commitReveal` below is about to start
        // animating well past this value for `.archive`/`.delete`/`.junk`)
        // and pin `armedReveal` to that decision — see its doc comment for
        // why `swipeActionBackground` must not keep re-deriving this from
        // `dragTranslation` once the exit-slide animation starts.
        let decided = reveal(for: translation.width)
        armedReveal = decided
        switch decided {
        case .none:
            cancelSwipe()
        case .leading(let action, _):
            commitReveal(action: action, direction: 1)
        case .trailing(let action, _):
            commitReveal(action: action, direction: -1)
        }
    }

    /// A swipe that didn't cross `shortSwipeThreshold` (or a drag that
    /// ended up more vertical than horizontal): spring back to rest,
    /// exactly like letting go of a rubber band — 実機報告「スワイプの挙動を
    /// sparkみたいに滑らかにして欲しい」の一部。前実装は `.easeOut(duration: 0.2)`
    /// で機械的に0へ戻していた — 一定速度で減速して停止するだけで、指を離した
    /// 勢い（バネの縮み量）を反映しない分、実機で「カクッ」と止まって見える。
    /// `interactiveSpring` はその場の変位に応じて自然に収束するため、同じ
    /// 「元に戻る」動作でも実機で明確になめらかに感じる。
    private func cancelSwipe() {
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.82)) {
            dragTranslation = 0
        } completion: {
            // Task #53: only clear the displayed icon/color once the
            // spring-back has visually settled at rest — `armedReveal` was
            // pinned (not re-derived from `dragTranslation`) at whatever it
            // was at release, so this is the one place it needs to reset
            // back to `.none` for this path.
            armedReveal = .none
        }
    }

    /// A swipe that crossed `shortSwipeThreshold`: branches on whether
    /// `action` actually removes this row from the list. `.archive`/
    /// `.delete`/`.junk` always do (the row's thread leaves whatever
    /// mailbox this list is showing); `.toggleRead`/`.pin` don't (the row
    /// stays — only its own content, e.g. the unread dot or pin indicator,
    /// changes), so there's nothing to slide away for those — firing
    /// immediately and springing back to rest, same as before this pass,
    /// is already correct for them.
    private func commitReveal(action: SwipeAction, direction: CGFloat) {
        switch action {
        case .archive, .delete, .junk:
            commitRemoval(action: action, direction: direction)
        case .toggleRead, .pin:
            perform(action)
            cancelSwipe()
        }
    }

    /// The `.archive`/`.delete`/`.junk` half of `commitReveal(action:
    /// direction:)`. Unlike the previous implementation (which snapped
    /// `dragTranslation` straight back to `0` — the *same* animation a
    /// cancelled swipe used — and, entirely separately/unsynchronized, let
    /// `perform(action)`'s resulting `MessageListView.summaries` update
    /// remove the row via `List`'s own default diff animation), this
    /// slides the row the rest of the way off its own edge first. Those
    /// two almost-overlapping "row snaps back" and "row vanishes"
    /// animations racing each other, one beat apart, was the actual source
    /// of 実機報告「スワイプしたときの挙動を sparkみたいに滑らかにして欲しい」—
    /// not the drag tracking itself (which was already 1:1 with the
    /// finger, matching every reference mail client). Sliding fully
    /// off-screen *before* mutating the database means the row is already
    /// invisible (clipped outside its own bounds — see `swipeableRow`'s
    /// `.clipShape`) by the time `MessageListView.applySummaries`'s
    /// animated removal takes over, so the two coordinate into one
    /// continuous "colored background fills the row → row slides out → the
    /// gap it leaves collapses" sequence instead of visibly fighting each
    /// other (reference frames: `swipe-smooth-frames/f011`–`f017` in the
    /// verification recording).
    private func commitRemoval(action: SwipeAction, direction: CGFloat) {
        isCommitting = true
        let exitDistance = direction * (rowWidth + Self.exitOvershoot)
        withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
            dragTranslation = exitDistance
        }
        Task {
            try? await Task.sleep(for: Self.exitSettleDuration)
            guard !Task.isCancelled else { return }
            perform(action)
            // If `perform` didn't actually remove this row from
            // `MessageListView.summaries` (a best-effort DB write failed
            // silently — see `MessageListView.commitArchive`'s doc
            // comment), snap back to rest instead of leaving it stuck
            // off-screen with no way to swipe again.
            dragTranslation = 0
            lastHapticReveal = .none
            armedReveal = .none
            isCommitting = false
        }
    }
}

/// The colored, full-bleed action layer revealed underneath the row as it's
/// dragged — a standalone `View` (not inlined into `swipeActionBackground`)
/// so its own body stays trivially type-checkable per `docs/ci.md`. Takes
/// the already-resolved `systemImage`/`tint` rather than a raw `SwipeAction`
/// — `MessageListRow.effectiveSystemImage(for:)`/`.effectiveTint(for:)`
/// account for state (e.g. ピン留め済みの行は `pin.slash` + 別トーン), which
/// needs `summary`, not available here.
private struct SwipeRevealBackground: View {
    let systemImage: String
    let tint: Color
    let isLong: Bool
    let edge: HorizontalEdge

    enum HorizontalEdge { case leading, trailing }

    var body: some View {
        // 色付き背景 + アイコンのみ — ボタンという概念は無い (実機の Gmail の
        // スワイプ挙動を参照して確定した見た目、しきい値で自動実行バッチの
        // 検証記録参照)。ラベル文字は付けない: 短い/長いの切り替えは色と
        // アイコンだけで表現する。
        HStack(spacing: 0) {
            if edge == .trailing { Spacer(minLength: 0) }
            Image(systemName: systemImage)
                .font(.system(size: isLong ? 24 : 20, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, OtegamiSpacing.xl)
            if edge == .leading { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tint)
        .accessibilityHidden(true)
    }
}
#endif
