import SwiftUI

/// iOS's whole-app root (新画面構成 (1)): replaces design-phase-2's bottom
/// tab bar (メール/検索/設定) with a single always-visible mail screen —
/// `MailScreenView` — plus a hamburger-menu drawer for folder navigation
/// (統合受信トレイ／アカウント別メールボックスツリー／下書き／送信待ち／
/// 同期エラー, `FolderListSheet`'s content) with 設定 pinned at the bottom of
/// that same menu (`FolderListSheet`'s doc comment). 検索 moves to a button
/// in `MailScreenView`'s own header instead of a tab
/// (`Features/Search/SearchScreenView.swift`).
///
/// macOS keeps its three-pane `NavigationSplitView` layout unchanged
/// (`CLAUDE.md`: "macOS は現状の `NavigationSplitView` 3ペインを維持する") —
/// this type is iOS-only. `OtegamiApp.swift`'s `RootView` still owns
/// everything platform-agnostic (scene-phase-driven IDLE loop lifecycle,
/// composer sheet presentation) and just renders this in place of its own
/// macOS-only `navigationViewWithFocusedValues` on iOS.
struct OtegamiRootView: View {
    var onCompose: () -> Void
    var onOpenDraft: (Int64) -> Void
    var onOpenServerDraft: (Int64) -> Void
    var onReply: (Int64, Bool) -> Void
    /// 新画面構成 (3): メール本文画面フッターツールバーの「転送」— see
    /// `ComposerLaunchPayload.Kind.forward`'s doc comment.
    var onForward: (Int64) -> Void
    /// C7 — see `MailScreenView.onOpenCancelledSend`'s doc comment.
    var onOpenCancelledSend: (PendingSendDraftSnapshot) -> Void

    var body: some View {
        MailScreenView(
            onCompose: onCompose, onOpenDraft: onOpenDraft, onOpenServerDraft: onOpenServerDraft,
            onReply: onReply, onForward: onForward, onOpenCancelledSend: onOpenCancelledSend
        )
        .tint(OtegamiColor.accent)
    }
}
