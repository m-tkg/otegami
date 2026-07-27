import SwiftUI

/// I「設定画面の再構成」実機フィードバック第3弾: 新設カテゴリ「メール作成」。
/// 旧「その他」カテゴリに雑多に並んでいたテンプレート (C8) と送信キャンセル
/// の猶予 (C7) に加え、ルート直下の独立カテゴリだった「署名テンプレート」
/// (F) もここへ統合した — 3つとも「メールを書くときに使う設定」という
/// 共通点があり、ルート一覧に「テンプレート」的な項目が2つ (このカテゴリ
/// への入口と、旧ルート直下の署名テンプレート) 並んで見えるより、1つの
/// カテゴリの中に「テンプレート」「署名テンプレート」の2つの入口がある方が
/// 発見しやすいと判断した。`SignatureTemplateRecord`のドキュメントコメント
/// が説明する「テンプレート (全文定型) と署名 (本文末尾への付加) は別機能・
/// 別テーブル」という区別自体は変えていない — あくまで設定画面上の置き場所
/// だけの統合。
struct MailComposeSettingsView: View {
    #if os(iOS)
    @AppStorage(SendCancelSettingsStore.windowKey) private var sendCancelWindowRaw = SendCancelSettingsStore.defaultWindow.rawValue
    #endif

    var body: some View {
        List {
            // C8「メール作成のテンプレート」.
            Section {
                NavigationLink {
                    TemplatesSettingsView()
                } label: {
                    Label("テンプレート", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("settings.templatesLink")
            }

            // F「署名テンプレート」— 実機フィードバック第3弾 (I) でルート
            // 直下からこのカテゴリへ移設。
            Section {
                NavigationLink {
                    SignatureTemplatesSettingsView()
                } label: {
                    Label("署名テンプレート", systemImage: "signature")
                }
                .accessibilityIdentifier("settings.signaturesLink")
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
        }
        .navigationTitle("メール作成")
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
    }
}
