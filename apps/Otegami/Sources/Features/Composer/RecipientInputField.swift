import SwiftUI
import OtegamiCore

/// One To/Cc/Bcc field with an inline address-suggestion dropdown, sourced
/// from `RecipientOccurrence` message history (Task #200,
/// `docs/design-system.md`'s「宛先サジェスト」note has the sourcing/ranking/
/// perf decisions this feature embodies). Used by `ComposerView`'s
/// `addressSection` (macOS) and `flatRecipientsSection` (iOS) — split into
/// its own file/type both for reuse across those two very different layouts
/// and to keep `ComposerView.body` from growing (`docs/ci.md`'s SwiftUI
/// type-check timeout precedent).
///
/// **Layout strategy**: the dropdown renders *inline*, directly below the
/// field, expanding the row rather than floating in an overlay/popover.
/// Two reasons: (1) on macOS, this field sits directly inside a `Form`
/// `Section`, whose automatic label-left row styling
/// (`ComposerView.addressSection`'s Task #164 doc comment) this type
/// preserves by using `LabeledContent` — the same public, documented
/// primitive `Form` itself is built on — rather than a bare `TextField`
/// wrapped in a custom container, which `Form` would no longer recognize as
/// a labeled row; (2) on iOS, a `.popover`'s separate presentation context
/// risks stealing first-responder status from the `TextField` when a
/// suggestion `Button` is tapped, which would fight the "続けて次の宛先を
/// 入力できる" requirement (keep typing after picking one). An inline
/// expanding row has neither problem.
struct RecipientInputField<Trailing: View>: View {
    enum Style {
        /// macOS `Form`/`Section` styling — `LabeledContent`'s left-hand
        /// label column, matching every other row in `addressSection`.
        case labeled(LocalizedStringKey)
        /// iOS's flat, non-`Form` styling — a manually-styled `Text` label
        /// beside an untitled `TextField`, matching
        /// `flatRecipientsSection`/the old `ComposerFieldRow` it replaces.
        case flat(LocalizedStringKey)
    }

    let style: Style
    @Binding var text: String
    var prompt: Text?
    let accessibilityIdentifier: String
    /// Pre-loaded, already-deduplicated-by-nothing raw history —
    /// `ComposerView` loads this once per compose session
    /// (`RecipientSuggestionSource`, cached across sessions) and passes the
    /// same array to all three fields; this type only re-derives the
    /// *ranked, filtered* candidate list (cheap — see
    /// `RecipientSuggestionEngine`'s doc comment) on every keystroke.
    let occurrences: [RecipientOccurrence]
    /// Only meaningful for `.flat` — iOS's "Cc: Bcc:" pill button that
    /// lives in the same row as the To field until tapped
    /// (`ComposerView.isCcBccExpandedByUser`'s doc comment). Defaults to
    /// nothing via the `Trailing == EmptyView` initializer below.
    let trailing: () -> Trailing

    @FocusState private var isFocused: Bool
    @State private var highlightedIndex = 0

    init(
        style: Style,
        text: Binding<String>,
        prompt: Text? = nil,
        accessibilityIdentifier: String,
        occurrences: [RecipientOccurrence],
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.style = style
        self._text = text
        self.prompt = prompt
        self.accessibilityIdentifier = accessibilityIdentifier
        self.occurrences = occurrences
        self.trailing = trailing
    }

    private var suggestions: [RecipientSuggestion] {
        guard isFocused else { return [] }
        return RecipientSuggestionEngine.suggestions(for: Self.activeToken(in: text), occurrences: occurrences)
    }

    var body: some View {
        Group {
            switch style {
            case .labeled(let label):
                LabeledContent(label) {
                    VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
                        textField
                        suggestionRows
                    }
                }
            case .flat(let label):
                VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
                    HStack(spacing: OtegamiSpacing.sm) {
                        Text(label)
                            .font(OtegamiFont.subheadline())
                            .foregroundStyle(OtegamiColor.inkSecondary)
                        textField
                        trailing()
                    }
                    suggestionRows
                }
            }
        }
        .onChange(of: text) { highlightedIndex = 0 }
    }

    private var textField: some View {
        TextField("", text: $text, prompt: prompt)
            .textFieldAutocapitalizationNone()
            .accessibilityIdentifier(accessibilityIdentifier)
            .focused($isFocused)
            #if os(macOS)
            .onKeyPress(.downArrow) { moveHighlight(by: 1) }
            .onKeyPress(.upArrow) { moveHighlight(by: -1) }
            .onKeyPress(.return) { commitHighlighted() }
            #endif
    }

    @ViewBuilder
    private var suggestionRows: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    RecipientSuggestionRow(
                        suggestion: suggestion,
                        isHighlighted: index == highlightedIndex,
                        action: { commit(suggestion) }
                    )
                }
            }
            // Liquid Glass Phase 4 (`docs/design-system.md`「Liquid Glass 方針」):
            // このドロップダウンは本文と同じコンテンツ層 (入力候補のカード)
            // なのでガラスは使わない — 独自の不透明`surface`塗りを、
            // `MacListSearchBar`/`AccountDigestSearchBar`と同じ系統の
            // システム階層素材 (`.quinary`、控えめな塗り) へ委譲する。
            .background(.quinary)
            .overlay(alignment: .top) {
                Rectangle().fill(OtegamiColor.dividerSubtle).frame(height: 1)
            }
        }
    }

    #if os(macOS)
    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        let count = suggestions.count
        highlightedIndex = ((highlightedIndex + delta) % count + count) % count
        return .handled
    }

    private func commitHighlighted() -> KeyPress.Result {
        guard suggestions.indices.contains(highlightedIndex) else { return .ignored }
        commit(suggestions[highlightedIndex])
        return .handled
    }
    #endif

    private func commit(_ suggestion: RecipientSuggestion) {
        text = Self.applyingSuggestion(suggestion.formatted, to: text)
        highlightedIndex = 0
    }

    /// The in-progress token the current comma-separated segment holds —
    /// everything after the last comma, trimmed. `"tanaka@example.com, sat"`
    /// → `"sat"`; `"sat"` (no comma yet) → `"sat"`; a trailing `", "` (just
    /// finished a segment, nothing typed for the next one yet) → `""`,
    /// which `RecipientSuggestionEngine.suggestions(for:)` already treats
    /// as "show nothing".
    static func activeToken(in text: String) -> String {
        let segment = text.split(separator: ",", omittingEmptySubsequences: false).last.map(String.init) ?? text
        return segment.trimmingCharacters(in: .whitespaces)
    }

    /// Replaces the active token (see ``activeToken(in:)``) with `formatted`
    /// followed by `", "`, so typing can continue straight into the next
    /// recipient. Every earlier, already-completed segment is left
    /// untouched.
    static func applyingSuggestion(_ formatted: String, to text: String) -> String {
        guard let lastCommaIndex = text.lastIndex(of: ",") else {
            return formatted + ", "
        }
        let prefix = text[text.startIndex...lastCommaIndex]
        return prefix + " " + formatted + ", "
    }
}

extension RecipientInputField where Trailing == EmptyView {
    init(
        style: Style,
        text: Binding<String>,
        prompt: Text? = nil,
        accessibilityIdentifier: String,
        occurrences: [RecipientOccurrence]
    ) {
        self.init(
            style: style, text: text, prompt: prompt,
            accessibilityIdentifier: accessibilityIdentifier, occurrences: occurrences,
            trailing: { EmptyView() }
        )
    }
}

/// One suggestion row — its own `View` type per this app's "`ForEach`の中身は
/// 独立したView型に切り出す" convention (`CLAUDE.md`).
private struct RecipientSuggestionRow: View {
    let suggestion: RecipientSuggestion
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: OtegamiSpacing.sm) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(OtegamiColor.inkTertiary)
                labels
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OtegamiSpacing.sm)
            .padding(.vertical, OtegamiSpacing.xs)
            .background(isHighlighted ? OtegamiColor.paleBaseStrong : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Display name and address are both dynamic, user-derived strings
    /// (someone else's mail history) — `Text(verbatim:)`, never a
    /// `LocalizedStringKey`-driven `Text(_:)`, matching this app's
    /// documented `AccountFilterChip` lesson (an address rendered through
    /// `LocalizedStringKey` gets Markdown-interpreted into a `mailto:`
    /// link).
    @ViewBuilder
    private var labels: some View {
        if let name = suggestion.name, !name.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(OtegamiFont.body())
                    .foregroundStyle(OtegamiColor.ink)
                    .lineLimit(1)
                Text(verbatim: suggestion.address)
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .lineLimit(1)
            }
        } else {
            Text(verbatim: suggestion.address)
                .font(OtegamiFont.body())
                .foregroundStyle(OtegamiColor.ink)
                .lineLimit(1)
        }
    }
}

private extension View {
    @ViewBuilder
    func textFieldAutocapitalizationNone() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }
}
