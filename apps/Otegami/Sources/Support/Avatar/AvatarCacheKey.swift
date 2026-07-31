import CryptoKit
import Foundation

/// アバター強化バッチ: `ContactPhotoResolver`/`GravatarAvatarResolver`が
/// ディスクキャッシュのファイル名、および (Gravatar の場合) 実際に
/// gravatar.com へ送るクエリの両方に使う SHA-256 hex ダイジェスト。1箇所に
/// まとめ、各 resolver は呼ぶだけにした。
enum AvatarCacheKey {
    /// - Parameter string: 呼び出し側が既に正規化 (trim + 小文字化) した
    ///   文字列を渡すこと — 正規化はこの関数の責務ではない (`Gravatar
    ///   AvatarResolver.gravatarURL(for:)`のドキュメントコメント参照:
    ///   Gravatar 自体の仕様が「トリム+小文字化してからハッシュ」を要求する
    ///   ため、正規化のタイミングを呼び出し側で明示的に見せておく方が
    ///   安全と判断した)。
    static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
