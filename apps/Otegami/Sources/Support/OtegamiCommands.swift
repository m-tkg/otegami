import SwiftUI

#if os(macOS)
import AppKit
#endif

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
    // Task #158 (macOS「アップデートを確認」機能): unlike every other action
    // here, this one is independent of whatever window/view currently has
    // focus (`@FocusedValue`はここでは使わない) — it should always be
    // available from the app menu, account state or open thread aside, so
    // it opens its own dedicated window via `openWindow` directly instead.
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            // Spec: 通常クリック = 安定版のみ、option キーを押しながら
            // クリック = pre-release も対象。`NSEvent.modifierFlags` reads
            // the *current* global keyboard modifier state at the moment
            // this action closure runs (when the click/keyboard-shortcut
            // that selected this menu item completes) — same technique
            // several system apps use for an option-modified menu item,
            // and exactly what the task spec calls for.
            Button("アップデートを確認…") {
                let includePrereleases = NSEvent.modifierFlags.contains(.option)
                openWindow(id: "updateCheck", value: UpdateCheckRequest(includePrereleases: includePrereleases))
            }
        }

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
