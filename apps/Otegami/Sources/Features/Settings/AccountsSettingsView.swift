import SwiftUI
import OtegamiStore

/// Settings → account list (M4 plan: "設定にアカウント一覧 + 追加/削除"). The sheet
/// both platforms' gear-icon button opens; wraps `AccountsListContent` in
/// its own `NavigationStack` + "閉じる" toolbar button (a sheet needs an
/// explicit close affordance). See `AccountsListContent`'s doc comment for
/// why the actual list lives in its own type now.
struct AccountsSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AccountsListContent()
                .navigationTitle("設定")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                            .accessibilityIdentifier("settings.closeButton")
                    }
                }
        }
        .accessibilityIdentifier("settings.sheet")
        #if os(macOS)
        // M10 fix: see AccountTypeSelectionView's doc comment on why every
        // NavigationStack{List{...}}-shaped sheet in this app needs this.
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }
}

/// The account list itself: lists every configured account, lets the user
/// add another (reusing `AccountSetupView`, the same sheet the sidebar's
/// "+" button opens), edit one (`AccountEditView` — account edit UI), or
/// delete one — deletion cascades every local row for that account (DB
/// foreign keys) and wipes its Keychain password (`AppEnvironment
/// .deleteAccount`).
///
/// Extracted out of `AccountsSettingsView` in M10 (previously that type
/// *was* this content, wrapped directly in its own `NavigationStack`) so
/// `OtegamiSettingsView`'s macOS Settings-scene "アカウント" タブ can embed it
/// without nesting a second `NavigationStack` inside a `TabView` tab — doing
/// that was a real, confirmed-by-actually-launching-the-app bug: the nested
/// `NavigationStack`'s own toolbar conflicted with the surrounding
/// `TabView`'s tab-switcher chrome (a merged/confusing toolbar), and
/// switching tabs stopped visibly swapping the content pane at all (the
/// previously-selected tab's content just stayed on screen). Every prior
/// milestone's macOS verification was `make mac` (compile-only) — this
/// class of bug is exactly what M10's "launch it for real" requirement
/// exists to catch.
struct AccountsListContent: View {
    @Environment(AppEnvironment.self) private var environment

    /// M6: see `AccountEntryRoute`'s doc comment.
    @State private var accountEntryRoute: AccountEntryRoute?
    @State private var pendingDeletion: AccountRecord?
    @State private var reauthenticatingAccountId: String?
    @State private var reauthErrorMessage: String?
    /// Account edit UI: which account's edit sheet is open, `nil` when
    var body: some View {
        List {
            Section("アカウント") {
                if environment.accounts.isEmpty {
                    Text("アカウントがありません。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(environment.accounts) { account in
                        // Account edit UI: tapping a row pushes
                        // `AccountEditView` onto this same `NavigationStack`
                        // (`AccountsSettingsView`'s, or the macOS "アカウント"
                        // タブ's — `AccountsListContent`'s doc comment).
                        // Deliberately a `NavigationLink` push, **not**
                        // another `.sheet(item:)` (what this looked like
                        // originally) — a sheet presented from a view
                        // that's already inside `AccountsSettingsView`'s own
                        // sheet is an untested nesting depth in this app
                        // (confirmed broken by running the XCUITest suite:
                        // the tap registered but the second-level sheet
                        // never appeared, `accountEdit.sheet` timing out).
                        // `NavigationLink`, by contrast, stays inside the
                        // *same* `NavigationStack` the "プッシュ通知"/
                        // "このアプリについて" rows below already push onto
                        // successfully — a route proven by
                        // `OtegamiM9PushSettingsUITests`, which navigates
                        // through exactly this list to reach
                        // `PushNotificationSettingsView`. `AccountEditView`
                        // itself no longer wraps its content in its own
                        // `NavigationStack` (a pushed destination composes
                        // into the surrounding one; nesting a second
                        // `NavigationStack` is the exact anti-pattern this
                        // file's own doc comment already warns about for a
                        // different reason — the macOS `TabView` bug).
                        //
                        // The reauth/pending-credential `Button`s nested
                        // inside this row's label need `.buttonStyle
                        // (.borderless)` (see `accountRow(for:)`) so
                        // `NavigationLink`'s own tap gesture — which,
                        // unlike a plain `Button`'s, can otherwise swallow
                        // an inner control's tap and navigate instead —
                        // doesn't intercept them; this is the standard
                        // SwiftUI fix for "a List row that's both a
                        // NavigationLink and hosts its own inline action
                        // button".
                        NavigationLink {
                            AccountEditView(account: account)
                        } label: {
                            accountRow(for: account)
                        }
                        // `.row` suffix (not bare "settings.account.<id>")
                        // so an XCUITest lookup for *this* tappable row
                        // can't be confused with the sync-error/reauth/
                        // pending-credential banner `Label`s nested inside
                        // it, which also carry a "settings.account.<id>."
                        // prefix — see `accountRow(for:)`.
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

            // M11: iCloud account-definition sync (docs/icloud-sync.md).
            // Default on (`CloudSyncSettingsStore`'s doc comment); turning
            // it off only stops pushing local changes/reconciling — it
            // never touches any account already synced locally.
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

            // M10: reachable on both platforms, even though macOS also
            // gets a dedicated "情報" tab in the native Settings scene
            // (`OtegamiSettingsView`) — this sheet is still how the
            // app's own gear-icon entry point works on macOS too (it
            // wasn't replaced, only supplemented), and it's the *only*
            // route to it on iOS (no Settings scene there at all).
            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    Label("このアプリについて", systemImage: "info.circle")
                }
                .accessibilityIdentifier("settings.aboutLink")
            }

            if let reauthErrorMessage {
                Section {
                    Text(reauthErrorMessage)
                        .foregroundStyle(OtegamiColor.destructive)
                        .accessibilityIdentifier("settings.reauthErrorMessage")
                }
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
        .sheet(item: $accountEntryRoute) { route in
            accountEntryDestination(for: route, binding: $accountEntryRoute)
        }
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
    }

    /// One account row's content — extracted out of `body` so the `Button`
    /// wrapping it (above) doesn't have to inline this much view code
    /// itself. Not a `View`-conforming type of its own (just a
    /// `@ViewBuilder` function) since it needs no state of its own beyond
    /// what's already in scope.
    @ViewBuilder
    private func accountRow(for account: AccountRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.displayName)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(account.email)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Account edit UI: a connect-level sync failure (most
            // commonly: the account was just edited with a wrong
            // password) surfaced via `AccountRecord.lastSyncError` — see
            // that field's doc comment for why this needed its own
            // account-level record rather than reusing
            // `MailboxRecord.lastSyncError`. Clears itself the next time
            // `AccountSyncer` manages to connect (a fixed password, the
            // IDLE loop's own reconnect retries, ...), same as the
            // `needsReauth`/pending-credential banners below already do
            // for their own conditions.
            if let lastSyncError = account.lastSyncError {
                Label(lastSyncError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .accessibilityIdentifier("settings.account.\(account.id).syncErrorBanner")
            }

            // M6: a Gmail account whose refresh token was
            // rejected (see `AccountRecord.needsReauth`'s
            // doc comment) — the banner the plan calls for
            // ("リフレッシュ失敗 (invalid_grant) → ... UI
            // バナー"). `.buttonStyle(.borderless)` (see `body`'s doc
            // comment) keeps this tappable on its own now that the row
            // itself is a `NavigationLink`, not a plain `Button`.
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

            // M11: an account `CloudAccountDirectory
            // .insertFromCloud` created from this Apple
            // ID's iCloud sync payload, but with no
            // Keychain password found yet on this device
            // (iCloud Keychain hadn't caught up — same
            // `needsReauth` flag, different meaning and
            // banner text than the Gmail case above, per
            // the plan: "バナー文言だけ分岐"). "再接続" re-checks
            // Keychain immediately rather than waiting for
            // the next launch/accounts-list tick.
            if account.needsReauth, account.authType == .password {
                HStack {
                    Label("資格情報を待っています", systemImage: "icloud.and.arrow.down")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.account.\(account.id).pendingCredentialBanner")
                    Spacer()
                    Button("再接続") {
                        Task { await retryPendingCredential(account) }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .disabled(reauthenticatingAccountId == account.id)
                    .accessibilityIdentifier("settings.account.\(account.id).retryPendingCredentialButton")
                }
            }
        }
        .contentShape(Rectangle())
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

    /// M11: the "再接続" button on a cloud-inserted `.password` account
    /// that's still waiting for its Keychain credential to sync in — see
    /// `AppEnvironment.retryPendingCredential(for:)`'s doc comment. Shares
    /// `reauthenticatingAccountId`/`reauthErrorMessage` with
    /// `reauthenticate(_:)` above (both buttons are mutually exclusive per
    /// account — an account is never both an `.oauth2` reauth candidate and
    /// a `.password` pending-credential candidate at once) rather than
    /// duplicating a second pair of `@State` properties for the same
    /// "in-flight action, show an error if it fails" shape.
    private func retryPendingCredential(_ account: AccountRecord) async {
        reauthenticatingAccountId = account.id
        reauthErrorMessage = nil
        defer { reauthenticatingAccountId = nil }

        do {
            try await environment.retryPendingCredential(for: account)
        } catch {
            reauthErrorMessage = "まだ資格情報が見つかりません。iCloud キーチェーンの同期状況を確認してください。"
        }
    }
}
