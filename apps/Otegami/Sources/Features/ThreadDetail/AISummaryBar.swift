import SwiftUI

/// Task #55: replaced the persistent "AI要約"バー (which, together with the
/// old `TranslationBar`, used to occupy two full-width rows under the header
/// of *every* opened message, translated or not) with a single small
/// floating button — see `MessageView.floatingActionButtons`'s doc comment
/// for the shared layout/placement writeup, and `docs/design-system.md`'s
/// Task #55 section for the full before/after design-decision record.
///
/// Same "state lives in the parent, this is dumb rendering" split the old
/// bar already used (`TranslationFloatingButton`'s doc comment) — unchanged
/// by this redesign, just fewer visual states to render since there's no
/// headline/segment row anymore. Unlike the old bar, an already-summarized
/// tap doesn't re-summarize — it opens `MessageView`'s summary sheet
/// (`onShowSummary`); regenerating lives as its own button *inside* that
/// sheet instead, since a floating button only has room for one action.
struct AISummaryFloatingButton: View {
    let state: MessageSummaryState
    let isAvailable: Bool
    let onSummarize: () -> Void
    let onShowSummary: () -> Void

    var body: some View {
        Button(action: handleTap) {
            iconOrProgress
                .otegamiFloatingButtonChrome(tone: tone)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityIdentifier("messageDetail.summaryFloatingButton")
        .accessibilityLabel(Text(accessibilityLabel))
    }

    @ViewBuilder
    private var iconOrProgress: some View {
        if state.isSummarizing {
            ProgressView()
                .accessibilityIdentifier("messageDetail.summaryFloatingButton.loading")
        } else {
            Image(systemName: "sparkles")
        }
    }

    private var tone: OtegamiFloatingButtonTone {
        guard isAvailable else { return .disabled }
        if state.isFailure { return .attention }
        if state.isSummarized { return .active }
        return .neutral
    }

    /// Tapping while `.summarizing` is a harmless no-op — `onShowSummary()`
    /// still opens the sheet (which shows its own in-progress spinner), and
    /// `onSummarize()` is skipped so this never fires a second concurrent
    /// `requestSummary` (which already no-ops via `summaryTask == nil` on
    /// the caller side — this is just avoiding the redundant call, not
    /// working around a real race).
    private func handleTap() {
        guard isAvailable else { return }
        switch state {
        case .none, .failed:
            onSummarize()
        case .summarizing, .summarized:
            break
        }
        onShowSummary()
    }

    private var accessibilityLabel: String {
        guard isAvailable else { return String(localized: "この端末では要約を利用できません") }
        return switch state {
        case .none: String(localized: "要約")
        case .summarizing: String(localized: "要約中")
        case .summarized: String(localized: "要約を表示")
        case .failed: String(localized: "要約を再試行")
        }
    }
}

/// `AISummaryFloatingButton`/`MessageView`が共有する要約の状態遷移 — `MessageTranslationState`
/// (`TranslationEngine`パッケージ側)と同じ形だが、要約はキャッシュもリトライ
/// 判定もない単発の非同期呼び出しでしかないため、アプリ側にこの軽量な列挙型
/// を独自に置いている (パッケージを跨いだ共有型にするほどの複雑さがない)。
enum MessageSummaryState: Equatable {
    case none
    case summarizing
    case summarized(String)
    case failed(String)

    var isSummarizing: Bool {
        if case .summarizing = self { return true }
        return false
    }

    var isSummarized: Bool {
        if case .summarized = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Shared floating-button chrome (Task #55)

/// Which visual state a message-detail floating button is signaling —
/// shared by `AISummaryFloatingButton`/`TranslationFloatingButton` since
/// both need the same four states and neither owns the other. Deliberately
/// *not* a general-purpose design-system component (`apps/Otegami/Sources/
/// DesignSystem/`): it only expresses what these two message-detail buttons
/// need, and the two pre-existing floating buttons this chrome is visually
/// modeled on (`MailScreenView.floatingSearchButton`/`FolderListSheet
/// .floatingSettingsButton`) each still inline their own copy of this same
/// styling rather than sharing it — promoting *this* one pair to a shared
/// design-system component without also consolidating those two would just
/// leave three near-duplicate implementations instead of one, and touching
/// either of those two files is out of scope here (both had unrelated
/// in-flight edits from another change at the time this was written).
enum OtegamiFloatingButtonTone {
    /// Idle/default — visually identical to the existing floating search/
    /// settings buttons (`OtegamiColor.surface` fill, accent-tinted icon).
    case neutral
    /// A result is ready and tapping reveals/toggles it (summarized, or
    /// translated-and-currently-showing) — filled with the accent color so
    /// it reads as "on"/"active" against the neutral default.
    case active
    /// The last attempt failed — tapping retries. Bordered/iconed in
    /// `OtegamiColor.destructive` rather than filled, so it doesn't compete
    /// visually with `.active`'s "this succeeded" affordance while still
    /// standing out from `.neutral`.
    case attention
    /// This device/configuration can't do this at all right now
    /// (`isAvailable == false`) — dimmed, and the button is also disabled
    /// (`.disabled(true)` at the call site); VoiceOver still explains why
    /// via `accessibilityLabel` rather than the button silently vanishing.
    case disabled
}

extension View {
    /// The circular "surface fill + subtle border + soft shadow" chrome
    /// `MailScreenView.floatingSearchButton`/`FolderListSheet
    /// .floatingSettingsButton` each already use, parameterized by `tone`
    /// instead of being a single fixed look — see `OtegamiFloatingButtonTone`'s
    /// doc comment for why this isn't promoted to a wider shared component.
    func otegamiFloatingButtonChrome(tone: OtegamiFloatingButtonTone) -> some View {
        modifier(OtegamiFloatingButtonChromeModifier(tone: tone))
    }
}

private struct OtegamiFloatingButtonChromeModifier: ViewModifier {
    let tone: OtegamiFloatingButtonTone

    func body(content: Content) -> some View {
        content
            .font(OtegamiFont.body())
            .foregroundStyle(iconColor)
            .frame(width: OtegamiSpacing.xl, height: OtegamiSpacing.xl)
            .padding(OtegamiSpacing.md + OtegamiSpacing.xs)
            .background(backgroundColor, in: Circle())
            .overlay(Circle().stroke(borderColor, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }

    private var backgroundColor: Color {
        switch tone {
        case .neutral, .attention, .disabled: OtegamiColor.surface
        case .active: OtegamiColor.accent
        }
    }

    private var iconColor: Color {
        switch tone {
        case .neutral: OtegamiColor.accent
        case .active: .white
        case .attention: OtegamiColor.destructive
        case .disabled: OtegamiColor.inkTertiary
        }
    }

    private var borderColor: Color {
        switch tone {
        case .attention: OtegamiColor.destructive
        default: OtegamiColor.dividerSubtle
        }
    }
}
