import Foundation

/// 「この送信者の画像は常に表示」(リモート画像バナーの Menu 項目 —
/// `HTMLMessageView.imagesBanner`) の送信者別許可リスト。ここに載っている
/// アドレスからのメールは、「リモート画像を自動で読み込む」(B6) がオフ
/// でもリモート画像を最初から表示する (`HTMLMessageView.init` が
/// `allowsExternalContent` の初期値に反映)。
///
/// 保存形式はカンマ結合の単一文字列 — `UserDefaults` の配列でなくこの形に
/// したのは、`AppSettingsCloudDirectory.stringDefaults` (iCloud 同期) が
/// 文字列値だけを扱い、`FolderCategoryOrderStore` 等のカンマ結合リストの
/// 前例に既に依存しているため。メールアドレスの実運用値にカンマは現れない
/// (RFC 上 quoted local part では可能だが、その場合も `normalize` 前の
/// 生アドレスを扱う箇所はここには無い)。
///
/// アドレスは小文字化して保持・比較する (`normalize`) — メールアドレスの
/// domain 部は大文字小文字を区別せず、local part も実運用では区別しない
/// サーバーが支配的で、「同じ送信者なのに大文字の差で許可が効かない」方が
/// 明確に有害なため。
enum SenderImageAllowlistStore {
    static let allowlistKey = "images.senderRemoteImageAllowlist"

    static func normalize(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func all(defaults: UserDefaults = .standard) -> [String] {
        guard let joined = defaults.string(forKey: allowlistKey), !joined.isEmpty else { return [] }
        return joined.split(separator: ",").map(String.init)
    }

    static func contains(_ address: String, defaults: UserDefaults = .standard) -> Bool {
        all(defaults: defaults).contains(normalize(address))
    }

    static func add(_ address: String, defaults: UserDefaults = .standard) {
        let normalized = normalize(address)
        guard !normalized.isEmpty else { return }
        var list = all(defaults: defaults)
        guard !list.contains(normalized) else { return }
        list.append(normalized)
        defaults.set(list.joined(separator: ","), forKey: allowlistKey)
    }

    static func remove(_ address: String, defaults: UserDefaults = .standard) {
        let normalized = normalize(address)
        let list = all(defaults: defaults).filter { $0 != normalized }
        defaults.set(list.joined(separator: ","), forKey: allowlistKey)
    }
}
