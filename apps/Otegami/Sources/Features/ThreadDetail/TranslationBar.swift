import SwiftUI
import OtegamiStore
import OtegamiTranslation
import TranslationEngine

/// 1i's translation bar: "「英語 → 日本語（端末内で翻訳）」＋ 訳文/原文セグメント。
/// 既定は訳文、位置は常に固定". Pure presentation — every piece of state
/// (translation status, which segment is selected) lives in the parent
/// (`MessageView`), passed in as plain values/bindings, the same split
/// `MessageListRow`/`ThreadRowView` already use for "stateful orchestration
/// in the container, dumb rendering in the child" (`docs/ci.md`'s "keep
/// each row-shaped view small" discipline applies just as well to a bar-
/// shaped one).
struct TranslationBar: View {
    let state: MessageTranslationState
    @Binding var showOriginal: Bool
    /// `false` when this device/Apple Intelligence configuration can't
    /// translate at all (`AppEnvironment.isTranslationAvailable`) — the bar
    /// still renders (so a user understands *why* their English mail has no
    /// translation) but the segmented control and translate button both
    /// disable, and the label explains rather than pretending nothing's
    /// wrong.
    let isAvailable: Bool
    let onTranslate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            HStack(spacing: OtegamiSpacing.sm) {
                Image(systemName: "globe")
                    .foregroundStyle(OtegamiColor.accent)
                    .accessibilityHidden(true)
                Text(headline)
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                Spacer(minLength: OtegamiSpacing.sm)
                trailingControl
            }
            if let footnote {
                Text(footnote)
                    .font(OtegamiFont.badge())
                    .foregroundStyle(state.isFailure ? OtegamiColor.destructive : OtegamiColor.inkTertiary)
                    .accessibilityIdentifier("messageDetail.translationBar.footnote")
            }
        }
        .padding(.horizontal, OtegamiSpacing.md)
        .padding(.vertical, OtegamiSpacing.sm)
        .background(OtegamiColor.paleBase)
        .accessibilityIdentifier("messageDetail.translationBar")
    }

    private var headline: String {
        // `Text(headline)`はverbatim呼び出しなので`String(localized:)`で
        // 明示的にローカライズする (`MessageListView.title`と同じ理由)。
        isAvailable ? String(localized: "英語 → 日本語（端末内で翻訳）") : String(localized: "この端末では翻訳を利用できません")
    }

    @ViewBuilder
    private var trailingControl: some View {
        if !isAvailable {
            EmptyView()
        } else if case .translated = state {
            Picker("表示", selection: $showOriginal) {
                Text("訳文").tag(false)
                Text("原文").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("messageDetail.translationBar.segment")
        } else if state.isTranslating {
            ProgressView()
                .accessibilityIdentifier("messageDetail.translationBar.loading")
        } else {
            Button(state.isFailure ? "再試行" : "翻訳") {
                onTranslate()
            }
            .font(OtegamiFont.caption())
            .buttonStyle(.borderedProminent)
            .tint(OtegamiColor.accent)
            .controlSize(.small)
            .accessibilityIdentifier("messageDetail.translationBar.translateButton")
        }
    }

    private var footnote: String? {
        if case .failed(let message) = state {
            return "翻訳に失敗しました: \(message)"
        }
        return nil
    }
}

private extension MessageTranslationState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
