import SwiftUI
import OtegamiCore

/// Task #123 (Spark 参考「引用履歴をメッセージ単位に分解して時系列表示」):
/// a plain-text message's quoted reply history, shown below the new body
/// text (`MessageView.content`'s plain-text branch) — a "履歴を表示/非表示"
/// text-button toggle (default: shown, never persisted — see `isExpanded`'s
/// doc comment) above a single rounded `surface` card containing one row
/// per historical message, parsed out by `QuoteHistoryParser`.
///
/// Only ever constructed with a non-empty `quotedText` — the call site
/// (`MessageView.content`) only builds this view when
/// `plainTextQuoteHistorySplit` found something to split off in the first
/// place.
///
/// Kept as its own file/type rather than inlined into `MessageView.body`
/// per this repo's CLAUDE.md rule against letting SwiftUI `body` expressions
/// grow large enough to risk the CI type-check timeout documented in
/// `docs/ci.md` — same reasoning `MessageHeaderCompactView`/
/// `AttachmentCardRow` already followed for this same view.
struct QuoteHistorySectionView: View {
    /// `QuoteStripper.SeparatedText.quotedText` — the quoted-history half of
    /// the plain-text body's split, already known non-empty by the caller.
    let quotedText: String

    /// Task #123 では「既定: 表示」で出したが、実機フィードバック
    /// (2026-07-29「履歴はデフォルトで折りたたまれていて欲しい」) で
    /// **既定: 折りたたみ**に反転した。トグルが opens をまたいで永続
    /// しない設計はそのまま — plain `@State` なので view の再生成
    /// (`MessageView.load()` の `.task(id: messageId)`) ごとに必ず
    /// `false` へ戻る。
    @State private var isExpanded = false

    private var parseResult: QuoteHistoryParser.ParseResult {
        QuoteHistoryParser.parse(quotedText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
            toggleButton
            if isExpanded {
                card
            }
        }
        .accessibilityIdentifier("messageDetail.quoteHistory")
    }

    private var toggleButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            // Static, non-dynamic label strings — plain `Text` (not
            // `Text(verbatim:)`) is fine here, unlike the sender/body text
            // below which comes from the message itself.
            Text(isExpanded ? "履歴を非表示" : "履歴を表示")
                .font(OtegamiFont.subheadline())
                .foregroundStyle(OtegamiColor.accentText)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("messageDetail.quoteHistory.toggle")
    }

    @ViewBuilder
    private var card: some View {
        switch parseResult {
        case .segments(let segments):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    QuoteHistorySegmentRow(segment: segment)
                    if index < segments.count - 1 {
                        segmentDivider
                    }
                }
            }
            .otegamiCardBackground(OtegamiColor.surface)
            .accessibilityIdentifier("messageDetail.quoteHistory.segments")
        case .unparsed(let raw):
            // Task #123's fallback contract: parsing that isn't confident
            // shows the original text untouched inside the same card,
            // rather than risking a wrong per-message split.
            Text(verbatim: raw)
                .font(OtegamiFont.body())
                .foregroundStyle(OtegamiColor.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(OtegamiSpacing.md)
                .otegamiCardBackground(OtegamiColor.surface)
                .accessibilityIdentifier("messageDetail.quoteHistory.unparsed")
        }
    }

    private var segmentDivider: some View {
        Rectangle()
            .fill(OtegamiColor.dividerSubtle)
            .frame(height: OtegamiStroke.secondary)
            .accessibilityHidden(true)
    }
}

/// One historical message inside the quote-history card: sender name
/// (bold), timestamp (if extracted), then body. Its own `View` type (not
/// inlined into `QuoteHistorySectionView.card`'s `ForEach`) for the same
/// CI type-check-timeout reason `QuoteHistorySectionView`'s own doc comment
/// cites.
///
/// `Text(verbatim:)`, not plain `Text`/`LocalizedStringKey`, for every
/// piece of message content below (`senderName`/`timestamp`/`body`/
/// `attributionText`) — these can contain bare email addresses (e.g. when
/// name extraction fell back to showing the raw attribution line), and
/// `LocalizedStringKey` Markdown-interprets a bare address into a `mailto:`
/// link — the exact bug `AccountFilterChip.swift`'s doc comment already
/// documents for this app's account-chip labels.
private struct QuoteHistorySegmentRow: View {
    let segment: QuoteHistoryParser.Segment

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            header
            if !segment.body.isEmpty {
                Text(verbatim: segment.body)
                    .font(OtegamiFont.subheadline())
                    .foregroundStyle(OtegamiColor.ink)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(OtegamiSpacing.md)
        .accessibilityIdentifier("messageDetail.quoteHistory.segment")
    }

    @ViewBuilder
    private var header: some View {
        if segment.senderName != nil || segment.timestamp != nil {
            HStack(spacing: OtegamiSpacing.xs) {
                if let senderName = segment.senderName {
                    Text(verbatim: senderName)
                        .font(OtegamiFont.subheadline().bold())
                        .foregroundStyle(OtegamiColor.ink)
                }
                if let timestamp = segment.timestamp {
                    Text(verbatim: timestamp)
                        .font(OtegamiFont.caption())
                        .foregroundStyle(OtegamiColor.inkTertiary)
                }
            }
        } else {
            // A confirmed segment boundary, but extraction couldn't pull a
            // name/timestamp out of it (e.g. a bare "----- Original
            // Message -----" separator) — show the raw attribution line so
            // this segment isn't silently unlabeled.
            Text(verbatim: segment.attributionText)
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkSecondary)
        }
    }
}
