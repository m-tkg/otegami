import SwiftUI
import OtegamiStore
import OtegamiRelayAPI
#if os(iOS)
import UIKit
#endif

/// Settings → プッシュ通知 (M9, plan §7): opt-in flow for the self-hosted
/// push relay. On "有効にする" (behind a consent alert — "資格情報がそのサーバへ
/// 送信・保存される旨", Task #175 follow-up: now also covers Gmail/Outlook
/// sending their OAuth refresh token) requests notification authorization,
/// obtains an APNs device token, and registers this device + every
/// push-watch-eligible account's watch with the relay
/// (`AppEnvironment.isPushWatchCandidate(_:)` — `.password` accounts send
/// an IMAP password, `.oauth2` Gmail/Microsoft accounts send an OAuth
/// refresh token instead). No relay-operator credential *or URL* is
/// ever collected here — both the relay's optional device-registration
/// secret (`RelayRegistrationSecretConfig`, Task #171) and the relay's URL
/// itself (`RelayURLConfig`, Task #173 follow-up: 実機フィードバック
/// 2026-07-30 「リレー URL は今の固定 URL という話をしたよ」) are build-time
/// values now — an ordinary user of this screen has nothing to type at all,
/// just "有効にする"/"無効にする" and (Task #173) the per-account watch
/// status list below.
///
/// iOS only: `AppEnvironment.enablePushNotifications` throws
/// `.unsupportedPlatform` on macOS (no `NotificationService` there yet —
/// M9 scope, see that Extension's own doc comment), which this view
/// surfaces as an explanatory message rather than a raw error, on the
/// platforms where the button can even be reached at all (macOS hides the
/// entry point with `#if os(iOS)` in `AccountSettingsCategoryView` — 実機
/// フィードバック 2026-07-30 で漏れていたことが判明し、そこで追加した —
/// this view itself still compiles and works standalone, e.g. for
/// previews, on both platforms).
struct PushNotificationSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showingConsent = false
    /// `true` only while `errorMessage` reflects
    /// `AppEnvironment.PushError.notificationPermissionDenied` — the one
    /// error where a "設定アプリを開く" shortcut
    /// (`UIApplication.openSettingsURLString`) actually helps, since iOS
    /// never re-shows the system permission prompt once denied.
    @State private var showsOpenSettingsButton = false
    /// Task #173: this device's per-account watch status, refreshed via
    /// `refreshWatchRows()` — see `PushWatchDisplayRow.build`'s doc comment.
    @State private var watchRows: [PushWatchDisplayRow] = []
    /// The one account currently being re-registered (if any) — drives
    /// that row's "再登録中…" `ProgressView` and disables its button, same
    /// single-in-flight-id shape as `MailboxSyncFailuresView
    /// .retryingMailboxIds` (a `Set` there since several mailboxes can
    /// retry independently; here only one re-register can be in flight at
    /// a time since this whole screen is a single `Form`, so a single
    /// optional id is enough).
    @State private var reregisteringAccountId: String?

    /// Task #176 (実機フィードバック 2026-07-30「通知にタイトル、差出人、
    /// 本文の一部を出すかどうかの設定を追加して」): the 3 content toggles —
    /// `@AppStorage`, same pattern as every other `*SettingsStore`-backed
    /// toggle in this app (`MailViewerSettingsView`'s bindings, e.g.), bound
    /// to `NotificationContentSettingsStore`'s keys. Each one's `onChange`
    /// below re-mirrors the current value into the shared App Group suite
    /// `NotificationService` actually reads — see that type's doc comment
    /// for why a plain `UserDefaults.standard` write alone isn't enough.
    @AppStorage(NotificationContentSettingsStore.showsSenderKey)
    private var showsSenderInNotification = NotificationContentSettingsStore.defaultShowsSender
    @AppStorage(NotificationContentSettingsStore.showsSubjectKey)
    private var showsSubjectInNotification = NotificationContentSettingsStore.defaultShowsSubject
    @AppStorage(NotificationContentSettingsStore.showsBodyPreviewKey)
    private var showsBodyPreviewInNotification = NotificationContentSettingsStore.defaultShowsBodyPreview

    var body: some View {
        Form {
            statusSection
            if RelayURLConfig.isConfigured {
                notificationContentSection
            }
            if environment.isPushEnabled {
                PushWatchStatusSection(
                    rows: watchRows,
                    reregisteringAccountId: reregisteringAccountId,
                    onReregister: { accountId in reregister(accountId) }
                )
            }
            if let errorMessage {
                errorSection(errorMessage)
            }
        }
        .navigationTitle("プッシュ通知")
        #if os(macOS)
        // Task #155: see `AccountEditView`'s doc comment on this same
        // modifier.
        .formStyle(.grouped)
        .toggleStyle(.switch)
        #else
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        // Task #155 follow-up: see `MacSettingsBackButton`'s doc comment —
        // this screen is pushed from `AccountSettingsCategoryView`.
        .macSettingsBackButton()
        #endif
        .task(id: environment.isPushEnabled) { await refreshWatchRows() }
        .alert("資格情報の送信について", isPresented: $showingConsent) {
            Button("キャンセル", role: .cancel) {}
            Button("同意して有効にする") {
                Task { await enable() }
            }
            .accessibilityIdentifier("settings.push.consentConfirmButton")
        } message: {
            // A「UI に複数言語が混在」実機報告の原因の一つ: 以前は`"a" + "b" +
            // "c"`という文字列連結の`String`式を`Text(_:)`に渡していたため、
            // `Text(LocalizedStringKey)`ではなく`Text(some StringProtocol)`
            // (verbatim) オーバーロードに解決され、String Catalog を一切
            // 引けていなかった (`docs/localization.md`の「`Text(String)`は
            // 自動でローカライズされない」節が警告するパターンそのもの、
            // ただし連結演算子経由という気づきにくい形)。1つのリテラルに
            // まとめることで`LocalizedStringKey`解決に戻した。
            Text("有効にすると、パスワード認証で設定した各アカウントの IMAP 接続情報（サーバー・ユーザー名・パスワード）がプッシュ中継サーバーへ送信され、暗号化して保存されます。Gmail・Outlook（OAuth 認証）アカウントは、パスワードの代わりにアクセス権のリフレッシュトークンが同様に送信され、暗号化して保存されます。いずれもリレーの運用者を信頼できる場合のみ有効にしてください。")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if !RelayURLConfig.isConfigured {
            unconfiguredSection
        } else if environment.isPushEnabled {
            enabledSection
        } else {
            disabledSection
        }
    }

    /// Task #173 follow-up: this build has no relay URL baked in
    /// (`RelayURLConfig`) — same "disabled button + explanatory footnote"
    /// shape as `AccountTypeSelectionView.gmailButton`'s
    /// `accountTypeSelection.gmailDisabledHint` for an unconfigured Gmail
    /// OAuth Client ID.
    private var unconfiguredSection: some View {
        Section {
            Button {} label: { Text("有効にする") }
                .disabled(true)
                .accessibilityIdentifier("settings.push.enableButton")
        } footer: {
            Text("この配布ビルドにはプッシュ中継サーバーが設定されていません。自分のリレーを使う場合は docs/relay-deployment.md を参照して Config/Local.xcconfig に設定してください。")
                .accessibilityIdentifier("settings.push.relayNotConfiguredHint")
        }
    }

    /// Task #176: shown whenever this build even has a relay configured
    /// (`RelayURLConfig.isConfigured`, same gate `statusSection` itself
    /// uses to decide whether to show anything push-related at all) —
    /// deliberately *not* gated on `environment.isPushEnabled` in addition,
    /// so a user can set these up before ever tapping "有効にする" and have
    /// them already in place the first time a notification actually
    /// arrives, rather than needing to remember to come back afterward.
    private var notificationContentSection: some View {
        Section {
            Toggle("差出人を表示", isOn: $showsSenderInNotification)
                .accessibilityIdentifier("settings.push.showsSenderToggle")
                .onChange(of: showsSenderInNotification) { _, _ in NotificationContentSettingsStore.mirrorToAppGroup() }
            Toggle("件名を表示", isOn: $showsSubjectInNotification)
                .accessibilityIdentifier("settings.push.showsSubjectToggle")
                .onChange(of: showsSubjectInNotification) { _, _ in NotificationContentSettingsStore.mirrorToAppGroup() }
            Toggle("本文プレビューを表示", isOn: $showsBodyPreviewInNotification)
                .accessibilityIdentifier("settings.push.showsBodyPreviewToggle")
                .onChange(of: showsBodyPreviewInNotification) { _, _ in NotificationContentSettingsStore.mirrorToAppGroup() }
        } header: {
            Text("通知の内容")
        } footer: {
            // 実機フィードバック 2026-07-30 の要望文そのもの — OS 側の
            // 「設定 → 通知 → プレビューを表示」(ロック画面などでその場に
            // プレビューを出すかどうかの OS 全体設定) と、ここでの3つの
            // トグル (このアプリが通知の中身として何を渡すか) は別物、かつ
            // 混同しやすいため明記する。すべてオフの場合は「新着メールが
            // あります」のような内容を伴わない通知になる。
            Text("OS の「設定 → 通知 → プレビューを表示」とは別の設定です。こちらは、このアプリが通知に載せる内容そのものを選びます（両方が有効な場合のみ、選んだ内容が実際に表示されます）。すべてオフにすると「新着メールがあります」のような内容を伴わない通知になります。")
                .accessibilityIdentifier("settings.push.notificationContentHint")
        }
    }

    private var enabledSection: some View {
        Section {
            Label("プッシュ通知は有効です", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("settings.push.enabledLabel")
            Button(role: .destructive) {
                Task { await disable() }
            } label: {
                if isProcessing {
                    ProgressView()
                } else {
                    Text("無効にする")
                }
            }
            .disabled(isProcessing)
            .accessibilityIdentifier("settings.push.disableButton")
        }
    }

    private var disabledSection: some View {
        Section {
            Button {
                showingConsent = true
            } label: {
                if isProcessing {
                    ProgressView()
                } else {
                    Text("有効にする")
                }
            }
            .disabled(isProcessing)
            .accessibilityIdentifier("settings.push.enableButton")
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Text(message)
                .foregroundStyle(OtegamiColor.destructive)
                .accessibilityIdentifier("settings.push.errorMessage")
            if showsOpenSettingsButton {
                #if os(iOS)
                Button("設定アプリを開く") {
                    openSystemSettings()
                }
                .accessibilityIdentifier("settings.push.openSystemSettingsButton")
                #endif
            }
        }
    }

    private func enable() async {
        isProcessing = true
        errorMessage = nil
        showsOpenSettingsButton = false
        defer { isProcessing = false }
        do {
            try await environment.enablePushNotifications()
            await refreshWatchRows()
        } catch AppEnvironment.PushError.relayNotConfigured {
            errorMessage = "この配布ビルドにはプッシュ中継サーバーが設定されていません。"
        } catch AppEnvironment.PushError.notificationPermissionDenied {
            errorMessage = "通知が許可されていません。設定アプリから許可してください。"
            showsOpenSettingsButton = true
        } catch AppEnvironment.PushError.noDeviceToken {
            errorMessage = "この環境では有効化できません。シミュレータは APNs デバイストークンを取得できないため、" +
                "実機で通知の許可を確認してください。"
        } catch AppEnvironment.PushError.unsupportedPlatform {
            errorMessage = "この OS では未対応です（iOS のみ対応）。"
        } catch AppEnvironment.PushError.registrationSecretRejected {
            // Task #171 follow-up: the registration secret is a build-time
            // value (`RelayRegistrationSecretConfig`) — see
            // `isRelayRegistrationSecretConfigured`'s doc comment for why
            // the message differs depending on whether this build has one
            // baked in at all.
            if environment.isRelayRegistrationSecretConfigured {
                errorMessage = "リレーの登録シークレットが一致しません。運用者に確認してください。"
            } else {
                errorMessage = "このリレーは登録シークレットを要求していますが、このビルドには設定されていません。" +
                    "運用者に確認するか docs/relay-deployment.md を参照してください。"
            }
        } catch {
            errorMessage = "有効化に失敗しました: \(error)"
        }
    }

    private func disable() async {
        isProcessing = true
        defer { isProcessing = false }
        await environment.disablePushNotifications()
        watchRows = []
    }

    /// Task #173: rebuilds `watchRows` from the relay's current watch list
    /// (`AppEnvironment.fetchPushWatchSummaries()`) — called on first
    /// appearance, right after enabling, and after every re-register
    /// attempt (success or failure — a failed attempt may still have
    /// changed the relay's state, e.g. the old watch got deleted but the
    /// new one failed to create).
    private func refreshWatchRows() async {
        guard environment.isPushEnabled else {
            watchRows = []
            return
        }
        let serverWatches = await environment.fetchPushWatchSummaries()
        watchRows = PushWatchDisplayRow.build(
            accounts: environment.accounts,
            isPushEnabled: environment.isPushEnabled,
            serverWatches: serverWatches
        )
    }

    private func reregister(_ accountId: String) {
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
        reregisteringAccountId = accountId
        Task {
            defer { reregisteringAccountId = nil }
            do {
                try await environment.reregisterWatch(for: account)
                errorMessage = nil
            } catch AppEnvironment.ReregisterWatchError.credentialUnavailable {
                errorMessage = "このアカウントのパスワードが見つかりません。アカウント設定でパスワードを再入力してください。"
            } catch AppEnvironment.ReregisterWatchError.relayRejectedWatch {
                errorMessage = "再登録に失敗しました。リレーに接続できないか、資格情報が拒否されました。"
            } catch {
                errorMessage = "再登録に失敗しました: \(error)"
            }
            await refreshWatchRows()
        }
    }

    #if os(iOS)
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    #endif
}

#Preview {
    NavigationStack {
        PushNotificationSettingsView()
    }
    .environment(AppEnvironment())
}
