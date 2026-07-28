import SwiftUI

/// 新画面構成 (3): メール本文画面フッターツールバーの「…」メニュー →
/// 「ツールバーをカスタマイズ」、および設定 →「メールビューア」→
/// 「ツールバーのカスタマイズ」の両方から開く設定画面。
///
/// Task #100 (「フッターツールバーのカスタマイズ」) で、それまでの
/// 「並び替えのみ」から「表示/非表示のトグル + 表示中アクションのみの
/// ドラッグ並び替え」に拡張した:
/// - 表示オンの6アクション (「その他」を除く) はトグルで非表示にでき、
///   ドラッグで並び替えられる (`reorderableSection`)。
/// - 非表示にしたアクションはツールバーから消えるのではなく、「その他」
///   メニューの中から引き続き使える
///   (`MessageDetailFooterToolbar.hiddenActionMenuItems`)。
/// - 「その他」自身は別セクション (`pinnedTrailingSection`) に固定表示 —
///   トグルも並び替えハンドルも出さず、グレーアウトして「常に表示・
///   常に最後尾・変更不可」であることを見た目でも伝える。
///
/// `List`+`.onMove` は既定でドラッグハンドルを見せない (通常は`EditButton`
/// で編集モードに入る必要がある) が、この画面は「並び替えること」自体が
/// 主要な目的の一つなので `.environment(\.editMode, .constant(.active))` で
/// 常時編集モードに固定し、余計な一手間を無くした
/// (トグル自体は編集モード中でも通常どおり操作できる — `List`の編集モードが
/// 抑制するのは`onDelete`/`onMove`のための行の先頭/末尾アクセサリだけで、
/// 行本体のコンテンツはそのまま反応する)。
struct MessageToolbarSettingsView: View {
    @State private var items: [MessageToolbarItemSetting] = MessageToolbarSettingsStore.loadItems()

    /// 「その他」を除いた6アクション — 表示/非表示トグル・ドラッグ並び替え
    /// の対象。ストア側の不変条件 (`MessageToolbarPreferencesCoding`) により
    /// `items`の末尾は常に`more`なので、単純に末尾を除けばよい。
    private var reorderableItems: [MessageToolbarItemSetting] {
        items.filter { $0.action != .more }
    }

    var body: some View {
        List {
            Section {
                ForEach(reorderableItems) { item in
                    MessageToolbarSettingsRow(item: item, onToggleVisibility: { toggleVisibility(item.action, isVisible: $0) })
                }
                .onMove(perform: move)
            } header: {
                Text("表示するアイコン")
            } footer: {
                Text("トグルをオフにしたアイコンは、ツールバーから消えて「その他」メニューの中から使えるようになります。ドラッグで、オンのアイコンがツールバーに並ぶ順序を変更できます。")
            }

            Section {
                MessageToolbarSettingsPinnedRow()
            } footer: {
                Text("「その他」は常にツールバーの末尾に固定表示され、オフにしたり並べ替えたりすることはできません。")
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
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
        .accessibilityIdentifier("messageToolbarSettings.list")
    }

    private func move(from source: IndexSet, to destination: Int) {
        var reordered = reorderableItems
        reordered.move(fromOffsets: source, toOffset: destination)
        persist(reordered)
    }

    private func toggleVisibility(_ action: MessageToolbarAction, isVisible: Bool) {
        var updated = reorderableItems
        guard let index = updated.firstIndex(where: { $0.action == action }) else { return }
        updated[index].isVisible = isVisible
        persist(updated)
    }

    /// `reorderableItems` (「その他」を除く6件) を並び替え/トグル後の内容で
    /// 差し替え、`more`を末尾に付け直して保存する — `saveItems`側でも
    /// `MessageToolbarPreferencesCoding.normalize`が同じ不変条件を強制する
    /// ので実質二重の安全網だが、`items`(この画面の表示用`@State`) 自体も
    /// 常に正規化済みの形に保つため、ここでも明示的に付け直す。
    private func persist(_ updatedReorderableItems: [MessageToolbarItemSetting]) {
        let pinnedTrailing = MessageToolbarItemSetting(action: .more, isVisible: true)
        items = updatedReorderableItems + [pinnedTrailing]
        MessageToolbarSettingsStore.saveItems(items)
    }
}

/// `MessageToolbarSettingsView`の`ForEach`本体を切り出した1行 — `docs/ci.md`
/// が警告する「`List`/`ForEach`の中身は独立した`View`型に切り出す」方針
/// (`CLAUDE.md`)。
private struct MessageToolbarSettingsRow: View {
    let item: MessageToolbarItemSetting
    let onToggleVisibility: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { item.isVisible }, set: onToggleVisibility)) {
            Label(item.action.title, systemImage: item.action.systemImage)
        }
        .accessibilityIdentifier("messageToolbarSettings.row.\(item.action.rawValue)")
    }
}

/// 「その他」専用の固定行 — トグルも並び替えハンドルも持たない別セクション
/// (`MessageToolbarSettingsView.body`) に置き、`.onMove`対象の`ForEach`にも
/// 含めないことで「常に最後尾・変更不可」をデータ構造レベルでも保証する。
/// 見た目のグレーアウトはこの不変性をユーザーにも伝えるための補足。
private struct MessageToolbarSettingsPinnedRow: View {
    var body: some View {
        Label(MessageToolbarAction.more.title, systemImage: MessageToolbarAction.more.systemImage)
            .foregroundStyle(OtegamiColor.inkTertiary)
            .accessibilityIdentifier("messageToolbarSettings.row.more")
    }
}
