import Foundation

/// アバター強化バッチ: `SenderAvatar` の優先順位付き情報源のうち、外部/OS
/// リソースに触れる各段 (連絡先・Gravatar・企業ロゴ) の on/off。イニシャル+
/// アカウント色 (最終フォールバック) は常に有効で、この設定の対象外
/// (`ListDisplaySettingsStore.showAvatarKey`/`showAvatarInDetailKey` が
/// アバター行自体の表示/非表示を制御する、より上位のトグル)。
///
/// 設定 UI は既存の `MailListSettingsView` の「表示」セクション
/// (`listDisplay.showAvatar` の直後) に置く — 差出人アバターに関する設定は
/// すべてそこに集約する、という既存の置き場所に合わせた
/// (`docs/settings.md` 参照)。
///
/// `ListDisplaySettingsStore`/`ImageSettingsStore` と同じ「プレーンな
/// `UserDefaults` キーの集まり」方針。`ContactPhotoResolver`/
/// `GravatarAvatarResolver`/`CompanyLogoAvatarResolver` (actor、`@AppStorage`
/// を使えない) は `UserDefaults.standard` を直接読むため、
/// `registerOtegamiAvatarSourceDefaults()` (`AppEnvironment.init()` から
/// 呼ぶ、`UserDefaults.registerOtegamiImageDefaults()` と同じ理由 —
/// `ImageSettingsStore`のドキュメントコメント参照) で未設定キーでも正しい
/// 既定値に解決されるようにしてある。
enum AvatarSourceSettingsStore {
    /// フェーズ1「連絡先の写真」— オンデバイスの `CNContactStore` のみを使う
    /// (外部送信なし)。既定 ON。
    static let showContactPhotoKey = "avatarSource.showContactPhoto"
    static let defaultShowContactPhoto = true

    static var isContactPhotoEnabled: Bool {
        UserDefaults.standard.bool(forKey: showContactPhotoKey)
    }
}

extension UserDefaults {
    static func registerOtegamiAvatarSourceDefaults() {
        standard.register(defaults: [
            AvatarSourceSettingsStore.showContactPhotoKey: AvatarSourceSettingsStore.defaultShowContactPhoto
        ])
    }
}
