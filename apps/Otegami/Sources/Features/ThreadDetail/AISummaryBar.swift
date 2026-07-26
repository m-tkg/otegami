import SwiftUI

/// 表示・操作改善バッチ「AI要約ボタン」: `TranslationBar`と同じ「状態はすべて
/// 親 (`MessageView`) が持ち、このビューは値/バインディングを受け取って描画
/// するだけ」という分担 (`TranslationBar`のdoc comment参照)。言語に関係なく
/// どのメッセージにも出す (要約は翻訳と違って原文が日本語でも英語でも意味が
/// ある) — `isEnglishMessage`のような表示条件は持たない。翻訳バーの直前に
/// 置き、見た目のトーン (`paleBase`背景・同じフォント階層) をそろえて
/// 「本文画面に生えたAI機能」として一貫させている。
struct AISummaryBar: View {
    let state: MessageSummaryState
    let isAvailable: Bool
    let onSummarize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            HStack(spacing: OtegamiSpacing.sm) {
                Image(systemName: "sparkles")
                    .foregroundStyle(OtegamiColor.accent)
                    .accessibilityHidden(true)
                Text(headline)
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                Spacer(minLength: OtegamiSpacing.sm)
                trailingControl
            }
            if let summaryText {
                Text(summaryText)
                    .font(OtegamiFont.subheadline())
                    .foregroundStyle(OtegamiColor.ink)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("messageDetail.summaryBar.text")
            }
            if let footnote {
                Text(footnote)
                    .font(OtegamiFont.badge())
                    .foregroundStyle(OtegamiColor.destructive)
                    .accessibilityIdentifier("messageDetail.summaryBar.footnote")
            }
        }
        .padding(.horizontal, OtegamiSpacing.md)
        .padding(.vertical, OtegamiSpacing.sm)
        .background(OtegamiColor.paleBase)
        .accessibilityIdentifier("messageDetail.summaryBar")
    }

    private var headline: String {
        // `TranslationBar.headline`と同じ理由で`String(localized:)`を使う。
        isAvailable ? String(localized: "AI要約（端末内で生成）") : String(localized: "この端末では要約を利用できません")
    }

    @ViewBuilder
    private var trailingControl: some View {
        if !isAvailable {
            EmptyView()
        } else if state.isSummarizing {
            ProgressView()
                .accessibilityIdentifier("messageDetail.summaryBar.loading")
        } else {
            Button(state.isFailure || state.isSummarized ? "再生成" : "要約") {
                onSummarize()
            }
            .font(OtegamiFont.caption())
            .buttonStyle(.borderedProminent)
            .tint(OtegamiColor.accent)
            .controlSize(.small)
            .accessibilityIdentifier("messageDetail.summaryBar.summarizeButton")
        }
    }

    private var summaryText: String? {
        if case .summarized(let text) = state { return text }
        return nil
    }

    private var footnote: String? {
        if case .failed(let message) = state {
            return "要約に失敗しました: \(message)"
        }
        return nil
    }
}

/// `AISummaryBar`/`MessageView`が共有する要約の状態遷移 — `MessageTranslationState`
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
