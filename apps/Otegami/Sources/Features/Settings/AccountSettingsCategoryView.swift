import SwiftUI
import OtegamiStore

/// I「設定画面の再構成」→「アカウントの設定」: アカウントの追加削除
/// (旧`AccountsListContent`の中身をほぼそのまま移設) + G「デフォルトの
/// アカウント設定 (新規メール作成時)」。アカウントごとのラベル色 (D) は
/// このカテゴリ画面ではなく各アカウントの編集画面 (`AccountEditView`) に
/// ある — 「アカウント全体の設定」ではなく「そのアカウント固有の見た目」
/// なので、一覧から辿った先の編集画面に置く方が一貫している。
///
/// 実機フィードバック第3弾 (I): 「その他」カテゴリから iCloud アカウント
/// 同期・プッシュ通知の2項目をここへ移設した — どちらも「アカウントの
/// 接続・同期に関する設定」という点でこのカテゴリの既存項目 (アカウント
/// 追加削除・デフォルトアカウント) と同じ性質であり、「その他」という
/// 汎用カテゴリに漠然と置いておく理由がなかった。この移設で「その他」に
/// 残る項目が「このアプリについて」だけになったため、`OtherSettingsView`
/// 自体を廃止しルート一覧の直下リンクに格上げした
/// (`AccountsListContent`の doc comment参照)。
struct AccountSettingsCategoryView: View {
    @Environment(AppEnvironment.self) private var environment

    /// M6: see `AccountEntryRoute`'s doc comment.
    @State private var accountEntryRoute: AccountEntryRoute?
    @State private var pendingDeletion: AccountRecord?
    @State private var reauthenticatingAccountId: String?
    @State private var reauthErrorMessage: String?
    /// See `AccountsListContent`'s previous doc comment (moved here
    /// verbatim) for why this pushes straight to `AccountEditView` rather
    /// than just re-checking the Keychain.
    @State private var passwordEntryAccountId: String?

    /// G「デフォルトのアカウント設定」— see `DefaultAccountSettingsStore`'s
    /// doc comment.
    @AppStorage(DefaultAccountSettingsStore.defaultAccountIdKey) private var defaultAccountId = ""

    var body: some View {
        List {
            Section("アカウント") {
                if environment.accounts.isEmpty {
                    Text("アカウントがありません。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(environment.accounts) { account in
                        NavigationLink {
                            AccountEditView(account: account)
                        } label: {
                            accountRow(for: account)
                        }
                        .accessibilityIdentifier("settings.account.\(account.id).row")
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

            // G「デフォルトのアカウント設定 (新規メール作成時)」.
            if !environment.accounts.isEmpty {
                Section {
                    Picker("デフォルトのアカウント", selection: $defaultAccountId) {
                        Text("先頭のアカウント").tag("")
                        ForEach(environment.accounts) { account in
                            Text(account.displayName).tag(account.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("settings.defaultAccountPicker")
                } header: {
                    Text("デフォルトのアカウント")
                } footer: {
                    Text("新規メール作成時の差出人の既定を選べます。削除などで無効になった場合は先頭のアカウントに戻ります。")
                }
            }

            if let reauthErrorMessage {
                Section {
                    Text(reauthErrorMessage)
                        .foregroundStyle(OtegamiColor.destructive)
                        .accessibilityIdentifier("settings.reauthErrorMessage")
                }
            }

            // 実機フィードバック第3弾 (I): 旧「その他」カテゴリから移設。
            Section {
                Toggle(
                    "iCloud でアカウントを同期",
                    isOn: Binding(
                        get: { environment.isCloudSyncEnabled },
                        set: { newValue in Task { await environment.setCloudSyncEnabled(newValue) } }
                    )
                )
                .accessibilityIdentifier("settings.cloudSyncToggle")
            } footer: {
                Text("同じ Apple ID の他の iOS/Mac デバイスとアカウントの接続設定を同期します。パスワードは iCloud キーチェーンが別途同期します。")
            }

            // M9: iOS-only in practice.
            Section {
                NavigationLink {
                    PushNotificationSettingsView()
                } label: {
                    Label("プッシュ通知", systemImage: "bell.badge")
                }
                .accessibilityIdentifier("settings.pushNotificationsLink")
            }
        }
        .navigationTitle("アカウントの設定")
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
        .sheet(item: $accountEntryRoute) { route in
            accountEntryDestination(for: route, binding: $accountEntryRoute)
        }
        .navigationDestination(item: $passwordEntryAccountId) { accountId in
            if let account = environment.accounts.first(where: { $0.id == accountId }) {
                AccountEditView(account: account)
            }
        }
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
    }

    /// One account row's content — see `AccountsListContent`'s previous
    /// identical doc comment (moved here verbatim, `docs/ci.md`'s "keep
    /// row-shaped views/closures small" precedent).
    @ViewBuilder
    private func accountRow(for account: AccountRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.displayName)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(account.email)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let lastSyncError = account.lastSyncError {
                Label(lastSyncError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .accessibilityIdentifier("settings.account.\(account.id).syncErrorBanner")
            }

            if account.needsReauth, account.authType == .oauth2 {
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
                    .buttonStyle(.borderless)
                    .disabled(reauthenticatingAccountId == account.id)
                    .accessibilityIdentifier("settings.account.\(account.id).reauthButton")
                }
            }

            if account.needsReauth, account.authType == .password {
                HStack {
                    Label("資格情報を待っています", systemImage: "icloud.and.arrow.down")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.account.\(account.id).pendingCredentialBanner")
                    Spacer()
                    Button("パスワードを入力") {
                        passwordEntryAccountId = account.id
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("settings.account.\(account.id).retryPendingCredentialButton")
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// Re-runs the OAuth flow for a `.gmail` account whose refresh token
    /// went stale — see `AppEnvironment.reauthenticateGmailAccount(_:)`'s
    /// doc comment.
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
