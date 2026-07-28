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
                            .tint(OtegamiColor.destructive)
                            .accessibilityIdentifier("settings.account.\(account.id).delete")
                        }
                    }
                    .onMove(perform: moveAccounts)
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

            // Task #48 (デフォルトメールアプリ対応) — see
            // `DefaultMailAppSettingsView`'s doc comment for what "既定"
            // actually requires on each platform.
            Section {
                NavigationLink {
                    DefaultMailAppSettingsView()
                } label: {
                    Label("デフォルトのメールアプリに設定", systemImage: "envelope.badge")
                }
                .accessibilityIdentifier("settings.defaultMailAppLink")
            }
        }
        .navigationTitle("アカウントの設定")
        #if os(iOS)
        // アカウントの並び替え: iOS は`EditButton`で編集モードに入ってから
        // ドラッグハンドルが出る通常の流儀 (`MessageToolbarSettingsView`の
        // doc comment が記録している「常時編集モード」の代替) —
        // このリストは並び替え専用画面ではなく `NavigationLink`
        // (`AccountEditView`への遷移) とスワイプ削除も同居しているため、
        // 常時編集モードにすると遷移・スワイプ操作を潰してしまう。
        // macOS はもとから編集モードなしでドラッグ並び替えできる
        // (`MessageToolbarSettingsView`と同じ理由) ので不要。
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
                    .accessibilityIdentifier("settings.accounts.editButton")
            }
        }
        #endif
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
        // Task #72: tap-free navigation for `scripts/verify-screen.sh` —
        // same idea as `AccountsListContent`'s
        // `-uitestsOpenAccountSettingsDirectly` hook, one screen deeper.
        // Reuses `passwordEntryAccountId`'s existing `navigationDestination
        // (item:)` above rather than adding a second one; a no-op on every
        // real launch. Both `.task` (covers the case `environment.accounts`
        // is already populated by the time this view appears) *and*
        // `.onChange` (covers the more common case: this view appears
        // before `environment`'s GRDB `ValueObservation` has delivered its
        // first `accounts` array, so the `.task` body's own read sees an
        // still-empty list) — a single `.task` alone missed the fixture
        // account the first time this was tried, since `.task` never
        // re-runs once `accounts` later updates.
        .task { openFirstAccountEditForUITestIfNeeded() }
        .onChange(of: environment.accounts.map(\.id)) { _, _ in
            openFirstAccountEditForUITestIfNeeded()
        }
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
    }

    /// One account row's content — see `AccountsListContent`'s previous
    /// identical doc comment (moved here verbatim, `docs/ci.md`'s "keep
    /// row-shaped views/closures small" precedent).
    ///
    /// Task #72「アカウント設定画面で、アカウント名の横に色を出すように」:
    /// a trailing color dot showing this account's *resolved* label color
    /// (manual pick if set, otherwise the FNV-1a auto assignment) — same
    /// placement as the reference screenshot's account-color list (dot at
    /// the row's trailing edge, roughly level with the display name). Just
    /// a preview of "this is what `AccountEditView`'s color picker
    /// currently has selected", not itself tappable — changing the color
    /// still requires opening the edit screen this row already links to.
    @ViewBuilder
    private func accountRow(for account: AccountRecord) -> some View {
        HStack(alignment: .top, spacing: OtegamiSpacing.sm) {
            accountRowContent(for: account)
            Spacer(minLength: OtegamiSpacing.sm)
            Circle()
                .fill(OtegamiAccountColor.color(for: account.id, override: account.labelColorKey))
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
                .accessibilityIdentifier("settings.account.\(account.id).colorDot")
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func accountRowContent(for account: AccountRecord) -> some View {
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

    /// アカウントの並び替え: `.onMove`'s callback — computes the reordered id
    /// list the same way `Array.move(fromOffsets:toOffset:)` would, then
    /// hands it to `AppEnvironment.reorderAccounts(_:)` to persist. Doesn't
    /// mutate any local `@State` array itself (unlike `MessageToolbarSettingsView
    /// .move`) — `environment.accounts` isn't owned by this view, it's a
    /// live `ValueObservation` result, so the list visually settles into its
    /// new order the moment that DB write commits and the observation fires
    /// again (near-instant for a local SQLite write).
    private func moveAccounts(from source: IndexSet, to destination: Int) {
        var reordered = environment.accounts
        reordered.move(fromOffsets: source, toOffset: destination)
        let orderedIds = reordered.map(\.id)
        Task { await environment.reorderAccounts(orderedIds) }
    }

    /// See the `.task`/`.onChange` pair above this view's `body` that call
    /// this — idempotent (bails via `passwordEntryAccountId == nil` once
    /// the destination is already showing) and a no-op on every real
    /// launch.
    private func openFirstAccountEditForUITestIfNeeded() {
        guard passwordEntryAccountId == nil,
              ProcessInfo.processInfo.arguments.contains("-uitestsOpenFirstAccountEditDirectly"),
              let firstAccount = environment.accounts.first else { return }
        passwordEntryAccountId = firstAccount.id
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
