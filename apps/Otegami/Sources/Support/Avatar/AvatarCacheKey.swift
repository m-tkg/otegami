import Foundation
import PushRelayClient

/// アバター強化バッチ: `ContactPhotoResolver`/`GravatarAvatarResolver`が
/// ディスクキャッシュのファイル名、および (Gravatar の場合) 実際に
/// gravatar.com へ送るクエリの両方に使う SHA-256 hex ダイジェスト。1箇所に
/// まとめ、各 resolver は呼ぶだけにした。
///
/// 実装本体は `PushRelayClient.SharedAvatarStore.sha256Hex(_:)` に移した —
/// Communication Notification 用の App Group 共有キャッシュ
/// (`SharedAvatarStore`) が同じアドレスから同じファイル名を導出する必要が
/// あり、両ターゲットが読める場所に 1 つだけ置くのが唯一のずれない方法
/// だったため。この型はアプリ本体側の既存呼び出し元のための薄い転送。
enum AvatarCacheKey {
    /// - Parameter string: 呼び出し側が既に正規化 (trim + 小文字化) した
    ///   文字列を渡すこと — 正規化はこの関数の責務ではない (`Gravatar
    ///   AvatarResolver.gravatarURL(for:)`のドキュメントコメント参照:
    ///   Gravatar 自体の仕様が「トリム+小文字化してからハッシュ」を要求する
    ///   ため、正規化のタイミングを呼び出し側で明示的に見せておく方が
    ///   安全と判断した)。
    static func sha256Hex(_ string: String) -> String {
        SharedAvatarStore.sha256Hex(string)
    }
}
