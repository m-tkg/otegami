import SwiftUI

#if os(macOS)
/// M10 (plan: "Settings ウィンドウ (macOS 標準 Settings scene) にアカウント/プッシュ
/// 設定を整理"). Backs `OtegamiApp`'s `Settings { }` scene (⌘,/App menu →
/// Settings…) — the platform-conventional place a macOS user expects an
/// app's preferences, distinct from (and in addition to, not replacing) the
/// gear-icon sheet `SidebarView` already opens on both platforms.
///
/// Reuses `AccountsListContent` (the account-list/add/delete/reauth logic
/// factored out of `AccountsSettingsView` for exactly this reason) for the
/// "アカウント" tab rather than duplicating it — but deliberately *not*
/// `AccountsSettingsView` itself, whose own `NavigationStack` caused a real,
/// confirmed-by-launching-the-app bug when nested inside this `TabView`:
/// the nested stack's toolbar conflicted with the tab switcher's, and
/// switching tabs stopped visibly swapping content (see
/// `AccountsListContent`'s doc comment for the full story). "プッシュ通知"
/// stays reachable through that same tab's `NavigationLink`
/// (`AccountsListContent`'s own `settings.pushNotificationsLink`) rather
/// than getting a third top-level tab here, to avoid duplicating that UI
/// too.
struct OtegamiSettingsView: View {
    var body: some View {
        TabView {
            NavigationStack {
                AccountsListContent()
                    .navigationTitle("アカウント")
            }
            .tabItem { Label("アカウント", systemImage: "person.crop.circle") }
            .accessibilityIdentifier("settings.macOS.accountsTab")
            .id("accountsTab")

            AboutView()
                .tabItem { Label("情報", systemImage: "info.circle") }
                .accessibilityIdentifier("settings.macOS.aboutTab")
                .id("aboutTab")
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}
#endif
