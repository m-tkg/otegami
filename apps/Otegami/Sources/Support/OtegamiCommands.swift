import SwiftUI

#if os(macOS)
/// M10 macOS polish (plan: "macOS メニュー/ショートカット: ⌘N 新規メール、⌘R 返信、
/// ⌘⇧F 検索フォーカス、⌘⌫ 削除、メールボックス移動。Commands API"). Reads the
/// currently-published actions via `@FocusedValue` (`AppFocusedValues.swift`)
/// rather than holding any state of its own — a `Commands` builder has no
/// view identity to own state with in the first place, and this way every
/// menu item automatically disables itself (SwiftUI's standard behavior for
/// a `Button` whose action closure is `nil`, via `.disabled` implicitly
/// following from the optional) exactly when there's nothing to act on
/// (e.g. ⌘R/⌘⌫ with no thread open), matching what a native macOS app's
/// menu bar is expected to do.
struct OtegamiCommands: Commands {
    @FocusedValue(\.newMessageAction) private var newMessageAction
    @FocusedValue(\.replyAction) private var replyAction
    @FocusedValue(\.deleteAction) private var deleteAction
    @FocusedValue(\.focusSearchAction) private var focusSearchAction
    @FocusedValue(\.nextMailboxAction) private var nextMailboxAction
    @FocusedValue(\.previousMailboxAction) private var previousMailboxAction

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新規メッセージ") { newMessageAction?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newMessageAction == nil)
        }

        CommandMenu("メッセージ") {
            Button("返信") { replyAction?() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(replyAction == nil)
            Button("削除") { deleteAction?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(deleteAction == nil)
            Divider()
            Button("次のメールボックス") { nextMailboxAction?() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(nextMailboxAction == nil)
            Button("前のメールボックス") { previousMailboxAction?() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(previousMailboxAction == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("検索") { focusSearchAction?() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(focusSearchAction == nil)
        }
    }
}
#endif
