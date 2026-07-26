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
    /// Real-device bug report: the "資格情報を待っています" banner's "再接続"
    /// button used to just re-check the Keychain (`retryPendingCredential`,
    /// still used for `.oauth2`'s "再認証") — for a `.password` account whose
    /// credential is genuinely gone (not just "iCloud Keychain hasn't
    /// synced it in yet"), that check can never succeed no matter how many
    /// times it's tapped, and it has no way to *tell* the user that; from
    /// their side, the button visibly does nothing. `AppEnvironment
    /// .startObservingAccounts` already re-runs the same Keychain check
    /// automatically on every account-list tick, so a manual button whose
    /// only job was to trigger that same check is redundant on top of being
    /// a dead end — the actual fix for a `.password` account is to type the
    /// password in, which only `AccountEditView` can do. Pushing straight
    /// there (via this `navigationDestination(item:)`, independent of each
    /// row's own `NavigationLink` push to the same destination) is what the
    /// button does now instead — see `accountRow(for:)`. Holds just the
    /// `accountId` (not the `AccountRecord` itself) because
    /// `navigationDestination(item:)` requires its item type be
    /// `Hashable`, which `AccountRecord` isn't (it's `Equatable`, not
    /// `Hashable` — GRDB's `FetchableRecord` types in this codebase
    /// generally aren't) — the destination closure below looks the account
    /// back up from `environment.accounts` by id instead.
    @State private var passwordEntryAccountId: String?

    // design-phase-3, 1l "操作"/"翻訳" blocks, D8/B3/B4/E9 の追加設定 — see
    // `SwipeActionSettingsStore`/`TranslationSettingsStore`/
    // `ListDisplaySettingsStore`/`PinSettingsStore`'s doc comments for why
    // these read `UserDefaults` directly via `@AppStorage` rather than
    // through `AppEnvironment`.
    @AppStorage(SwipeActionSettingsStore.leadingShortActionKey) private var leadingShortRaw = SwipeActionSettingsStore.defaultLeadingShort.rawValue
    @AppStorage(SwipeActionSettingsStore.leadingLongActionKey) private var leadingLongRaw = SwipeActionSettingsStore.defaultLeadingLong.rawValue
    @AppStorage(SwipeActionSettingsStore.trailingShortActionKey) private var trailingShortRaw = SwipeActionSettingsStore.defaultTrailingShort.rawValue
    @AppStorage(SwipeActionSettingsStore.trailingLongActionKey) private var trailingLongRaw = SwipeActionSettingsStore.defaultTrailingLong.rawValue
    @AppStorage(TranslationSettingsStore.autoTranslateEnglishKey) private var autoTranslateEnglish = true
    @AppStorage(TranslationSettingsStore.showListSummaryKey) private var showListSummary = false
    @AppStorage(ListDisplaySettingsStore.threadingKey) private var isThreadingEnabled = ListDisplaySettingsStore.defaultThreading
    @AppStorage(ListDisplaySettingsStore.showAvatarKey) private var showAvatar = ListDisplaySettingsStore.defaultShowAvatar
    @AppStorage(ListDisplaySettingsStore.previewLineCountKey) private var previewLineCountRaw = ListDisplaySettingsStore.defaultPreviewLineCount.rawValue
    @AppStorage(ListDisplaySettingsStore.showAvatarInDetailKey) private var showAvatarInDetail = ListDisplaySettingsStore.defaultShowAvatarInDetail
    @AppStorage(PinSettingsStore.syncWithFlaggedKey) private var pinSyncWithFlagged = false
    // A9「メールの表示」— see `HTMLDisplaySettingsStore`'s doc comment.
    @AppStorage(HTMLDisplaySettingsStore.alwaysShowPlainTextKey) private var alwaysShowPlainText = HTMLDisplaySettingsStore.defaultAlwaysShowPlainText
    // B「画像の設定」— see `ImageSettingsStore`'s doc comment.
    @AppStorage(ImageSettingsStore.autoShowEmbeddedImagesKey) private var autoShowEmbeddedImages = ImageSettingsStore.defaultAutoShowEmbedded
    @AppStorage(ImageSettingsStore.autoShowRemoteImagesKey) private var autoShowRemoteImages = ImageSettingsStore.defaultAutoShowRemote
    // C7「メール内リンクを開くブラウザ」— see `LinkBrowserSettingsStore`'s doc
    // comment for why this is iOS-only.
    @AppStorage(LinkBrowserSettingsStore.openInAppBrowserKey) private var openInAppBrowser = LinkBrowserSettingsStore.defaultOpenInAppBrowser
    // 表示・操作改善バッチ「表示言語の設定」— `LocalizationSettingsStore`'s
    // doc comment on why this is a plain `@State` seeded from `.current`
    // rather than `@AppStorage`.
    @State private var languageOption: AppLanguageOption = LocalizationSettingsStore.current

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

            // C8「メール作成のテンプレート」.
            Section {
                NavigationLink {
                    TemplatesSettingsView()
                } label: {
                    Label("テンプレート", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("settings.templatesLink")
            }

            // D8「スワイプの割り当て」— iOS only (macOS has no swipe gesture;
            // every action is always reachable there via the row's
            // context menu instead — `MessageListRow.contextMenuContent`).
            #if os(iOS)
            Section {
                Picker("右・短いスワイプ", selection: $leadingShortRaw) {
                    ForEach(SwipeAction.allCases) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.swipe.leadingShortPicker")
                Picker("右・長いスワイプ", selection: $leadingLongRaw) {
                    ForEach(SwipeAction.allCases) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.swipe.leadingLongPicker")
                Picker("左・短いスワイプ", selection: $trailingShortRaw) {
                    ForEach(SwipeAction.allCases) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.swipe.trailingShortPicker")
                Picker("左・長いスワイプ", selection: $trailingLongRaw) {
                    ForEach(SwipeAction.allCases) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.swipe.trailingLongPicker")
            } header: {
                Text("操作")
            } footer: {
                Text("短いスワイプで表示される操作は、そのままスワイプし切ると即座に実行されます（削除・迷惑メールを除く — 誤操作防止のため、必ずタップでの確定操作です）。長いスワイプの操作は、ボタンが表示されてからのタップでのみ実行されます。")
            }
            #endif

            // B3/B4「一覧・表示」.
            Section {
                Toggle("スレッド表示", isOn: $isThreadingEnabled)
                    .accessibilityIdentifier("settings.list.threadingToggle")
                Toggle("送信者のプロフィールアイコンを表示", isOn: $showAvatar)
                    .accessibilityIdentifier("settings.list.showAvatarToggle")
                Picker("本文プレビューの行数", selection: $previewLineCountRaw) {
                    ForEach(PreviewLineCount.allCases) { count in
                        Text(count.title).tag(count.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.list.previewLineCountPicker")
                Toggle("メール本文にも送信者アイコンを表示", isOn: $showAvatarInDetail)
                    .accessibilityIdentifier("settings.list.showAvatarInDetailToggle")
            } header: {
                Text("一覧・表示")
            } footer: {
                Text("プロフィールアイコンは差出人のイニシャルとアカウント色から生成され、外部サービスへの問い合わせは一切行いません。")
            }

            // A9「メールの表示」.
            Section {
                Toggle("常にテキストで表示", isOn: $alwaysShowPlainText)
                    .accessibilityIdentifier("settings.html.alwaysShowPlainTextToggle")
            } header: {
                Text("メールの表示")
            } footer: {
                Text("HTMLメールを既定でテキスト表示にします。メール詳細画面の切替ボタンで、メールごとに一時的に戻すこともできます。")
            }

            // B「画像の設定」.
            Section {
                Toggle("埋め込み画像を自動表示", isOn: $autoShowEmbeddedImages)
                    .accessibilityIdentifier("settings.images.autoShowEmbeddedToggle")
                Toggle("リモート画像を自動で読み込む", isOn: $autoShowRemoteImages)
                    .accessibilityIdentifier("settings.images.autoShowRemoteToggle")
            } header: {
                Text("画像")
            } footer: {
                Text("埋め込み画像はメールに直接添付・埋め込まれた画像（cid: インライン画像・画像添付）です。リモート画像は外部サーバーから読み込む画像で、自動で読み込むと送信者にメールを開いたことが伝わる場合があります（開封トラッキング）。いずれもオフの場合は、メール詳細画面の「画像を表示」ボタンでそのメールだけ一時的に表示できます。")
            }

            // C7「メール内リンクを開くブラウザ」— iOS only; macOS always opens
            // the system default browser (`LinkBrowserSettingsStore`'s doc
            // comment).
            #if os(iOS)
            Section {
                Picker("リンクを開く方法", selection: $openInAppBrowser) {
                    Text("アプリ内ブラウザ").tag(true)
                    Text("デフォルトブラウザ").tag(false)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.links.openInAppBrowserPicker")
            } header: {
                Text("リンク")
            } footer: {
                Text("メール本文内のリンクをタップしたときに、アプリ内のブラウザで開くか、端末のデフォルトブラウザで開くかを選べます。")
            }
            #endif

            // E9「ピン留め」.
            Section {
                Toggle("サーバーのフラグ (\\Flagged) と連動", isOn: $pinSyncWithFlagged)
                    .accessibilityIdentifier("settings.pinSyncWithFlaggedToggle")
            } header: {
                Text("ピン留め")
            } footer: {
                Text("既定ではピン留めはこの端末・このアプリだけのローカルな印です。ONにすると、ピン留め/解除のたびに IMAP の \\Flagged フラグも更新し、他のメールクライアントでのフラグ操作も読み取ってピン留めに反映します。")
            }

            // 表示・操作改善バッチ「表示言語の設定」— see
            // `LocalizationSettingsStore`'s doc comment. `@State`(`@AppStorage`
            // ではない) で持つ理由: `LocalizationSettingsStore.current`は
            // "system"/"ja"/"en" の生文字列ではなく `AppLanguageOption` を
            // 返す解決済みの値で、書き込み側も (`AppleLanguages`キーへの反映を
            // 伴う) 専用の`setLanguageOption(_:)`を経由する必要があるため、
            // 単純な `UserDefaults` キー1つへの読み書きで完結する
            // `@AppStorage` の形にそのまま乗らない。
            Section {
                Picker("表示言語", selection: $languageOption) {
                    ForEach(AppLanguageOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.languageOptionPicker")
                .onChange(of: languageOption) { _, newValue in
                    LocalizationSettingsStore.setLanguageOption(newValue)
                }
            } header: {
                Text("表示言語")
            } footer: {
                Text("アプリの表示言語を切り替えます。変更を反映するには、アプリを再起動してください。")
            }

            // design-phase-3, 1l "翻訳".
            Section {
                Toggle("英文を自動で翻訳", isOn: $autoTranslateEnglish)
                    .accessibilityIdentifier("settings.autoTranslateToggle")
                Toggle("一覧に要約を出す", isOn: $showListSummary)
                    .accessibilityIdentifier("settings.listSummaryToggle")
            } header: {
                Text("翻訳")
            } footer: {
                Text("翻訳は Apple Intelligence により端末内で行われ、外部に送信されません。")
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
        // Real-device bug fix: the pending-credential banner's "パスワードを
        // 入力" button (`passwordEntryAccountId`'s doc comment) pushes here —
        // a second, programmatic route to the exact same `AccountEditView`
        // destination each row's own `NavigationLink` already pushes to on
        // tap. Both coexist on this `NavigationStack` without conflict:
        // SwiftUI's implicit-path (`NavigationLink(destination:)`) and
        // item-driven (`navigationDestination(item:)`) push mechanisms are
        // independent triggers onto the same stack.
        .navigationDestination(item: $passwordEntryAccountId) { accountId in
            if let account = environment.accounts.first(where: { $0.id == accountId }) {
                AccountEditView(account: account)
            }
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
            // the plan: "バナー文言だけ分岐"). Real-device bug fix:
            // this used to be a "再接続" button that only
            // re-checked the Keychain — useless (and
            // indistinguishable from broken) once the
            // credential is actually gone, since nothing
            // ever makes that check start succeeding on its
            // own. `AppEnvironment
            // .retryPendingCredentialIfAvailable` already
            // performs that same check automatically on
            // every account-list tick, so tapping here now
            // goes straight to the one thing that can
            // actually fix a `.password` account:
            // `AccountEditView`'s password field (see
            // `passwordEntryAccountId`'s doc comment).
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
