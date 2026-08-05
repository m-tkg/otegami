import SwiftUI

/// 「画像を常に表示する送信者」の一覧・解除画面 — 設定 →「メールビューア」
/// →「画像」セクションから開く (`MailViewerSettingsView`)。登録は本文画面の
/// 「画像を表示」バナーの「この送信者の画像を常に表示」から
/// (`HTMLMessageView.allowSenderAlwaysMenuItem`) — この画面は閲覧と削除
/// だけで、手入力での追加は設けない (アドレスの打ち間違いで意図しない
/// 送信者を許可するリスクの方が、設定画面から直接足せる便利さより重い)。
struct SenderImageAllowlistSettingsView: View {
    /// `SenderImageAllowlistStore` はカンマ結合の単一文字列で保持している
    /// ため `@AppStorage` の配列としては読めない — 表示用に `@State` へ
    /// 読み込み、削除のたびに Store と両方更新する。この画面が開いている
    /// 間に他所 (本文画面のバナー) から追加されることは画面遷移上ないので、
    /// `onAppear` での読み直しで十分。
    @State private var addresses: [String] = []

    var body: some View {
        listContainer
            .navigationTitle("画像を常に表示する送信者")
            .onAppear { addresses = SenderImageAllowlistStore.all() }
    }

    @ViewBuilder
    private var listContainer: some View {
        #if os(macOS)
        Form {
            listSection
        }
        .formStyle(.grouped)
        #else
        List {
            listSection
        }
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
        #endif
    }

    @ViewBuilder
    private var listSection: some View {
        Section {
            if addresses.isEmpty {
                Text("登録された送信者はありません")
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .accessibilityIdentifier("settings.images.senderAllowlist.empty")
            } else {
                ForEach(addresses, id: \.self) { address in
                    SenderImageAllowlistRow(address: address, onRemove: remove)
                }
            }
        } footer: {
            Text("ここに登録された送信者からのメールは、画像の自動表示設定にかかわらず、埋め込み画像・リモート画像を最初から表示します。登録はメール本文画面の「画像を表示」ボタンから行えます。")
        }
    }

    private func remove(_ address: String) {
        SenderImageAllowlistStore.remove(address)
        addresses = SenderImageAllowlistStore.all()
    }
}

/// 一覧の1行 — CLAUDE.md「行を描画する `ForEach` の中身は独立した `View`
/// 型に切り出す」(CI 型チェックタイムアウト対策) に従う。アドレスは動的
/// 文字列なので `Text(verbatim:)` (`AccountFilterChip` の教訓 —
/// `LocalizedStringKey` 経由だと `mailto:` リンク化する)。
private struct SenderImageAllowlistRow: View {
    let address: String
    let onRemove: (String) -> Void

    var body: some View {
        HStack {
            Text(verbatim: address)
                .font(OtegamiFont.body())
            Spacer()
            Button(role: .destructive, action: removeTapped) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("settings.images.senderAllowlist.remove")
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: removeTapped) {
                Label("削除", systemImage: "trash")
            }
        }
    }

    private func removeTapped() {
        onRemove(address)
    }
}
