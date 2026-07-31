import Foundation

/// アバター強化バッチ: `SenderAvatar` の優先順位 (`docs/design-system.md`)
/// を実装する、複数情報源の合成 `AvatarImageResolving`。各情報源
/// (`ContactPhotoResolver`/将来の `GravatarAvatarResolver`/
/// `CompanyLogoAvatarResolver`) は自分の on/off 設定
/// (`AvatarSourceSettingsStore`) と自分自身のキャッシュを持つので、この
/// 型自身は宣言順に試して最初の非 `nil` を返すだけ — 二重キャッシュは
/// 何のメリットもない追加メモリでしかないため、ここでは持たない。
///
/// `AppEnvironment.avatarImageResolver` が唯一のインスタンスを保持し、
/// `OtegamiApp.swift` の各 `.environment(environment)` 呼び出しに併設した
/// `.environment(\.avatarImageResolver, ...)` でビュー階層へ配る — 複数の
/// `SenderAvatar` インスタンスがこの1つのインスタンスを共有することで、
/// 各情報源のキャッシュ/coalescing が一覧全体で効く。
actor CompositeAvatarImageResolver: AvatarImageResolving {
    private let sources: [any AvatarImageResolving]

    init(sources: [any AvatarImageResolving]) {
        self.sources = sources
    }

    func resolveAvatarImageData(displayName: String?, address: String) async -> Data? {
        for source in sources {
            if let data = await source.resolveAvatarImageData(displayName: displayName, address: address) {
                return data
            }
        }
        return nil
    }
}
