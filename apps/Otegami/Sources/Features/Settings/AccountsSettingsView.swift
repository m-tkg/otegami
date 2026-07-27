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

/// I「設定画面の再構成」: 設定のルート画面。以前はここに全設定 (アカウント
/// 一覧・スワイプ・翻訳・画像・etc.) がフラットな`List`として並んでいたが、
/// ユーザー指定のカテゴリ構造 (アカウントの設定/メールビューア/メール一覧/
/// 署名テンプレート/その他) に沿って5つのサブ画面へ分割した — 各設定項目
/// の実体 (`@AppStorage`キー等) は移動していない。分割後の各カテゴリ画面
/// (`AccountSettingsCategoryView`/`MailViewerSettingsView`/
/// `MailListSettingsView`/`SignatureTemplatesSettingsView`/
/// `OtherSettingsView`) を参照。
///
/// `AccountsListContent`という型名は維持している (`OtegamiSettingsView`
/// (macOS Settings シーン) がこの型を直接埋め込む既存の配線を変更せずに
/// 済むため) が、中身は「アカウント一覧」ではなく「カテゴリ一覧」に
/// 変わった — M10 時点のこの型の doc comment (nested `NavigationStack`が
/// macOS `TabView`と衝突する話) はそのまま有効: このルートも各カテゴリも
/// 独自の`NavigationStack`を持たず、埋め込まれた側の`NavigationStack`
/// (`AccountsSettingsView`の、または`OtegamiSettingsView`の"設定"タブの)
/// にそのまま`NavigationLink`で積み上がる。
struct AccountsListContent: View {
    var body: some View {
        List {
            Section {
                NavigationLink {
                    AccountSettingsCategoryView()
                } label: {
                    Label("アカウントの設定", systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("settings.category.accounts")

                NavigationLink {
                    MailViewerSettingsView()
                } label: {
                    Label("メールビューア", systemImage: "envelope.open")
                }
                .accessibilityIdentifier("settings.category.mailViewer")

                NavigationLink {
                    MailListSettingsView()
                } label: {
                    Label("メール一覧", systemImage: "list.bullet")
                }
                .accessibilityIdentifier("settings.category.mailList")

                // F「署名テンプレート」— see `SignatureTemplateRecord`'s doc
                // comment for why this is separate from C8's templates
                // (`OtherSettingsView`内) と同列のトップレベル項目にした。
                NavigationLink {
                    SignatureTemplatesSettingsView()
                } label: {
                    Label("署名テンプレート", systemImage: "signature")
                }
                .accessibilityIdentifier("settings.signaturesLink")

                NavigationLink {
                    OtherSettingsView()
                } label: {
                    Label("その他", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("settings.category.other")
            }
        }
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
    }
}
