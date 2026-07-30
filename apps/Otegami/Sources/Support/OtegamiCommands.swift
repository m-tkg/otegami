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
    @FocusedValue(\.replyAllAction) private var replyAllAction
    @FocusedValue(\.forwardAction) private var forwardAction
    @FocusedValue(\.archiveAction) private var archiveAction
    @FocusedValue(\.toggleReadAction) private var toggleReadAction
    @FocusedValue(\.deleteAction) private var deleteAction
    @FocusedValue(\.focusSearchAction) private var focusSearchAction
    @FocusedValue(\.nextMailboxAction) private var nextMailboxAction
    @FocusedValue(\.previousMailboxAction) private var previousMailboxAction
    // Task #182 (macOS アプリ内アップデート): unlike every other action
    // here, this one is independent of whatever window/view currently has
    // focus (`@FocusedValue`はここでは使わない) — it should always be
    // available from the app menu, account state or open thread aside, so
    // it opens its own dedicated window via `openWindow` directly instead.
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Task #182 (実機フィードバック「mac 版で、update のチェックができる
        // 画面は About に移動してほしい」): replaces the standard "Otegami
        // について" About panel with `AboutView` (`OtegamiApp`'s
        // `WindowGroup(id: "about")`) instead of appending an item after it
        // — Task #158's separate "アップデートを確認…" menu item (which used
        // to sit in a `CommandGroup(after: .appInfo)` here) is gone entirely;
        // its functionality moved into this same About window
        // (`AboutUpdateSection`), so there's nothing left for a second menu
        // item to do. The option-key pre-release toggle Task #158 read via
        // `NSEvent.modifierFlags` at click time doesn't apply to a menu
        // item anymore either — see `AboutUpdateSection`'s own doc comment
        // for why that became a persistent checkbox instead.
        CommandGroup(replacing: .appInfo) {
            Button("Otegamiについて") {
                openWindow(id: "about")
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("新規メッセージ") { newMessageAction?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newMessageAction == nil)
        }

        // Task #165 (macOS 操作体系再設計、ユーザー指示「iOS の操作体系を完全に
        // 忘れて Mac ネイティブに再設計してほしい」): 返信/全員に返信/転送/
        // アーカイブ/既読・未読切替/削除を1つのメニューへ集約 — 実 Apple
        // Mail.app の Message メニューに準拠したショートカット(⌘R/⇧⌘R/⇧⌘F/
        // ⇧⌘U/⌘⌫)に、Gmail系メールクライアントで広く使われる ⌘E (アーカイブ)
        // を足した組み合わせ。
        //
        // ⇧⌘F の付け替え: このメニューは元々 ⇧⌘F を「検索フィールドにフォー
        // カス」に割り当てていた(M10)。実 Mail.app の ⇧⌘F は「転送」で、
        // ユーザー指示は転送にこの組み合わせを明示的に求めた — 同じキー
        // 組み合わせを2つのコマンドで奪い合うことはできないため、検索の
        // 方を実 Mail.app の検索ショートカット ⌘F へ動かした(下の
        // `CommandGroup(after: .textEditing)`)。⌘F はこのアプリの他のどの
        // メニュー項目にも割り当てられていない(重複確認済み)。
        CommandMenu("メッセージ") {
            Button("返信") { replyAction?() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(replyAction == nil)
            Button("全員に返信") { replyAllAction?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(replyAllAction == nil)
            Button("転送") { forwardAction?() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(forwardAction == nil)
            Divider()
            // Task #165: 「E アーカイブ (Mail.app 準拠)」というユーザー指示は
            // 修飾キー無しの単独 "E" を指していたが、SwiftUI/AppKit の
            // メニューキー等価はテキストフィールドのフォーカスに関係なく
            // アプリ全体で先取りされる — 修飾キー無しの文字キーを割り当てる
            // と、件名欄・本文・検索欄に "e" を1文字打つたびにアーカイブが
            // 発火し、通常のタイピングが破壊される(HIGもこの理由で単独文字
            // キーの割り当てを避けるよう定めている)。安全な ⌘E (Airmail/
            // Spark 等、複数のネイティブ Mac メールクライアントが実際に
            // 使っているアーカイブの組み合わせ)に変更 — 実クリック検証で
            // 通常のテキスト入力に副作用が無いことを確認済み。
            Button("アーカイブ") { archiveAction?() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(archiveAction == nil)
            Button("既読/未読を切り替え") { toggleReadAction?() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(toggleReadAction == nil)
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
            // Task #165: ⇧⌘F → ⌘F (このファイルの`CommandMenu("メッセージ")`
            // 冒頭のdoc comment参照)。
            Button("検索") { focusSearchAction?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(focusSearchAction == nil)
        }
    }
}
#endif
