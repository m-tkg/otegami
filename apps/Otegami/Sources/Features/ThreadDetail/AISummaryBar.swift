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

// MARK: - Shared floating-button chrome

// Task #78: `OtegamiFloatingButtonTone`と`otegamiFloatingButtonChrome(tone:)`
// はこのファイルではなく`apps/Otegami/Sources/DesignSystem/Components/
// OtegamiFloatingButton.swift`に昇格した — 検索・設定のフローティング
// ボタンも同じアクセント塗り+白アイコンに統一されたことで、この2つの
// 状態遷移ボタン専用に留める理由が無くなったため (そのファイルの
// doc comment参照)。
