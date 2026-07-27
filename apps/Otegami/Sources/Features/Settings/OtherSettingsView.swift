import SwiftUI

/// I「設定画面の再構成」→「その他」: 上記のカテゴリに自然に収まらなかった
/// 既存設定 (スレッド表示・ピン留め連動・送信キャンセル・画像設定・
/// HTML表示・表示言語・テンプレート・iCloud同期・プッシュ通知・
/// アイコンバッジ) + このアプリについて。
///
/// **送信キャンセルの猶予時間**: `SendCancelSettingsStore`自体は C7 で
/// 実装済みだったが、実際に値を変更できる `Picker` UI がこの再構成まで
/// どの設定画面にも存在しなかった (`ComposerView`が既定値を読むだけ) —
/// この再構成のついでに配線した。
struct OtherSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @AppStorage(ListDisplaySettingsStore.threadingKey) private var isThreadingEnabled = ListDisplaySettingsStore.defaultThreading
    @AppStorage(PinSettingsStore.syncWithFlaggedKey) private var pinSyncWithFlagged = false
    // A9「メールの表示」.
    @AppStorage(HTMLDisplaySettingsStore.alwaysShowPlainTextKey) private var alwaysShowPlainText = HTMLDisplaySettingsStore.defaultAlwaysShowPlainText
    // B「画像の設定」.
    @AppStorage(ImageSettingsStore.autoShowEmbeddedImagesKey) private var autoShowEmbeddedImages = ImageSettingsStore.defaultAutoShowEmbedded
    @AppStorage(ImageSettingsStore.autoShowRemoteImagesKey) private var autoShowRemoteImages = ImageSettingsStore.defaultAutoShowRemote
    // 表示・操作改善バッチ「表示言語の設定」— `LocalizationSettingsStore`の
    // doc comment参照 (`@AppStorage`に乗らない理由)。
    @State private var languageOption: AppLanguageOption = LocalizationSettingsStore.current
    /// A「表示言語の切替が効かない」実機報告の修正 — see
    /// `languageChangeRestartAlert`'s doc comment.
    @State private var showingRestartAlert = false
    // H「アプリアイコンの未読バッジ」.
    @AppStorage(BadgeSettingsStore.enabledKey) private var badgeEnabled = BadgeSettingsStore.defaultEnabled
    #if os(iOS)
    @AppStorage(SendCancelSettingsStore.windowKey) private var sendCancelWindowRaw = SendCancelSettingsStore.defaultWindow.rawValue
    #endif

    var body: some View {
        List {
            Section {
                Toggle("スレッド表示", isOn: $isThreadingEnabled)
                    .accessibilityIdentifier("settings.list.threadingToggle")
            } footer: {
                Text("ONで一覧を会話単位にまとめます。OFFにすると一覧がメール単位になります。")
            }

            Section {
                Toggle("サーバーのフラグ (\\Flagged) と連動", isOn: $pinSyncWithFlagged)
                    .accessibilityIdentifier("settings.pinSyncWithFlaggedToggle")
            } header: {
                Text("ピン留め")
            } footer: {
                Text("既定ではピン留めはこの端末・このアプリだけのローカルな印です。ONにすると、ピン留め/解除のたびに IMAP の \\Flagged フラグも更新し、他のメールクライアントでのフラグ操作も読み取ってピン留めに反映します。")
            }

            #if os(iOS)
            Section {
                Picker("送信取り消しの猶予", selection: $sendCancelWindowRaw) {
                    ForEach(SendCancelWindow.allCases) { window in
                        Text(window.title).tag(window.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.sendCancelWindowPicker")
            } header: {
                Text("送信キャンセル")
            } footer: {
                Text("「送信」をタップしてから実際にサーバーへ送るまでの猶予時間です。この間は「送信を取り消す」で送信をキャンセルできます。アプリをバックグラウンドに切り替えると、残り時間に関わらず即座に送信されます。")
            }
            #endif

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

            Section {
                Toggle("常にテキストで表示", isOn: $alwaysShowPlainText)
                    .accessibilityIdentifier("settings.html.alwaysShowPlainTextToggle")
            } header: {
                Text("メールの表示 (HTML)")
            } footer: {
                Text("HTMLメールを既定でテキスト表示にします。メール詳細画面の切替ボタンで、メールごとに一時的に戻すこともできます。")
            }

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
                    showingRestartAlert = true
                }
            } header: {
                Text("表示言語")
            } footer: {
                Text("アプリの表示言語を切り替えます。変更を反映するには、アプリを再起動してください。")
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

            // M11: iCloud account-definition sync.
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

            // H「アプリアイコンの未読バッジ」.
            Section {
                Toggle("アイコンバッジ", isOn: $badgeEnabled)
                    .accessibilityIdentifier("settings.badgeToggle")
            } footer: {
                Text("統合受信トレイの未読数をアプリアイコンに表示します。")
            }

            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    Label("このアプリについて", systemImage: "info.circle")
                }
                .accessibilityIdentifier("settings.aboutLink")
            }
        }
        .navigationTitle("その他")
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
        .onChange(of: badgeEnabled) { _, _ in
            environment.refreshBadgeObservation()
        }
        .alert(
            "表示言語を変更しました",
            isPresented: $showingRestartAlert
        ) {
            Button("今すぐ終了", role: .destructive) {
                exit(0)
            }
            .accessibilityIdentifier("settings.languageOptionRestartNowButton")
            Button("あとで", role: .cancel) {}
                .accessibilityIdentifier("settings.languageOptionRestartLaterButton")
        } message: {
            Text("変更を反映するには、アプリを完全に終了してもう一度起動してください（ホーム画面に戻るだけでは反映されません）。「今すぐ終了」でアプリを終了できます。")
        }
    }
}
