import SwiftUI
import OtegamiStore
#if os(iOS)
import UIKit
#endif

/// Settings → プッシュ通知 (M9, plan §7): opt-in flow for the self-hosted
/// push relay. Collects the relay's URL (https required — `http://
/// localhost`/`http://127.0.0.1` exempted for local dev, enforced by
/// `AppEnvironment.validatedRelayURL(_:)`), shows the consent text the
/// plan calls for ("資格情報がそのサーバへ送信・保存される旨"), then on
/// "有効にする" requests notification authorization, obtains an APNs
/// device token, and registers this device + every `.password`-auth
/// account's watch with the relay.
///
/// iOS only: `AppEnvironment.enablePushNotifications` throws
/// `.unsupportedPlatform` on macOS (no `NotificationService` there yet —
/// M9 scope, see that Extension's own doc comment), which this view
/// surfaces as an explanatory message rather than a raw error, on the
/// platforms where the button can even be reached at all (macOS hides the
/// entry point in `AccountsSettingsView` — this view itself still compiles
/// and works standalone, e.g. for previews, on both platforms).
struct PushNotificationSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var relayURLText: String = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showingConsent = false
    /// `true` only while `errorMessage` reflects
    /// `AppEnvironment.PushError.notificationPermissionDenied` — the one
    /// error where a "設定アプリを開く" shortcut
    /// (`UIApplication.openSettingsURLString`) actually helps, since iOS
    /// never re-shows the system permission prompt once denied.
    @State private var showsOpenSettingsButton = false

    var body: some View {
        Form {
            Section {
                Text("自分でホストしたプッシュ中継サーバ (otegami-relay) の URL を入力してください。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("https://relay.example.com", text: relayURLBinding)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .disabled(environment.isPushEnabled || isProcessing)
                    .accessibilityIdentifier("settings.push.relayURLField")
            } header: {
                Text("リレー URL")
            } footer: {
                Text("https:// が必須です（ローカル開発時のみ http://localhost を使用できます）。")
            }

            if environment.isPushEnabled {
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
            } else {
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
                    .disabled(isProcessing || AppEnvironment.validatedRelayURL(relayURLText) == nil)
                    .accessibilityIdentifier("settings.push.enableButton")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
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
        }
        .navigationTitle("プッシュ通知")
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            relayURLText = environment.pushRelayURLString
        }
        .alert("資格情報の送信について", isPresented: $showingConsent) {
            Button("キャンセル", role: .cancel) {}
            Button("同意して有効にする") {
                Task { await enable() }
            }
            .accessibilityIdentifier("settings.push.consentConfirmButton")
        } message: {
            Text(
                "有効にすると、パスワード認証で設定した各アカウントの IMAP 接続情報" +
                    "（サーバー・ユーザー名・パスワード）が入力したリレー URL のサーバーへ" +
                    "送信され、暗号化して保存されます。リレーの運用者を信頼できる場合のみ" +
                    "有効にしてください。Gmail (OAuth) アカウントは現バージョンでは対象外です。"
            )
        }
    }

    private var relayURLBinding: Binding<String> {
        Binding(get: { relayURLText }, set: { relayURLText = $0 })
    }

    private func enable() async {
        isProcessing = true
        errorMessage = nil
        showsOpenSettingsButton = false
        defer { isProcessing = false }
        do {
            try await environment.enablePushNotifications(relayURLString: relayURLText)
        } catch AppEnvironment.PushError.invalidRelayURL {
            errorMessage = "リレー URL が不正です。https:// から始まる URL を入力してください。"
        } catch AppEnvironment.PushError.notificationPermissionDenied {
            errorMessage = "通知が許可されていません。設定アプリから許可してください。"
            showsOpenSettingsButton = true
        } catch AppEnvironment.PushError.noDeviceToken {
            errorMessage = "この環境では有効化できません。シミュレータは APNs デバイストークンを取得できないため、" +
                "実機で通知の許可を確認してください。"
        } catch AppEnvironment.PushError.unsupportedPlatform {
            errorMessage = "この OS では未対応です（iOS のみ対応）。"
        } catch {
            errorMessage = "有効化に失敗しました: \(error)"
        }
    }

    private func disable() async {
        isProcessing = true
        defer { isProcessing = false }
        await environment.disablePushNotifications()
        relayURLText = ""
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
