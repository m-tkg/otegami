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
/// "+" button opens) or delete one — deletion cascades every local row for
/// that account (DB foreign keys) and wipes its Keychain password
/// (`AppEnvironment.deleteAccount`).
///
/// Extracted out of `AccountsSettingsView` in M10 (previously that type
/// *was* this content, wrapped directly in its own `NavigationStack`) so
/// `OtegamiSettingsView`'s macOS Settings-scene "アカウント" tab can embed it
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

    var body: some View {
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
                        .foregroundStyle(.red)
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
