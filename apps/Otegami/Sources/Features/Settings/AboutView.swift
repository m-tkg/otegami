import SwiftUI
import OtegamiCore

#if os(macOS)
import AppKit
#endif

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
/// その結果、この型はどこからも呼ばれなくなった (`#Preview`のみ)。
///
/// Task #182 (macOS アプリ内アップデート、実機フィードバック「update の
/// チェックができる画面は About に移動してほしい。そこから update
/// ボタンも置いて、自身のアップデートができるようにしてほしい」):
/// このAboutViewを再び使う場所ができた — `OtegamiCommands`の
/// `CommandGroup(replacing: .appInfo)`が標準の About panel の代わりに
/// この View を独立ウィンドウ (`OtegamiApp`の`WindowGroup(id: "about")`)
/// で開く。Task #158で追加された独立ウィンドウ`UpdateCheckView`はこの
/// 節の`updateSection`に統合されて廃止した (`UpdateCheckView.swift`/
/// `UpdateCheckRequest.swift`は削除済み) — 「アップデートを確認…」という
/// 独立メニュー項目も無くなり、この画面だけがアップデート関連の唯一の
/// 入口になった。
///
/// アップデート関連 UI は `#if os(macOS)` — iOS はこの機能を持たない
/// (App Store/TestFlight 配布、`CLAUDE.md`のUI設計方針・このタスクの
/// スコープ note参照)。基本情報 (アイコン/バージョン/著作権) 部分は
/// 元々どちらのプラットフォームでも動く実装だったので、そのまま両対応の
/// ままにしてある (iOS側は現状どこからも呼ばれない — この doc comment
/// 冒頭と同じ「今後iOS側で使うかもしれない」という位置づみ)。
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
        ScrollView {
            VStack(spacing: OtegamiSpacing.lg) {
                HStack(spacing: OtegamiSpacing.lg) {
                    appIcon

                    VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
                        Text("Otegami")
                            .font(OtegamiFont.title())
                            .foregroundStyle(OtegamiColor.ink)
                        Text(String(localized: "バージョン \(version) (\(build))"))
                            .font(OtegamiFont.subheadline())
                            .foregroundStyle(OtegamiColor.inkSecondary)
                            .accessibilityIdentifier("about.version")
                    }
                }

                VStack(spacing: OtegamiSpacing.sm) {
                    Text("既存のメールアカウント (Gmail / iCloud / 汎用 IMAP・SMTP) に接続する、\nオフラインファーストのオープンソースメールクライアントです。")
                        .font(OtegamiFont.body())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(OtegamiColor.inkSecondary)

                    HStack(spacing: OtegamiSpacing.md) {
                        Link("GitHub リポジトリ", destination: Self.repositoryURL)
                            .accessibilityIdentifier("about.repositoryLink")

                        Text("ライセンス: MIT")
                            .foregroundStyle(OtegamiColor.inkTertiary)
                            .accessibilityIdentifier("about.license")

                        Link("サードパーティライセンス", destination: Self.noticeURL)
                            .accessibilityIdentifier("about.thirdPartyLicensesLink")
                    }
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.accentText)
                }

                #if os(macOS)
                Rectangle()
                    .fill(OtegamiColor.dividerSubtle)
                    .frame(height: 1)
                    .padding(.vertical, OtegamiSpacing.xs)

                AboutUpdateSection()
                #endif
            }
            .padding(OtegamiSpacing.xl)
        }
        .frame(width: 460)
        .frame(minHeight: 560, idealHeight: 620, maxHeight: 720)
        // Liquid Glass Phase 5 (docs/design-system.md「Liquid Glass 方針」):
        // 独自の`OtegamiColor.background`塗りを廃止し、標準のウィンドウ/
        // スクロール背景へ委譲 (iOS は Liquid Glass 方針、macOS は
        // 2026-08-07 ネイティブ化方針と同じ判断)。
        .accessibilityIdentifier("about.view")
    }

    @ViewBuilder
    private var appIcon: some View {
        #if os(macOS)
        // Real running app icon (reflects whatever `AppIcon.appiconset`
        // actually ships) rather than a placeholder SF Symbol — this is the
        // one part of the old `UpdateCheckView`-less `AboutView` this task
        // improves on, now that this view is an actual user-facing surface
        // again instead of dead code.
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
        #else
        Image(systemName: "envelope.badge.fill")
            .font(.system(size: 56))
            .foregroundStyle(OtegamiColor.accent)
            .accessibilityHidden(true)
        #endif
    }
}

#Preview {
    AboutView()
}
