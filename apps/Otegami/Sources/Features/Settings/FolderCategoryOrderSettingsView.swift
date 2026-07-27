import SwiftUI
import OtegamiStore

/// Task #52, 3: 設定 → メール一覧 から開く、ハンバーガーメニューの
/// カテゴリセクション (受信トレイ/アーカイブ/送信済み等) の並び替え画面 —
/// `MessageToolbarSettingsView`と全く同じ形 (常時編集モードの`List`+
/// `.onMove`) を、対象を`MessageToolbarAction`から`MailboxRoleRecord`に
/// 差し替えて再利用している。「その他」(ユーザー独自フォルダ、role`.none`)
/// はここに含めない — `MailboxRoleRecord.categoryOrder`自体がそれを対象外
/// としているのと同じ理由 (`FolderListSheet.uncategorizedSection`のdoc
/// comment参照)、常にメニューの最後に固定表示される。
struct FolderCategoryOrderSettingsView: View {
    @State private var order: [MailboxRoleRecord] = FolderCategoryOrderStore.loadOrder()

    var body: some View {
        List {
            Section {
                ForEach(order, id: \.self) { role in
                    Label(role.categoryDisplayName, systemImage: role.categorySystemImage)
                        .accessibilityIdentifier("folderCategoryOrderSettings.row.\(role.rawValue)")
                }
                .onMove(perform: move)
            } footer: {
                Text("ドラッグして、フォルダメニューに並ぶカテゴリの表示順を変更できます。「その他」(独自フォルダ) は常に一番下に表示されます。")
            }
        }
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
        .navigationTitle("カテゴリの並び替え")
        .accessibilityIdentifier("folderCategoryOrderSettings.list")
        .onChange(of: order) { _, newValue in FolderCategoryOrderStore.saveOrder(newValue) }
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
    }

    private func move(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
    }
}
