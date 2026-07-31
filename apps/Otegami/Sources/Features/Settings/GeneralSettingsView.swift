import SwiftUI

/// Task #189 (実機フィードバック「iCloud で色々同期するようになったんで、
/// iCloud 同期の設定をアカウント設定から出して『一般』を新設してそこに
/// 移して」): 設定のトップに新設したカテゴリ。直前の Task #186 で iCloud
/// 同期の対象がアカウントの接続設定から表示・翻訳・通知・署名・テンプレート
/// など設定全般へ広がったため、同期のオン/オフを「アカウントの設定」
/// カテゴリの中に置いておく理由がなくなった —
/// `AccountSettingsCategoryView`の同トグルをこのカテゴリへ丸ごと移設し、
/// 移設元には残していない。
///
/// 並び順はカテゴリ一覧 (`AccountsListContent`/`MacSettingsCategory`) の
/// 先頭 — 既存4カテゴリの並びは「アカウント→メール一覧→メールビューア→
/// メール作成」というアプリの利用フロー順だったが、iCloud 同期はその
/// どの段階にも属さずアプリ全体に横断的に効く設定なので、フロー順の外側
/// (先頭) に置くのが両立する。Apple 標準の「設定」アプリ/システム設定が
/// 「一般」を他のアプリ固有カテゴリより手前に置く並びとも一致する。
///
/// アクセシビリティ識別子 `settings.cloudSyncToggle` は
/// `AccountSettingsCategoryView`時代のものをそのまま再利用している
/// (UITest 互換、`docs/localization.md`のキー再利用方針とも整合) —
/// 変わったのはこのトグルが属する画面だけで、ローカライズキーやトグル
/// 自体の挙動 (`AppEnvironment.isCloudSyncEnabled`/`setCloudSyncEnabled`)
/// は変えていない。footer の説明文だけは Task #186 で同期対象が広がった
/// 実態に合わせて書き直した (旧文言は「アカウントの接続設定・表示設定」
/// までしか触れていなかった)。
///
/// **Task #212 (実機フィードバック「push 通知の設定はアカウント設定
/// じゃなくて一般に移した方がいいと思う」)**: `AccountSettingsCategoryView`
/// にあった「プッシュ通知」への入口 (`PushNotificationSettingsView`への
/// `NavigationLink`) をここへ移設した — 移設元には残していない。Task #189
/// 時点の doc comment (このファイルの上の段落、および
/// `AccountSettingsCategoryView`側) は「プッシュ通知はアカウントごとの
/// push watch 登録という『アカウントの接続に関する設定』の性質が変わって
/// いないため今回は移設しない」と判断していたが、今回の実機フィードバック
/// でその判断がユーザー自身によって覆された — プッシュ通知は個々の
/// アカウントの接続設定というより、iCloud 同期同様「アプリ全体に1つだけ
/// ある」横断的な設定として扱ってほしいとのこと。
///
/// **並び順は iCloud 同期の下**: iCloud 同期トグルは即座に反映される単純な
/// on/off で、この画面が新設されたときからの唯一の項目 — その定位置を
/// 崩さずそのまま先頭に残し、プッシュ通知 (サブ画面へのドリルダウン、かつ
/// iOS 専用) はその下の2番目のセクションとして追加した。
/// `AccountSettingsCategoryView`側でも同じ「トグル系のセクションが先、
/// サブ画面へ遷移する`NavigationLink`のセクションが後」という並びだった
/// ため、この画面でも踏襲している。
struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    /// Task #212: tap-free navigation to `PushNotificationSettingsView` for
    /// `scripts/verify-screen.sh` — `AccountSettingsCategoryView`が同じ
    /// 目的で持っていたフックをそのままここへ移設した (`Task #171`由来)。
    /// A no-op (`false`, and the `.task` below never flips it) on every
    /// real launch.
    @State private var uitestShowPushNotificationsDirectly = false

    var body: some View {
        settingsContainer
            .navigationTitle("一般")
            #if os(iOS)
            .navigationDestination(isPresented: $uitestShowPushNotificationsDirectly) {
                PushNotificationSettingsView()
            }
            .task {
                if ProcessInfo.processInfo.arguments.contains("-uitestsOpenPushNotificationsDirectly") {
                    uitestShowPushNotificationsDirectly = true
                }
            }
            #endif
    }

    /// Task #155: see `MailListSettingsView`'s identical doc comment on
    /// this same property (`Form`+`.formStyle(.grouped)`+`.toggleStyle
    /// (.switch)`on macOS, plain`List`on iOS — 他の新設カテゴリと同じ型)。
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
            Text(
                "同じ Apple ID の他の iOS/Mac デバイスと、アカウントの接続設定に加えて表示・翻訳・通知内容・署名・テンプレートなどの設定を同期します。パスワードは iCloud キーチェーンが別途同期し、メール本文などのキャッシュやプッシュ通知の設定など端末固有の項目は同期しません。"
            )
        }

        // Task #212: `AccountSettingsCategoryView`から移設 — 元の
        // `#if os(iOS)`ガードも含めそのまま持ってきた
        // (`AppEnvironment.enablePushNotifications`はmacOSで
        // `.unsupportedPlatform`を投げる、`PushNotificationSettingsView`の
        // doc comment参照)。
        #if os(iOS)
        Section {
            NavigationLink {
                PushNotificationSettingsView()
            } label: {
                Label("プッシュ通知", systemImage: "bell.badge")
            }
            .accessibilityIdentifier("settings.pushNotificationsLink")
        }
        #endif
    }
}
