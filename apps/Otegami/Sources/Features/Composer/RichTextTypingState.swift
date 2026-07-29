import OtegamiCore

/// Task #129 (作成画面リッチテキスト化): what the formatting bar reflects for
/// wherever the cursor/selection currently is in `ComposerView`'s body
/// editor — e.g. the Bold button lights up while editing inside already-bold
/// text, same as system rich text editors. Recomputed by
/// `RichTextEditingController` on every selection change and after every
/// formatting command; read by `RichTextFormattingBar` to drive each
/// button's highlighted state.
struct RichTextTypingState: Equatable {
    var isBold = false
    var isItalic = false
    var isUnderline = false
    var isStrikethrough = false
    var listStyle: RichTextListStyle = .none
    var indentLevel = 0
    /// Task #161 (#129 第2段): mirrors `listStyle`/`indentLevel`'s "read at
    /// the selection/cursor's start location" convention (not a
    /// whole-selection-uniform check the way bold/italic/underline/
    /// strikethrough are) — see `RichTextAttributedString.typingState(in:
    /// selectedRange:)`'s doc comment for why.
    var fontSize: RichTextFontSize = .standard
    var textColor: RichTextColor?
    var backgroundColor: RichTextColor?
    /// Non-`nil` while the cursor/selection sits inside an existing link —
    /// lets the formatting bar's link button switch to "編集"/"削除" instead
    /// of "追加" without requiring the user to re-select the linked text.
    var linkURL: String?
}
