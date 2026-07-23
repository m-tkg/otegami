import SwiftUI
import OtegamiStore

/// Settings → account list (M4 plan: "設定にアカウント一覧 + 追加/削除"). Lists
/// every configured account, lets the user add another (reusing
/// `AccountSetupView`, the same sheet the sidebar's "+" button opens) or
/// delete one — deletion cascades every local row for that account (DB
/// foreign keys) and wipes its Keychain password (`AppEnvironment
/// .deleteAccount`).
struct AccountsSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var showingAccountSetup = false
    @State private var pendingDeletion: AccountRecord?

    var body: some View {
        NavigationStack {
            List {
                Section("アカウント") {
                    if environment.accounts.isEmpty {
                        Text("アカウントがありません。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(environment.accounts) { account in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName)
                                    .font(.headline)
                                Text(account.email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityIdentifier("settings.account.\(account.id)")
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingDeletion = account
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                                .accessibilityIdentifier("settings.account.\(account.id).delete")
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showingAccountSetup = true
                    } label: {
                        Label("アカウントを追加", systemImage: "plus")
                    }
                    .accessibilityIdentifier("settings.addAccountButton")
                }
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                        .accessibilityIdentifier("settings.closeButton")
                }
            }
            .alert(
                "アカウントを削除しますか？",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                presenting: pendingDeletion
            ) { account in
                Button("削除", role: .destructive) {
                    Task { await environment.deleteAccount(account) }
                }
                .accessibilityIdentifier("settings.confirmDeleteButton")
                Button("キャンセル", role: .cancel) {}
            } message: { account in
                Text("\(account.displayName) (\(account.email)) を削除すると、ローカルに保存されたメールもすべて削除されます。")
            }
        }
        .accessibilityIdentifier("settings.sheet")
        .sheet(isPresented: $showingAccountSetup) {
            AccountSetupView()
        }
    }
}
