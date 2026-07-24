import SwiftUI

/// The first screen of "アカウントを追加" (M6, plan: "種別選択: Gmail / iCloud /
/// その他 (IMAP)") — replaces M1–M5's direct jump into `AccountSetupView`.
/// Presented as the *only* sheet in the add-account flow: `SidebarView`/
/// `AccountsSettingsView` bind a single `AccountEntryRoute?` to one
/// `.sheet(item:)`, and this view's three buttons just change that route to
/// swap the sheet's *content* (`GmailAccountSetupView`/`ICloudAccountSetupView`/
/// `AccountSetupView`) rather than presenting a nested sheet on top of this
/// one — see `AccountEntryRoute`'s doc comment for why that matters: it's
/// what lets each destination form's own `@Environment(\.dismiss)` (used
/// completely unchanged from M1–M5) close the *entire* add-account flow on
/// save, not just pop back to this picker.
struct AccountTypeSelectionView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var onSelectGmail: () -> Void
    var onSelectICloud: () -> Void
    var onSelectOther: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onSelectGmail()
                    } label: {
                        Label("Gmail", systemImage: "envelope.badge")
                    }
                    .accessibilityIdentifier("accountTypeSelection.gmailButton")
                    .disabled(!environment.isGmailOAuthConfigured)

                    if !environment.isGmailOAuthConfigured {
                        Text("この配布ビルドには Google OAuth Client ID が設定されていません。docs/oauth-setup.md を参照して各自 Client ID を発行し、Config/Local.xcconfig に設定してください。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("accountTypeSelection.gmailDisabledHint")
                    }

                    Button {
                        onSelectICloud()
                    } label: {
                        Label("iCloud", systemImage: "icloud")
                    }
                    .accessibilityIdentifier("accountTypeSelection.icloudButton")

                    Button {
                        onSelectOther()
                    } label: {
                        Label("その他 (IMAP)", systemImage: "server.rack")
                    }
                    .accessibilityIdentifier("accountTypeSelection.otherButton")
                } header: {
                    Text("アカウントの種類")
                } footer: {
                    Text("Gmail と iCloud はホスト設定が自動で入力されます。それ以外のプロバイダは「その他」から手動で設定してください。")
                }
            }
            .navigationTitle("アカウントを追加")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .accessibilityIdentifier("accountTypeSelection.cancelButton")
                }
            }
        }
        .accessibilityIdentifier("accountTypeSelection.sheet")
    }
}

/// Drives the single `.sheet(item:)` `SidebarView`/`AccountsSettingsView`
/// each own for the whole add-account flow (picker → the chosen form). A
/// plain `Identifiable` enum rather than three separate `@State private var
/// showingX: Bool`s specifically so changing *which* case is bound doesn't
/// dismiss-then-represent a new sheet — see `AccountTypeSelectionView`'s
/// doc comment.
enum AccountEntryRoute: String, Identifiable {
    case typeSelection
    case gmail
    case icloud
    case other

    var id: String { rawValue }
}

/// Shared by `SidebarView` and `AccountsSettingsView` — both own an
/// identical `@State private var accountEntryRoute: AccountEntryRoute?`
/// feeding a `.sheet(item:)` (matching the pre-existing, pre-M6 duplication
/// pattern where both already independently owned a `showingAccountSetup`
/// `Bool`), so this one `@ViewBuilder` function is what keeps the
/// route→view mapping itself defined in exactly one place.
@ViewBuilder
func accountEntryDestination(for route: AccountEntryRoute, binding: Binding<AccountEntryRoute?>) -> some View {
    switch route {
    case .typeSelection:
        AccountTypeSelectionView(
            onSelectGmail: { binding.wrappedValue = .gmail },
            onSelectICloud: { binding.wrappedValue = .icloud },
            onSelectOther: { binding.wrappedValue = .other }
        )
    case .gmail:
        GmailAccountSetupView()
    case .icloud:
        ICloudAccountSetupView()
    case .other:
        AccountSetupView()
    }
}
