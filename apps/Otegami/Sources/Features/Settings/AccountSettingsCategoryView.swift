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
///
/// Task #189 (2026-07-31): 上で移設した iCloud 同期トグルは、その後の
/// Task #186 で同期対象がアカウントの接続設定から設定全般 (表示・翻訳・
/// 通知・署名・テンプレート等) へ広がったことで「アカウントの設定」に
/// 属する項目ではなくなったため、新設した`GeneralSettingsView`(「一般」
/// カテゴリ) へ再度移設した — このカテゴリには残していない。プッシュ
/// 通知は当時は移設していなかった (アカウントごとの push watch 登録と
/// いう「アカウントの接続に関する設定」の性質が変わっていないと判断した
/// ため)。
///
/// Task #212 (実機フィードバック「push 通知の設定はアカウント設定じゃ
/// なくて一般に移した方がいいと思う」): その判断がユーザー自身によって
/// 覆り、プッシュ通知への入口も`GeneralSettingsView`へ移設した —
/// このカテゴリにはもう残っていない (`settings.pushNotificationsLink`は
/// `GeneralSettingsView`側にある)。アカウント別の push watch 状態表示
/// (`PushWatchStatusSection`) は`PushNotificationSettingsView`の中身
/// なので、画面ごと一緒に移動している。
///
/// 2026-08-02: 「デフォルトのメールアプリに設定」への入口
/// (`DefaultMailAppSettingsView`への`NavigationLink`) も同じ理由で
/// `GeneralSettingsView`へ移設した — このカテゴリにはもう残っていない。
/// iCloud 同期・プッシュ通知と同様、特定のアカウントに紐づく設定ではなく
/// アプリ全体に1つだけ効く横断的な設定のため。
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
        settingsContainer
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
    }

    /// Task #155 (macOS 設定画面フィードバック 2026-07-29) では「`Form`に
    /// 切り替えると`.onMove`のホバードラッグ並び替えが失われる懸念」から
    /// この画面だけ意図的に素の`List`のまま残していたが、2026-08-07 の
    /// macOS ネイティブ化でこの画面も`Form`+`.formStyle(.grouped)`へ揃えた
    /// — 素の`List`は区切り線が全幅のフラットな表で、`.grouped`のカード
    /// 状のセクションを使う他カテゴリと並ぶと 1 画面だけ iOS 風に見えて
    /// いた。並び替えは実機での動作確認ポイント (`.formStyle(.grouped)`の
    /// `Form`は`List`ベースの描画なので`.onMove`は保たれる想定だが、
    /// ドラッグハンドルの出方はスタイル依存)。
    @ViewBuilder
    private var settingsContainer: some View {
        #if os(macOS)
        Form {
            sections
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        #else
        List {
            sections
        }
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
        #endif
    }

    @ViewBuilder
    private var sections: some View {
            Section("アカウント") {
                if environment.accounts.isEmpty {
                    Text("アカウントがありません。")
                        .foregroundStyle(OtegamiColor.inkSecondary)
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
                        #if os(macOS)
                        // 実機バグ修正 (2026-07-29「アカウントの削除ができ
                        // ない」): `.swipeActions`はmacOS(AppKitホスト)では
                        // 効かない — `SwipeActionSettingsStore`の doc
                        // comment・`MessageListRow.contextMenuContent`が
                        // 既に確立している「macOSは右クリックの
                        // `.contextMenu`で同じアクションを出す」という
                        // このアプリの標準パターンをこの画面にも適用する。
                        // これがないと、上のswipeActionsだけではmacOSに
                        // 削除する手段が一切無かった。
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDeletion = account
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                            .accessibilityIdentifier("settings.account.\(account.id).contextDelete")
                        }
                        #endif
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
    ///
    /// Task #117「アカウント設定一覧に自分のアバターを表示」: a leading
    /// `SenderAvatar` for *this account's own address* — passing
    /// `account.email` as the resolved `address` reuses the exact same
    /// priority chain a message sender's avatar already goes through
    /// (`SenderAvatar`'s doc comment: 連絡先の写真 → Google プロフィール
    /// 写真 → Gravatar → 企業ロゴ → イニシャル), no bespoke "my own avatar"
    /// API needed. For a Gmail account this resolves to the same `people/me`
    /// self-photo `GoogleProfilePhotoAvatarResolver` already indexes
    /// alongside every other contact (Task #42「自分のプロフィール写真」
    /// doc comment, `GoogleProfilePhotoAvatarResolver.fetchAndStoreIndex`) —
    /// merged into the very index `resolveAvatarImageData(address:)` already
    /// looks `account.email` up in, so this account row gets it "for free"
    /// once that resolver's normal (non-diagnostic) path runs. Every other
    /// `AvatarSourceSettingsStore` on/off toggle (contacts/Gravatar/company
    /// logo) and the unified dark-gray backdrop + white-initials fallback
    /// apply unchanged, same as any other `SenderAvatar` call site.
    @ViewBuilder
    private func accountRow(for account: AccountRecord) -> some View {
        HStack(alignment: .top, spacing: OtegamiSpacing.sm) {
            SenderAvatar(
                displayName: account.displayName, address: account.email, accountId: account.id,
                labelColorKey: account.labelColorKey, diameter: 36
            )
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
                .font(OtegamiFont.headline())
                .foregroundStyle(OtegamiColor.ink)
            Text(account.email)
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkSecondary)

            if let lastSyncError = account.lastSyncError {
                Label(lastSyncError, systemImage: "exclamationmark.triangle")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .accessibilityIdentifier("settings.account.\(account.id).syncErrorBanner")
            }

            if account.needsReauth, account.authType == .oauth2 {
                HStack {
                    Label("再認証が必要です", systemImage: "exclamationmark.triangle")
                        .font(OtegamiFont.caption())
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.account.\(account.id).needsReauthBanner")
                    Spacer()
                    Button("再認証") {
                        Task { await reauthenticate(account) }
                    }
                    .font(OtegamiFont.caption())
                    .buttonStyle(.borderless)
                    .disabled(reauthenticatingAccountId == account.id)
                    .accessibilityIdentifier("settings.account.\(account.id).reauthButton")
                }
            }

            if account.needsReauth, account.authType == .password {
                HStack {
                    Label("資格情報を待っています", systemImage: "icloud.and.arrow.down")
                        .font(OtegamiFont.caption())
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.account.\(account.id).pendingCredentialBanner")
                    Spacer()
                    Button("パスワードを入力") {
                        passwordEntryAccountId = account.id
                    }
                    .font(OtegamiFont.caption())
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
