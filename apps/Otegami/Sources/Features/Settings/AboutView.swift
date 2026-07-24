import SwiftUI

/// M10 (plan: "アプリ内「バージョン情報」(About) — バージョン、ライセンス、リポジトリ
/// リンク"). Reads version/build straight from the bundle's `Info.plist`
/// (`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, `Config/Shared.xcconfig`)
/// rather than hardcoding a string here, so this view never needs editing
/// just because the version number changed.
struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private static let repositoryURL = URL(string: "https://github.com/m-tkg/otegami")!

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Otegami")
                    .font(.title2.bold())
                Text("バージョン \(version) (\(build))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("about.version")
            }

            VStack(spacing: 8) {
                Text("既存のメールアカウント (Gmail / iCloud / 汎用 IMAP・SMTP) に接続する、\nオフラインファーストのオープンソースメールクライアントです。")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Link("GitHub リポジトリ", destination: Self.repositoryURL)
                    .accessibilityIdentifier("about.repositoryLink")

                Text("ライセンス: MIT")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("about.license")
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
        .accessibilityIdentifier("about.view")
    }
}

#Preview {
    AboutView()
}
