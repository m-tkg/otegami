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
}
