import SwiftUI

/// I「設定画面の再構成」→「メールビューア」: ブラウザの設定 (C7)・G「メール
/// 削除/アーカイブ時の挙動」・メール本文へのプロフィール画像表示・
/// AI 機能の on/off (翻訳・要約をまとめて)。
///
/// 実機フィードバック第3弾 (I): 旧「その他」カテゴリから画像設定 (B) と
/// HTML表示設定 (A9) をここへ移設した — どちらも「メール本文の描画」に
/// 関わる設定で、このカテゴリの既存項目 (ブラウザ・プロフィール画像・
/// AI機能) と同じ「本文を読む/表示する体験」の範疇にある。
struct MailViewerSettingsView: View {
    // C7「メール内リンクを開くブラウザ」— iOS only (`LinkBrowserSettingsStore`
    // の doc comment参照)。
    @AppStorage(LinkBrowserSettingsStore.openInAppBrowserKey) private var openInAppBrowser = LinkBrowserSettingsStore.defaultOpenInAppBrowser
    /// G「メール削除/アーカイブ時の挙動」.
    @AppStorage(MessagePostActionSettingsStore.afterDeleteArchiveKey) private var afterDeleteArchiveRaw = MessagePostActionSettingsStore.defaultAfterDeleteArchive.rawValue
    @AppStorage(ListDisplaySettingsStore.showAvatarInDetailKey) private var showAvatarInDetail = ListDisplaySettingsStore.defaultShowAvatarInDetail
    /// I「AI 機能の on/off (翻訳・要約をまとめて)」.
    @AppStorage(AIFeaturesSettingsStore.enabledKey) private var aiFeaturesEnabled = AIFeaturesSettingsStore.defaultEnabled
    @AppStorage(TranslationSettingsStore.autoTranslateEnglishKey) private var autoTranslateEnglish = TranslationSettingsStore.defaultAutoTranslateEnglish
    // B「画像の設定」— 実機フィードバック第3弾 (I) で旧「その他」から移設。
    @AppStorage(ImageSettingsStore.autoShowEmbeddedImagesKey) private var autoShowEmbeddedImages = ImageSettingsStore.defaultAutoShowEmbedded
    @AppStorage(ImageSettingsStore.autoShowRemoteImagesKey) private var autoShowRemoteImages = ImageSettingsStore.defaultAutoShowRemote
    // A9「メールの表示」— 実機フィードバック第3弾 (I) で旧「その他」から移設。
    @AppStorage(HTMLDisplaySettingsStore.alwaysShowPlainTextKey) private var alwaysShowPlainText = HTMLDisplaySettingsStore.defaultAlwaysShowPlainText

    var body: some View {
        List {
            #if os(iOS)
            Section {
                Picker("リンクを開く方法", selection: $openInAppBrowser) {
                    Text("アプリ内ブラウザ").tag(true)
                    Text("デフォルトブラウザ").tag(false)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.links.openInAppBrowserPicker")
            } header: {
                Text("ブラウザ")
            } footer: {
                Text("メール本文内のリンクをタップしたときに、アプリ内のブラウザで開くか、端末のデフォルトブラウザで開くかを選べます。")
            }
            #endif

            Section {
                Picker("削除/アーカイブ後の動作", selection: $afterDeleteArchiveRaw) {
                    ForEach(PostDeleteArchiveAction.allCases) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.afterDeleteArchivePicker")
            } header: {
                Text("削除・アーカイブ")
            } footer: {
                Text("メール本文画面から削除・アーカイブ・迷惑メールにする操作をしたあと、一覧に戻るか次のメールを自動で開くかを選べます。")
            }

            Section {
                Toggle("送信者のプロフィールアイコンを表示", isOn: $showAvatarInDetail)
                    .accessibilityIdentifier("settings.list.showAvatarInDetailToggle")
            } header: {
                Text("プロフィール画像")
            } footer: {
                Text("プロフィールアイコンは差出人のイニシャルとアカウント色から生成され、外部サービスへの問い合わせは一切行いません。")
            }

            Section {
                Toggle("AI 機能 (翻訳・要約)", isOn: $aiFeaturesEnabled)
                    .accessibilityIdentifier("settings.aiFeaturesToggle")
                if aiFeaturesEnabled {
                    Toggle("英文を自動で翻訳", isOn: $autoTranslateEnglish)
                        .accessibilityIdentifier("settings.autoTranslateToggle")
                }
            } header: {
                Text("AI 機能")
            } footer: {
                Text("翻訳・要約は Apple Intelligence により端末内で行われ、外部に送信されません。オフにすると、メール本文画面の翻訳バー・AI要約ボタンの両方が表示されなくなります。")
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

            // A9「メールの表示」.
            Section {
                Toggle("常にテキストで表示", isOn: $alwaysShowPlainText)
                    .accessibilityIdentifier("settings.html.alwaysShowPlainTextToggle")
            } header: {
                Text("メールの表示 (HTML)")
            } footer: {
                Text("HTMLメールを既定でテキスト表示にします。メール詳細画面の切替ボタンで、メールごとに一時的に戻すこともできます。")
            }
        }
        .navigationTitle("メールビューア")
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
    }
}
