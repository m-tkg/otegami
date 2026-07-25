import SwiftUI

/// iOS's "設定" tab (1a): the gear-icon sheet (`AccountsSettingsView`) this
/// app previously reached from a `SidebarView` toolbar button, now a
/// permanent tab instead — matches macOS's native Settings scene
/// (`OtegamiSettingsView`) already reusing the same `AccountsListContent`
/// for its own "アカウント" tab, for the identical reason documented on
/// `AccountsListContent`: a pushed `NavigationLink` (`AccountEditView`)
/// composes cleanly into whichever single `NavigationStack` wraps this
/// content, so it doesn't matter whether that's a sheet, a `TabView` tab
/// pane, or (here) another `TabView` tab pane on the other platform.
struct SettingsTabView: View {
    var body: some View {
        NavigationStack {
            AccountsListContent()
                .navigationTitle("設定")
        }
        .accessibilityIdentifier("settingsTab.navigationStack")
    }
}
