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

    /// M6: see `AccountEntryRoute`'s doc comment.
    @State private var accountEntryRoute: AccountEntryRoute?
    @State private var pendingDeletion: AccountRecord?
    @State private var reauthenticatingAccountId: String?
    @State private var reauthErrorMessage: String?

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

                                // M6: a Gmail account whose refresh token
                                // was rejected (see `AccountRecord
                                // .needsReauth`'s doc comment) — the banner
                                // the plan calls for ("リフレッシュ失敗
                                // (invalid_grant) → ... UI バナー").
                                if account.needsReauth {
                                    HStack {
                                        Label("再認証が必要です", systemImage: "exclamationmark.triangle")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                            .accessibilityIdentifier("settings.account.\(account.id).needsReauthBanner")
                                        Spacer()
                                        Button("再認証") {
                                            Task { await reauthenticate(account) }
                                        }
                                        .font(.caption)
                                        .disabled(reauthenticatingAccountId == account.id)
                                        .accessibilityIdentifier("settings.account.\(account.id).reauthButton")
                                    }
                                }
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
                        accountEntryRoute = .typeSelection
                    } label: {
                        Label("アカウントを追加", systemImage: "plus")
                    }
                    .accessibilityIdentifier("settings.addAccountButton")
                }

                // M9: iOS-only in practice (macOS has no
                // NotificationService yet — PushNotificationSettingsView's
                // doc comment), but always reachable so a builder can see
                // why it's unavailable there rather than the entry point
                // silently vanishing.
                Section {
                    NavigationLink {
                        PushNotificationSettingsView()
                    } label: {
                        Label("プッシュ通知", systemImage: "bell.badge")
                    }
                    .accessibilityIdentifier("settings.pushNotificationsLink")
                }

                if let reauthErrorMessage {
                    Section {
                        Text(reauthErrorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("settings.reauthErrorMessage")
                    }
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
        .sheet(item: $accountEntryRoute) { route in
            accountEntryDestination(for: route, binding: $accountEntryRoute)
        }
    }

    /// Re-runs the OAuth flow for a `.gmail` account whose refresh token
    /// went stale (`AccountRecord.needsReauth`) — see `AppEnvironment
    /// .reauthenticateGmailAccount(_:)`'s doc comment.
    private func reauthenticate(_ account: AccountRecord) async {
        reauthenticatingAccountId = account.id
        reauthErrorMessage = nil
        defer { reauthenticatingAccountId = nil }

        do {
            try await environment.reauthenticateGmailAccount(account)
        } catch {
            reauthErrorMessage = "再認証に失敗しました: \(error)"
        }
    }
}
