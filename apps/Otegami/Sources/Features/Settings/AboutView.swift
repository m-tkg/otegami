import SwiftUI

/// M10 (plan: "アプリ内「バージョン情報」(About) — バージョン、ライセンス、リポジトリ
/// リンク"). Reads version/build straight from the bundle's `Info.plist`
/// (`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, `Config/Shared.xcconfig`)
/// rather than hardcoding a string here, so this view never needs editing
/// just because the version number changed.
///
/// Task #155 (2026-07-29): macOS の`OtegamiSettingsView`が「設定」/「情報」
/// の2タブ`TabView`からサイドバー+detailの`NavigationSplitView`に作り
/// 直された際、「情報」タブ (この`AboutView`の表示先) を廃止した —
/// サイドバー構成に自然に収まる場所が無く、同等の情報はメニューバーの
/// 「Otegami」→「Otegamiについて」(標準の About panel) で代替できるため。
/// その結果、この型はどこからも呼ばれなくなった (`#Preview`のみ) —
/// 今後 iOS 側などで再利用する可能性を考え、ファイル自体は削除していない。
struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private static let repositoryURL = URL(string: "https://github.com/m-tkg/otegami")!
    private static let noticeURL = URL(string: "https://github.com/m-tkg/otegami/blob/main/NOTICE")!

    var body: some View {
        VStack(spacing: OtegamiSpacing.lg) {
            Image(systemName: "envelope.badge.fill")
                .font(.system(size: 56))
                .foregroundStyle(OtegamiColor.accent)
                .accessibilityHidden(true)

            VStack(spacing: OtegamiSpacing.xs) {
                Text("Otegami")
                    .font(OtegamiFont.title())
                    .foregroundStyle(OtegamiColor.ink)
                Text("バージョン \(version) (\(build))")
                    .font(OtegamiFont.subheadline())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .accessibilityIdentifier("about.version")
            }

            VStack(spacing: OtegamiSpacing.sm) {
                Text("既存のメールアカウント (Gmail / iCloud / 汎用 IMAP・SMTP) に接続する、\nオフラインファーストのオープンソースメールクライアントです。")
                    .font(OtegamiFont.body())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(OtegamiColor.inkSecondary)

                Link("GitHub リポジトリ", destination: Self.repositoryURL)
                    .font(OtegamiFont.subheadline())
                    .foregroundStyle(OtegamiColor.accentText)
                    .accessibilityIdentifier("about.repositoryLink")

                Text("ライセンス: MIT")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkTertiary)
                    .accessibilityIdentifier("about.license")

                Link("サードパーティライセンス", destination: Self.noticeURL)
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.accentText)
                    .accessibilityIdentifier("about.thirdPartyLicensesLink")
            }
        }
        .padding(OtegamiSpacing.xxl)
        .frame(maxWidth: 420)
        .background(OtegamiColor.background)
        .accessibilityIdentifier("about.view")
    }
}

#Preview {
    AboutView()
}
