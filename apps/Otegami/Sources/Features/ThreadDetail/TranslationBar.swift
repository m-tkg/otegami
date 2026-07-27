import SwiftUI
import OtegamiStore
import OtegamiTranslation
import TranslationEngine

/// Task #55: replaced 1i's persistent "「英語 → 日本語（端末内で翻訳）」＋
/// 訳文/原文セグメント" bar with a single small floating button — see
/// `MessageView.floatingActionButtons`'s doc comment for the shared layout/
/// placement writeup, and `docs/design-system.md`'s Task #55 section for the
/// full before/after design-decision record.
///
/// Pure presentation — every piece of state (translation status, which
/// segment is selected) still lives in the parent (`MessageView`), passed in
/// as plain values/bindings, exactly as the old bar already did. What
/// changed is *how a result is revealed*: the old bar's 訳文/原文
/// `Picker(.segmented)` had its own dedicated row to live in; this button
/// doesn't, so once translated, tapping the button itself toggles
/// `showOriginal` directly and its own tone flips between `.active` (showing
/// the translation) and `.neutral` (showing the original) to signal which
/// state a tap will switch *to* next — the button doubles as a "原文へ
/// 戻す"/"訳文に戻す" toggle instead of a separate control.
struct TranslationFloatingButton: View {
    let state: MessageTranslationState
    @Binding var showOriginal: Bool
    /// `false` when this device/Apple Intelligence configuration can't
    /// translate at all (`AppEnvironment.isTranslationAvailable`) — the
    /// button still shows (so it's discoverable) but disabled, with the
    /// reason surfaced via `accessibilityLabel` — see `AISummaryFloatingButton
    /// .isAvailable`'s identical doc comment.
    let isAvailable: Bool
    let onTranslate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            if let footnote {
                footnoteCaption(footnote)
            }
            Button(action: handleTap) {
                iconOrProgress
                    .otegamiFloatingButtonChrome(tone: tone)
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .accessibilityIdentifier("messageDetail.translationFloatingButton")
            .accessibilityLabel(Text(accessibilityLabel))
        }
    }

    @ViewBuilder
    private var iconOrProgress: some View {
        if state.isTranslating {
            ProgressView()
                .accessibilityIdentifier("messageDetail.translationFloatingButton.loading")
        } else {
            Image(systemName: "globe")
        }
    }

    /// `.active` (filled) only while a translation is *both* ready and
    /// currently the visible one (`!showOriginal`) — flips to `.neutral` the
    /// moment the user toggles back to 原文, so the button's own fill state
    /// always answers "is the translation on screen right now", not just
    /// "does one exist".
    private var tone: OtegamiFloatingButtonTone {
        guard isAvailable else { return .disabled }
        if state.isFailure { return .attention }
        if case .translated = state { return showOriginal ? .neutral : .active }
        return .neutral
    }

    private func handleTap() {
        guard isAvailable else { return }
        switch state {
        case .none, .failed:
            onTranslate()
        case .translating:
            break
        case .translated:
            showOriginal.toggle()
        }
    }

    private var accessibilityLabel: String {
        guard isAvailable else { return String(localized: "この端末では翻訳を利用できません") }
        return switch state {
        case .none: String(localized: "英語 → 日本語（端末内で翻訳）")
        case .translating: String(localized: "翻訳中")
        case .failed: String(localized: "翻訳を再試行")
        case .translated: showOriginal ? String(localized: "訳文に戻す") : String(localized: "原文に戻す")
        }
    }

    /// Task #55: the old bar's failure footnote (`"翻訳に失敗しました: ..."`)
    /// had a whole row to live in; this button doesn't have a sheet to put
    /// it in either (unlike `AISummaryFloatingButton`'s — translation
    /// applies straight to the body, there's nothing else to show a sheet
    /// *of*), so it surfaces as a small capsule caption stacked directly
    /// above the button instead — still visible to a sighted user, not just
    /// VoiceOver's `accessibilityLabel`.
    /// Not routed through `String(localized:)` — same reasoning as the old
    /// bar's identical `footnote` property had: the embedded `message` is a
    /// runtime value (`TranslationServiceError.errorDescription` or
    /// equivalent), and `Text(String)` already renders a plain `String`
    /// verbatim rather than doing a catalog lookup on it, so wrapping this
    /// in `String(localized:)` would only pretend to localize the fixed
    /// "翻訳に失敗しました: " prefix while still being unable to extract a
    /// sane catalog key for a string containing an unbounded runtime value.
    private var footnote: String? {
        if case .failed(let message) = state {
            return "翻訳に失敗しました: \(message)"
        }
        return nil
    }

    private func footnoteCaption(_ text: String) -> some View {
        Text(text)
            .font(OtegamiFont.badge())
            .foregroundStyle(.white)
            .padding(.horizontal, OtegamiSpacing.sm)
            .padding(.vertical, OtegamiSpacing.xs)
            .background(OtegamiColor.destructive, in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 240, alignment: .leading)
            .accessibilityIdentifier("messageDetail.translationFloatingButton.footnote")
    }
}

private extension MessageTranslationState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
