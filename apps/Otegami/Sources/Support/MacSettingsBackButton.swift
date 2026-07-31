import SwiftUI

#if os(macOS)
/// Task #155 follow-up (2026-07-29 実機報告「設定 → アカウントを編集を
/// 開くと、タイトルの真下・中央に丸い『<』戻るボタンが浮いている」):
/// `MacSettingsSplitView`(`OtegamiSettingsView.swift`)の detail 側
/// `NavigationStack`で2段目以降にプッシュされる画面 (`AccountEditView`等)
/// が対象。
///
/// **原因**: `Settings { }` シーンの`NavigationSplitView`は、通常の
/// `WindowGroup`と違い、`.toolbar`の内容がウィンドウの実タイトルバーへ
/// マージされず、コンテンツ内にインラインで描画される — この
/// シーン自身の自動サイドバートグルボタン (`NavigationSplitView`が
/// 何も指定せずとも出す標準ボタン) が、タイトルバーではなくサイドバー
/// 内容の先頭にインライン描画されることで確認済み (`.navigation`
/// placementの実レイアウトが不安定になりうることは`docs/design-system.md`
/// のTask #109でも既出)。この結果、プッシュされた画面の自動生成の戻る
/// ボタンが、他に並ぶツールバー項目のない単独の toolbar item として、
/// タイトル直下の中央寄せで浮いて見える。
///
/// **対策**: toolbar/タイトルバーのマージに一切依存しない、通常の
/// ビューコンテンツとして左寄せの戻るボタンを自前で描画する。
/// `.navigationBarBackButtonHidden(true)` — macOS でも実際に呼べる
/// (SDKの`SwiftUI.swiftinterface`を確認: 同じ拡張の`navigationBarTitle`系
/// 各オーバーロードには軒並み`@available(macOS, unavailable)`が付いて
/// いるのに対し、このメソッドだけ付いていない = macOSでも利用可能) —
/// で自動生成のボタンを消し、`.safeAreaInset(edge: .top, alignment:
/// .leading)`で戻るボタンを差し込む。`dismiss()`はこの`NavigationStack`
/// が(旧`TabView`ネスト構造と違い)`TabView`の外にあるため問題なく動く
/// 経路 (`OtegamiSettingsView`の doc comment 参照)。
///
/// `.navigationTitle(_:)`自体はそのまま — ウィンドウの実タイトルバー
/// テキストは(戻るボタンと違い)正しくマージされることを確認済みなので、
/// このモディファイアは戻るボタンの位置だけを直す。
///
/// 適用対象: `GeneralSettingsView`/`AccountSettingsCategoryView`/
/// `MailListSettingsView`/`MailComposeSettingsView`/
/// `MailViewerSettingsView`(カテゴリ画面自体は detail の1段目 = プッシュ
/// されていないので対象外)から2段目以降にプッシュされる画面すべて —
/// `AccountEditView`・`MailboxVisibilityView`・
/// `GoogleAvatarDiagnosticsView`・`PushNotificationSettingsView`(Task #212
/// で`AccountSettingsCategoryView`から`GeneralSettingsView`配下へ移設)・
/// `DefaultMailAppSettingsView`・`MessageToolbarSettingsView`
/// (ツールバーカスタマイズ)・`SignatureTemplatesSettingsView`/
/// `SignatureTemplateEditView`等。
struct MacSettingsBackButton: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .safeAreaInset(edge: .top, alignment: .leading, spacing: 0) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("戻る")
                .accessibilityIdentifier("macSettings.backButton")
                .padding(.leading, OtegamiSpacing.md)
                .padding(.top, OtegamiSpacing.sm)
        }
    }
}

extension View {
    /// See `MacSettingsBackButton`'s doc comment.
    func macSettingsBackButton() -> some View {
        modifier(MacSettingsBackButton())
    }
}
#endif
