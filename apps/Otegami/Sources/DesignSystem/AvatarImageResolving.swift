import SwiftUI

/// アバター強化バッチ: `SenderAvatar` の背後にある画像解決の抽象。優先順位
/// (連絡先の写真 → Gravatar → BIMI/企業ロゴ → イニシャル、`docs/design-system.md`
/// のこのバッチの節参照) の実装は `apps/Otegami/Sources/Support/` 側が担う —
/// `Contacts`/`URLSession` に依存する具象型を `DesignSystem` (アプリ本体と
/// `DesignSystemCatalog` の両方がビルドする層) に置くと、使用目的文言
/// (`NSContactsUsageDescription`) を持たないカタログ実行ターゲットからでも
/// `CNContactStore` に触れかねない。このファイルは Foundation only の純粋な
/// プロトコル + SwiftUI `EnvironmentValues` 配線だけを持つ。
///
/// `nil` を返すことは「このアドレスには画像が無い/取得できなかった」を表し、
/// エラーではない — `SenderAvatar` は常にイニシャル+アカウント色へフォール
/// バックできるので、呼び出し側に伝えるべき失敗はそもそも存在しない
/// (連絡先が見つからない・権限が無い・Gravatar が404・企業ロゴのドメインが
/// 対象外、いずれも同じ「この情報源では出せなかった」という結果)。
public protocol AvatarImageResolving: Sendable {
    /// - Parameters:
    ///   - displayName: 差出人の表示名 (`EmailAddress.name`)。現在の実装は
    ///     どれもアドレスだけで解決するが、将来の情報源のために渡しておく。
    ///   - address: 差出人のメールアドレス。解決の主キー。
    /// - Returns: 生の画像バイト列 (情報源が返した形式のまま — PNG/JPEG 等)、
    ///   またはこのアドレスに表示できる画像が無いとき `nil`。
    func resolveAvatarImageData(displayName: String?, address: String) async -> Data?
}

private struct AvatarImageResolverKey: EnvironmentKey {
    static let defaultValue: (any AvatarImageResolving)? = nil
}

extension EnvironmentValues {
    /// アプリ全体で1つのインスタンスを共有する想定 (`AppEnvironment
    /// .avatarImageResolver`、`OtegamiApp.swift` の各 `.environment(environment)`
    /// 呼び出し箇所に併設) — インメモリキャッシュや「同一アドレスの重複解決を
    /// coalesce する」仕組みがインスタンスをまたいでは効かないため。`nil` の
    /// まま (未注入) なら `SenderAvatar` は常にイニシャル表示のみになる —
    /// `DesignSystemCatalog` (Contacts の使用目的文言を持たない別実行ターゲット)
    /// がこの値を注入しないのはそのため: 注入しなければ `CNContactStore`/
    /// `URLSession` の類に一切触れない。
    public var avatarImageResolver: (any AvatarImageResolving)? {
        get { self[AvatarImageResolverKey.self] }
        set { self[AvatarImageResolverKey.self] = newValue }
    }
}
