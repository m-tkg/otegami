import SwiftUI

/// iOS's 設定画面 (新画面構成 (1)): presented as a sheet from the hamburger
/// menu's bottom row (`FolderListSheet.settingsSection`) — replaces
/// design-phase-2's dedicated 設定 tab now that the bottom tab bar is gone.
/// Reuses `AccountsSettingsView`'s `AccountsListContent`, matching macOS's
/// native Settings scene (`OtegamiSettingsView`) already reusing the same
/// content for its own "アカウント" tab, for the identical reason documented
/// on `AccountsListContent`: a pushed `NavigationLink` (`AccountEditView`)
/// composes cleanly into whichever single `NavigationStack` wraps this
/// content, so it doesn't matter whether that's a sheet (here), a
/// `TabView` tab pane (design-phase-2's now-removed tab), or a `Settings`
/// scene pane (macOS).
struct SettingsSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AccountsListContent()
                .navigationTitle("設定")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                            .accessibilityIdentifier("settingsSheet.closeButton")
                    }
                }
        }
        .tint(OtegamiColor.accent)
        .accessibilityIdentifier("settingsSheet.navigationStack")
    }
}
