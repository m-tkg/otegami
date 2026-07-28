import SwiftUI

/// 新画面構成 (3): メール本文画面フッターツールバーの「…」メニュー →
/// 「ツールバーをカスタマイズ」から開く並び替え画面。7つのアクション
/// (`MessageToolbarAction.allCases`、Task #88 で要約/翻訳が加わり5→7)
/// は常にすべて表示される — 有効/無効の概念は無く、並び順だけを変更できる
/// (`MessageToolbarSettingsStore`'s doc comment)。
///
/// `List`+`.onMove` は既定でドラッグハンドルを見せない (通常は`EditButton`
/// で編集モードに入る必要がある) が、この画面は「並び替えること」自体が
/// 唯一の目的なので `.environment(\.editMode, .constant(.active))` で常時
/// 編集モードに固定し、余計な一手間を無くした。
struct MessageToolbarSettingsView: View {
    @State private var order: [MessageToolbarAction] = MessageToolbarSettingsStore.loadOrder()

    var body: some View {
        List {
            Section {
                ForEach(order) { action in
                    Label(action.title, systemImage: action.systemImage)
                        .accessibilityIdentifier("messageToolbarSettings.row.\(action.rawValue)")
                }
                .onMove(perform: move)
            } footer: {
                Text("ドラッグして、メール本文画面下部のツールバーに並ぶアイコンの順序を変更できます。")
            }
        }
        #if os(iOS)
        // `\.editMode` (drag handles without a separate "編集" step) is
        // iOS-only — macOS's `List`/`.onMove` shows drag handles on hover
        // by default with no equivalent environment key to force on, so
        // there's nothing to set here for that platform.
        .environment(\.editMode, .constant(.active))
        #endif
        .navigationTitle("ツールバーの編集")
        .accessibilityIdentifier("messageToolbarSettings.list")
        .onChange(of: order) { _, newValue in MessageToolbarSettingsStore.saveOrder(newValue) }
    }

    private func move(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
    }
}
