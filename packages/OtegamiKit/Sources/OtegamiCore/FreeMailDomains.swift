/// アバター強化バッチ フェーズ3「企業ロゴ (BIMI/favicon)」:
/// `CompanyLogoAvatarResolver`(app 側) が、企業ドメインの favicon を企業
/// ロゴとして表示する前に「そもそもこのドメインは特定の1社を指すか」を
/// 判定するための、主要フリーメールドメインの除外リスト。
///
/// gmail.com のような大規模フリーメールプロバイダの favicon を、そのまま
/// 「送信者のアイコン」として全ユーザーの Gmail アドレスに表示してしまう
/// のは誤り (Google 社のロゴが、無関係などのユーザーからのメールにも一律
/// 付いてしまう) ため、これらのドメインは企業ロゴ解決の対象から除外し、
/// イニシャル+アカウント色のフォールバックへ委ねる。
///
/// 純粋な文字列判定のみで OS/ネットワーク API に依存しないため、
/// `OtegamiCore`(Linux 互換・依存無しの pure-logic 層) に置いている —
/// 実際の favicon 取得 (`URLSession`) はこの判定の**後**に app 側
/// (`CompanyLogoAvatarResolver`) が行う。
public enum FreeMailDomains {
    /// 網羅的なリストではない (存在しうる全世界のフリーメールプロバイダを
    /// 完全に把握することは現実的でない) — 主要な国際/日本語圏プロバイダ
    /// を中心に、実際に遭遇しやすいものを収録した。新しいプロバイダに
    /// 気付いたら追記していく運用を想定している。
    public static let domains: Set<String> = [
        // Google
        "gmail.com", "googlemail.com",
        // Microsoft
        "outlook.com", "outlook.jp", "hotmail.com", "hotmail.co.jp", "live.com", "live.jp", "msn.com",
        // Apple
        "icloud.com", "me.com", "mac.com",
        // Yahoo
        "yahoo.com", "yahoo.co.jp", "ymail.com", "rocketmail.com",
        // AOL
        "aol.com",
        // Proton
        "protonmail.com", "proton.me", "pm.me",
        // その他国際的なフリーメール
        "gmx.com", "gmx.net", "zoho.com", "mail.com", "fastmail.com", "hey.com",
        "yandex.com", "yandex.ru", "mail.ru", "qq.com", "163.com", "126.com", "naver.com", "daum.net",
        // 日本の大手キャリア/プロバイダ系フリーメール
        "docomo.ne.jp", "ezweb.ne.jp", "au.com", "softbank.ne.jp", "i.softbank.jp",
        "nifty.com", "biglobe.ne.jp", "so-net.ne.jp", "ocn.ne.jp"
    ]

    /// - Parameter domain: メールアドレスの `@` 以降 (例: `"gmail.com"`)。
    ///   大文字/小文字を区別しない。
    public static func isFreeMailDomain(_ domain: String) -> Bool {
        domains.contains(domain.lowercased())
    }

    /// `!isFreeMailDomain(_:)`の可読性のためのエイリアス
    /// (`CompanyLogoAvatarResolver`側の条件式を「企業ロゴ解決の対象か」
    /// という肯定形で読めるようにする)。
    public static func isEligibleForCompanyLogo(domain: String) -> Bool {
        !isFreeMailDomain(domain)
    }
}
