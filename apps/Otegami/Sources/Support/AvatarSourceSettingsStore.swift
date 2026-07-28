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
/// Task #60: `AppEnvironment.init()`の`OTEGAMI_UITEST_DISABLE_AVATAR_SOURCES`
/// はこの4キーすべてを強制的に`false`へ上書きする、UITest/verify-script
/// 専用のエスケープハッチ — 連絡先権限ダイアログの非決定的な出現
/// (`docs/verify.md`「シミュレータ検証の既知の不調」参照) を根絶するため。
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

    /// アバター強化バッチ「Google プロフィール写真」— Gmail (OAuth) アカウント
    /// が1つ以上ある場合に限り、差出人アドレスを Google People API に送信して
    /// プロフィール写真を取得する (`GoogleProfilePhotoAvatarResolver`)。連絡先
    /// の写真の次、Gravatar の前の優先順位。Gravatar と同じく外部サービスへの
    /// 通信を伴うため既定 ON・設定でいつでも無効化できる。既定 ON。
    static let showGoogleProfilePhotoKey = "avatarSource.showGoogleProfilePhoto"
    static let defaultShowGoogleProfilePhoto = true

    static var isGoogleProfilePhotoEnabled: Bool {
        UserDefaults.standard.bool(forKey: showGoogleProfilePhotoKey)
    }

    /// フェーズ2「Gravatar」— 差出人アドレスの SHA-256 ハッシュを
    /// gravatar.com へ送信して画像を取得する。連絡先の写真と違い外部
    /// サービスへの通信を伴うため、設定画面には「差出人アドレスのハッシュ
    /// が gravatar.com に送信されます」という注記を添えている
    /// (`MailListSettingsView`)。既定 ON。
    static let showGravatarKey = "avatarSource.showGravatar"
    static let defaultShowGravatar = true

    static var isGravatarEnabled: Bool {
        UserDefaults.standard.bool(forKey: showGravatarKey)
    }

    /// フェーズ3「企業ロゴ (favicon)」— `CompanyLogoAvatarResolver`のドキュ
    /// メントコメント参照 (BIMI は実装していない)。既定 ON。
    static let showCompanyLogoKey = "avatarSource.showCompanyLogo"
    static let defaultShowCompanyLogo = true

    static var isCompanyLogoEnabled: Bool {
        UserDefaults.standard.bool(forKey: showCompanyLogoKey)
    }
}

extension UserDefaults {
    static func registerOtegamiAvatarSourceDefaults() {
        standard.register(defaults: [
            AvatarSourceSettingsStore.showContactPhotoKey: AvatarSourceSettingsStore.defaultShowContactPhoto,
            AvatarSourceSettingsStore.showGoogleProfilePhotoKey: AvatarSourceSettingsStore.defaultShowGoogleProfilePhoto,
            AvatarSourceSettingsStore.showGravatarKey: AvatarSourceSettingsStore.defaultShowGravatar,
            AvatarSourceSettingsStore.showCompanyLogoKey: AvatarSourceSettingsStore.defaultShowCompanyLogo
        ])
    }
}
