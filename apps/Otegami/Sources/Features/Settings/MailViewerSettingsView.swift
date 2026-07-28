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
    // Task #45「ダークモードで文字が読めない」.
    @AppStorage(HTMLDisplaySettingsStore.autoAdjustColorsInDarkModeKey) private var autoAdjustColorsInDarkMode = HTMLDisplaySettingsStore.defaultAutoAdjustColorsInDarkMode
    // Task #71「メールの背景を常に白に」.
    @AppStorage(HTMLDisplaySettingsStore.forceLightBackgroundKey) private var forceLightBackground = HTMLDisplaySettingsStore.defaultForceLightBackground

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
                // Task #50: 以前はここに「イニシャル+アカウント色のみ・外部
                // 照会なし」という古い記述が残っていたが、アバター強化バッチ
                // (フェーズ1〜3・Google プロフィール写真) で解決順が
                // 連絡先の写真 → Google プロフィール写真 → Gravatar →
                // 企業ロゴ → イニシャルへと拡張され、外部送信を伴う情報源も
                // 増えている (`AvatarSourceSettingsStore`)。この画面の
                // トグルは本文画面での表示可否だけを切り替え、各情報源
                // ごとの有効/無効は「メール一覧」設定の同名トグルと共有する
                // ため、そちらへの案内も添えている。
                Text("プロフィールアイコンは、差出人のイニシャル+アカウント色を基本に、連絡先の写真・Google プロフィール写真・Gravatar・企業ロゴを優先順に探して表示します。どの情報源を使うか (外部への問い合わせを含む) は「メール一覧」設定の同名のトグルで個別にオフにできます。")
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
                // Task #45「ダークモードで文字が読めない」→ Task #80 で
                // 既定 OFF・ラベル/説明を反転専用トグルとして更新。
                Toggle("ダークモードで暗い背景に反転", isOn: $autoAdjustColorsInDarkMode)
                    .accessibilityIdentifier("settings.html.autoAdjustColorsInDarkModeToggle")
                    // Task #71: この設定は「メールの背景を常に白」と排他 —
                    // 常に白がONの間はダークモード判定自体が常にスキップ
                    // される (`HTMLDocumentBuilder.wrap`側の
                    // `forceLightBackground`分岐参照) ので、トグル自体を
                    // 無効化して「今は関係ない」ことを見た目でも伝える。
                    .disabled(forceLightBackground)
                // Task #71「メールの背景を常に白に」.
                Toggle("メールの背景を常に白（ライト表示）", isOn: $forceLightBackground)
                    .accessibilityIdentifier("settings.html.forceLightBackgroundToggle")
            } header: {
                Text("メールの表示 (HTML)")
            } footer: {
                Text("HTMLメールを既定でテキスト表示にします。メール詳細画面の切替ボタンで、メールごとに一時的に戻すこともできます。ダークモード表示中、白背景・濃い文字色を明示したメール（ライトデザインのメール）は、既定では反転せずメール本来の配色（白背景）のまま表示します。色指定を持たないメールは、読みやすい配色に自動で解決されます。メール自身がダークモードに対応済みの場合は何もしません。「ダークモードで暗い背景に反転」をオンにすると、ライトデザインのメールを暗い背景に反転して表示します（文字中心のメールで暗い背景を好む場合向け）。「メールの背景を常に白」をオンにすると、色指定の有無にかかわらずすべてのメールを常に白背景で表示します（このとき上の反転設定は無効になります）。")
            }
        }
        .navigationTitle("メールビューア")
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
    }
}
