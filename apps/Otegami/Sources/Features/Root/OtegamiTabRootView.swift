import SwiftUI

/// iOS's whole-app root (1a): "下部タブバー3つ（メール・検索・設定）". Replaces
/// `RootView`'s `NavigationSplitView` on this platform only — macOS keeps
/// that three-pane layout unchanged (`CLAUDE.md`: "macOS は現状の
/// `NavigationSplitView` 3ペインを維持する"). `OtegamiApp.swift`'s `RootView`
/// still owns everything platform-agnostic (scene-phase-driven IDLE loop
/// lifecycle, composer sheet presentation) and just renders this in place
/// of its own macOS-only `navigationViewWithFocusedValues` on iOS.
struct OtegamiTabRootView: View {
    var onCompose: () -> Void
    var onOpenDraft: (Int64) -> Void
    var onOpenServerDraft: (Int64) -> Void
    var onReply: (Int64, Bool) -> Void

    var body: some View {
        TabView {
            MailTabView(onCompose: onCompose, onOpenDraft: onOpenDraft, onOpenServerDraft: onOpenServerDraft, onReply: onReply)
                .tabItem {
                    Label("メール", systemImage: "envelope")
                        .accessibilityIdentifier("tabBar.mail")
                }
            SearchTabView(onReply: onReply)
                .tabItem {
                    Label("検索", systemImage: "magnifyingglass")
                        .accessibilityIdentifier("tabBar.search")
                }
            SettingsTabView()
                .tabItem {
                    Label("設定", systemImage: "gearshape")
                        .accessibilityIdentifier("tabBar.settings")
                }
        }
        .tint(OtegamiColor.accent)
    }
}
