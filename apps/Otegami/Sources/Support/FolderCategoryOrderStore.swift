import Foundation
import OtegamiStore

/// Task #52, 3: ハンバーガーメニューのカテゴリセクション (受信トレイ/
/// アーカイブ/送信済み等、`MailboxRoleRecord.categoryOrder`) 自体の並び順を
/// ユーザーが変更できるようにする永続化 — `MessageToolbarSettingsStore`と
/// 同じ「rawValueをカンマ区切りで1つの`UserDefaults`文字列キーに書く」流儀
/// (JSON より軽く、この程度の小さい固定集合の並び順にはこれで十分)。
enum FolderCategoryOrderStore {
    static let key = "folderSheet.categoryOrder"

    static let defaultOrder = MailboxRoleRecord.categoryOrder

    /// 保存された並び順を読む。キーが未設定、または保存後にカテゴリ集合が
    /// 変わった (アプリ更新で新しい role が`categoryOrder`に増えた/減った)
    /// 場合でもクラッシュせず安全にフォールバックする —
    /// `MessageToolbarSettingsStore.loadOrder()`と同じ考え方: 保存文字列
    /// から解決できたものだけを残し、まだ含まれていない現行のカテゴリは
    /// 末尾に追記する (静かに消えることがないように)。
    static func loadOrder() -> [MailboxRoleRecord] {
        loadOrder(from: UserDefaults.standard.string(forKey: key))
    }

    /// `loadOrder()`のロジック本体 — `raw`を明示的に受け取るオーバーロード。
    /// `FolderListSheet`は`@AppStorage(FolderCategoryOrderStore.key)`で
    /// 生の文字列を直接監視し (SwiftUIの`@AppStorage`は`[MailboxRoleRecord]`
    /// のような配列型を直接は扱えないため)、これをそのつど渡すことで
    /// 「設定画面で並び替えて戻ってくると、常設マウントされたままの
    /// ドロワーにも即反映される」という反応性を得る — `FolderListSheet`
    /// 自身は再生成されない (`HamburgerMenuContainer`のdoc comment参照)
    /// ので、`loadOrder()`を`@State`の初期値として一度だけ読むだけでは
    /// 設定変更後に古いままになってしまう。
    static func loadOrder(from raw: String?) -> [MailboxRoleRecord] {
        guard let raw, !raw.isEmpty else {
            return defaultOrder
        }
        var order = raw.split(separator: ",").compactMap { MailboxRoleRecord(rawValue: String($0)) }
            .filter { defaultOrder.contains($0) }
        for role in defaultOrder where !order.contains(role) {
            order.append(role)
        }
        return order
    }

    static func saveOrder(_ order: [MailboxRoleRecord]) {
        UserDefaults.standard.set(order.map(\.rawValue).joined(separator: ","), forKey: key)
    }
}
