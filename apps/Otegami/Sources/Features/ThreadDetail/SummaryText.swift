import SwiftUI

/// Task #102 (3パート要約: ■要約/■伝えたいこと/■アクション): renders the
/// generated summary text with its "■"-prefixed label lines in a heavier
/// weight than the surrounding body text, so the three parts stay visually
/// distinct without a heavier UI change (a dedicated per-part layout,
/// markdown parsing, ...) than the sheet already had. Splits on newlines
/// and checks each line's own prefix rather than parsing any real
/// structure — the label lines are a small, fixed set coming from
/// `FoundationModelsTranslationService.summarizeInstructions`'s own
/// literal "■要約"/"■伝えたいこと"/"■アクション" strings, not user input, so
/// a plain prefix check is enough. `Text(verbatim:)`, not plain `Text`, for
/// the same reason `sourceTextForSummary()`'s callers use it elsewhere in
/// this file (`AccountFilterChip`'s doc comment): a dynamic string routed
/// through `LocalizedStringKey` gets Markdown-interpreted, which turns a
/// bare email address into a `mailto:` link.
/// Task #153: no longer `private` — `ThreadDetailView`'s whole-thread
/// summary sheet reuses this same view as-is for its own ■経緯/■現状 output
/// (a different label set, but the same "bold any `■`-prefixed line, plain
/// text otherwise" rendering applies unchanged since it only checks the
/// generic `"■"` prefix, not any specific label string).
struct SummaryText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(line.hasPrefix("■") ? OtegamiFont.body().bold() : OtegamiFont.body())
                    .foregroundStyle(OtegamiColor.ink)
            }
        }
        .textSelection(.enabled)
    }
}
