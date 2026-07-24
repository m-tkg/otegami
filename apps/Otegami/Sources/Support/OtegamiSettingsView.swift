import SwiftUI

#if os(macOS)
/// M10 (plan: "Settings ウィンドウ (macOS 標準 Settings scene) にアカウント/プッシュ
/// 設定を整理"). Backs `OtegamiApp`'s `Settings { }` scene (⌘,/App menu →
/// Settings…) — the platform-conventional place a macOS user expects an
/// app's preferences, distinct from (and in addition to, not replacing) the
/// gear-icon sheet `SidebarView` already opens on both platforms.
///
/// Reuses `AccountsSettingsView` for the "アカウント" tab rather than
/// duplicating its account-list/add/delete/reauth logic — its own
/// `NavigationStack` + "閉じる" toolbar button (meaningful when it's
/// presented as a sheet) become an inert no-op `dismiss()` call here (no
/// sheet presentation to dismiss), which is a minor cosmetic wart but not a
/// functional problem, and far cheaper than forking the account-list UI
/// into a second implementation that could drift from the sheet's.
/// "プッシュ通知" stays reachable through that same tab's `NavigationLink`
/// (`AccountsSettingsView`'s own `settings.pushNotificationsLink`) rather
/// than getting a third top-level tab here, for the same duplication
/// reason.
struct OtegamiSettingsView: View {
    var body: some View {
        TabView {
            AccountsSettingsView()
                .tabItem { Label("アカウント", systemImage: "person.crop.circle") }
                .accessibilityIdentifier("settings.macOS.accountsTab")

            AboutView()
                .tabItem { Label("情報", systemImage: "info.circle") }
                .accessibilityIdentifier("settings.macOS.aboutTab")
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}
#endif
