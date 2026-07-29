import SwiftUI
import OtegamiCore

#if os(macOS)
/// Task #158 (macOS「アップデートを確認」機能): shown in its own window
/// (`OtegamiApp`'s `WindowGroup(id: "updateCheck", ...)`), opened by the
/// "Otegami" app menu's "アップデートを確認…" item
/// (`OtegamiCommands.swift`). Not a sheet — a `Commands` menu item has no
/// specific window to attach a `.sheet` to (it applies app-wide,
/// `OtegamiCommands`'s own doc comment), so this follows the same
/// "separate window per action" pattern the compose/reply windows already
/// use (`OtegamiApp.presentComposer(_:)`'s doc comment) rather than trying
/// to retrofit sheet presentation onto whichever window happens to be key.
///
/// Fetches on appear and never refetches on its own — reopening the menu
/// item always spins up a fresh `UpdateCheckRequest` (new `id`), so a
/// fresh window with a fresh `.task` is exactly "check again", with no
/// separate refresh button needed.
struct UpdateCheckView: View {
    let request: UpdateCheckRequest

    private var includePrereleases: Bool { request.includePrereleases }

    private enum LoadState {
        case checking
        case upToDate
        case available(release: GitHubRelease, version: SemanticVersion)
        case failed(String)
    }

    @State private var state: LoadState = .checking
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.lg) {
            header
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(OtegamiSpacing.xl)
        .frame(width: 420, height: 320, alignment: .top)
        .background(OtegamiColor.background)
        .task { await check() }
        .accessibilityIdentifier("updateCheck.view")
    }

    private var header: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(OtegamiColor.accent)
            Text("アップデートを確認")
                .font(OtegamiFont.headline())
                .foregroundStyle(OtegamiColor.ink)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .checking:
            HStack(spacing: OtegamiSpacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("確認しています…")
                    .font(OtegamiFont.body())
                    .foregroundStyle(OtegamiColor.inkSecondary)
            }
            .accessibilityIdentifier("updateCheck.checking")

        case .upToDate:
            VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
                Text("最新版です")
                    .font(OtegamiFont.body())
                    .foregroundStyle(OtegamiColor.ink)
                Text("現在のバージョン: \(currentVersionString)")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkTertiary)
            }
            .accessibilityIdentifier("updateCheck.upToDate")

        case .available(let release, let version):
            VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
                Text("新しいバージョンがあります")
                    .font(OtegamiFont.body())
                    .foregroundStyle(OtegamiColor.ink)
                Text("\(version.description) (現在: \(currentVersionString))")
                    .font(OtegamiFont.subheadline())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .accessibilityIdentifier("updateCheck.newVersion")
                if let notes = releaseNotesExcerpt(release.body) {
                    ScrollView {
                        Text(verbatim: notes)
                            .font(OtegamiFont.caption())
                            .foregroundStyle(OtegamiColor.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                }
                Button("ダウンロードページを開く") {
                    openURL(release.htmlURL)
                }
                .accessibilityIdentifier("updateCheck.openDownloadPage")
            }
            .accessibilityIdentifier("updateCheck.available")

        case .failed(let message):
            VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
                Text("確認できませんでした")
                    .font(OtegamiFont.body())
                    .foregroundStyle(OtegamiColor.ink)
                Text(verbatim: message)
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkTertiary)
            }
            .accessibilityIdentifier("updateCheck.failed")
        }
    }

    private var footer: some View {
        HStack {
            if includePrereleases {
                Text("プレリリースを含めて確認中")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkTertiary)
            }
        }
    }

    private var currentVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private func check() async {
        let releases: [GitHubRelease]
        do {
            releases = try await GitHubReleaseClient().fetchReleases()
        } catch {
            state = .failed(errorMessage(for: error))
            return
        }
        let outcome = UpdateAvailability.check(
            currentVersionString: currentVersionString,
            releases: releases,
            includePrereleases: includePrereleases
        )
        switch outcome {
        case .upToDate:
            state = .upToDate
        case .updateAvailable(let release, let version):
            state = .available(release: release, version: version)
        }
    }

    /// Only the first few lines of the release body (spec: "本文の先頭
    /// 数行") — a full changelog can be arbitrarily long and this is a
    /// small fixed-size window, not a full release-notes reader.
    private func releaseNotesExcerpt(_ body: String?, maxLines: Int = 6) -> String? {
        guard let body, !body.isEmpty else { return nil }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        let excerpt = lines.prefix(maxLines).joined(separator: "\n")
        return excerpt.isEmpty ? nil : excerpt
    }

    private func errorMessage(for error: Error) -> String {
        if let clientError = error as? GitHubReleaseClient.ClientError {
            switch clientError {
            case .httpError(let statusCode):
                return "GitHubへの問い合わせに失敗しました (HTTP \(statusCode))"
            case .decodingError:
                return "GitHubからの応答を解析できませんでした"
            }
        }
        // Most common real-world case: offline / no network route.
        return "オフラインか、GitHubに接続できませんでした"
    }
}

#Preview {
    UpdateCheckView(request: UpdateCheckRequest(includePrereleases: false))
}
#endif
