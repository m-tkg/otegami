import SwiftUI

/// I「設定画面の再構成」→「メールビューア」: ブラウザの設定 (C7)・G「メール
/// 削除/アーカイブ時の挙動」・メール本文へのプロフィール画像表示・
/// AI 機能の on/off (翻訳・要約をまとめて)。
struct MailViewerSettingsView: View {
    // C7「メール内リンクを開くブラウザ」— iOS only (`LinkBrowserSettingsStore`
    // の doc comment参照)。
    @AppStorage(LinkBrowserSettingsStore.openInAppBrowserKey) private var openInAppBrowser = LinkBrowserSettingsStore.defaultOpenInAppBrowser
    /// G「メール削除/アーカイブ時の挙動」.
    @AppStorage(MessagePostActionSettingsStore.afterDeleteArchiveKey) private var afterDeleteArchiveRaw = MessagePostActionSettingsStore.defaultAfterDeleteArchive.rawValue
    @AppStorage(ListDisplaySettingsStore.showAvatarInDetailKey) private var showAvatarInDetail = ListDisplaySettingsStore.defaultShowAvatarInDetail
    /// I「AI 機能の on/off (翻訳・要約をまとめて)」.
    @AppStorage(AIFeaturesSettingsStore.enabledKey) private var aiFeaturesEnabled = AIFeaturesSettingsStore.defaultEnabled
    @AppStorage(TranslationSettingsStore.autoTranslateEnglishKey) private var autoTranslateEnglish = true

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
        }
        .navigationTitle("メールビューア")
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
    }
}
