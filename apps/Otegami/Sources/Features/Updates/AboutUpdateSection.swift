import SwiftUI
import OtegamiCore

#if os(macOS)
import AppKit

/// Task #182 (macOS アプリ内アップデート): `AboutView`'s update-check/
/// install section — split into its own file/type (rather than inlined
/// into `AboutView.body`) for the same reason `CLAUDE.md`'s "SwiftUI ビューは
/// 小さく保つこと" rule always gives: a `switch` over this many states, each
/// with its own row of buttons/progress UI, is exactly the shape that has
/// blown past CI's type-check timeout before in this repo. Each state's
/// row is further split into its own small `private struct` below so no
/// single expression in this file has to type-check the whole state
/// machine at once.
///
/// Absorbs what used to be the standalone `UpdateCheckView`/
/// `UpdateCheckRequest` (Task #158, deleted by this task) — see
/// `AboutView`'s own doc comment for why this moved here, and the "pre-
/// release toggle" note below for the one behavior change from that
/// screen.
struct AboutUpdateSection: View {
    private enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate
        case available(release: GitHubRelease, version: SemanticVersion)
        case checkFailed(message: String)
        case downloading(fraction: Double)
        case verifying
        case installing
        case installed(version: String)
        case installFailed(message: String)
    }

    @State private var state: UpdateState = .idle
    /// Task #158's "アップデートを確認…" menu item used `NSEvent.modifierFlags
    /// .contains(.option)` at click time to decide this — that technique
    /// doesn't translate well to a persistent window's button (the user has
    /// long since released any modifier key by the time they read the
    /// result, and "hold Option while clicking" has no visible affordance
    /// inside a window the way a menu item can hint at in its own way
    /// either). This screen instead exposes it as an explicit, persistent
    /// checkbox — less hidden, and it survives across repeated checks
    /// without the user having to remember to hold anything down each time.
    @State private var includePrereleases = false
    /// The release the last successful check found available, kept around
    /// purely so `checkFailed`/`installFailed`'s "ダウンロードページを開く"
    /// fallback link still has somewhere to point during/after an install
    /// attempt (once `state` has moved on to `.downloading`/`.verifying`/
    /// etc., the `.available` case itself is no longer active to read
    /// `release.htmlURL` from).
    @State private var latestRelease: GitHubRelease?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
            HStack {
                Text("アップデート")
                    .font(OtegamiFont.subheadline())
                    .foregroundStyle(OtegamiColor.ink)
                Spacer(minLength: OtegamiSpacing.sm)
                Toggle("プレリリースも確認する", isOn: $includePrereleases)
                    .toggleStyle(.checkbox)
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .disabled(isBusy)
                    .accessibilityIdentifier("about.includePrereleasesToggle")
            }

            content
                .frame(minHeight: 210, maxHeight: 210, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(OtegamiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OtegamiColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: OtegamiRadius.card, style: .continuous))
        .accessibilityIdentifier("about.updateSection")
    }

    private var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .installing: true
        case .idle, .upToDate, .available, .checkFailed, .installed, .installFailed: false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            IdleUpdateRow(onCheck: check)
        case .checking:
            CheckingUpdateRow()
        case .upToDate:
            UpToDateUpdateRow(currentVersion: currentVersionString, onRecheck: check)
        case .available(let release, let version):
            AvailableUpdateRow(
                version: version,
                currentVersion: currentVersionString,
                releaseNotesExcerpt: Self.releaseNotesExcerpt(release.body),
                onOpenDownloadPage: { openURL(release.htmlURL) },
                onInstall: { install(release: release) }
            )
        case .checkFailed(let message):
            CheckFailedUpdateRow(message: message, onRetry: check)
        case .downloading(let fraction):
            DownloadingUpdateRow(fraction: fraction)
        case .verifying:
            VerifyingUpdateRow()
        case .installing:
            InstallingUpdateRow()
        case .installed(let version):
            InstalledUpdateRow(version: version, onRestartNow: restartNow)
        case .installFailed(let message):
            InstallFailedUpdateRow(
                message: message,
                onOpenDownloadPage: latestRelease.map { release in { openURL(release.htmlURL) } },
                onRetry: check
            )
        }
    }

    private var currentVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private func check() {
        Task {
            state = .checking
            do {
                let releases = try await GitHubReleaseClient().fetchReleases()
                let outcome = UpdateAvailability.check(
                    currentVersionString: currentVersionString, releases: releases, includePrereleases: includePrereleases
                )
                switch outcome {
                case .upToDate:
                    latestRelease = nil
                    state = .upToDate
                case .updateAvailable(let release, let version):
                    latestRelease = release
                    state = .available(release: release, version: version)
                }
            } catch {
                state = .checkFailed(message: Self.checkErrorMessage(for: error))
            }
        }
    }

    private func install(release: GitHubRelease) {
        guard let asset = release.zipAsset() else {
            state = .installFailed(message: String(localized: "このリリースには配布ファイルが見つかりませんでした。"))
            return
        }
        // Change the button row immediately. Waiting for URLSession's first
        // progress callback leaves the enabled-looking "更新" button on
        // screen during DNS, redirect, and response setup, making a valid
        // click look ignored on a slower connection.
        state = .downloading(fraction: 0)
        Task {
            let installer = AppUpdateInstaller()
            do {
                let outcome = try await installer.install(asset: asset) { phase in
                    Task { @MainActor in applyPhase(phase) }
                }
                state = .installed(version: outcome.installedVersion)
            } catch {
                state = .installFailed(message: Self.installErrorMessage(for: error))
            }
        }
    }

    @MainActor
    private func applyPhase(_ phase: AppUpdateInstaller.Phase) {
        switch phase {
        case .downloading(let fraction): state = .downloading(fraction: fraction)
        case .verifying: state = .verifying
        case .installing: state = .installing
        case .done: break
        }
    }

    /// `openApplication(at:configuration:)` with `createsNewApplicationInstance
    /// = true` — without it, macOS can decide "this bundle identifier is
    /// already running" and just re-activate *this* (about to terminate)
    /// process instead of actually launching the freshly-installed binary
    /// now sitting at the same path. `terminate(nil)` runs after requesting
    /// the new instance, not before — reversing the order would risk this
    /// process exiting before the request is even sent.
    private func restartNow() {
        let appURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
        NSApplication.shared.terminate(nil)
    }

    /// Only the first few lines of the release body (spec: "本文の先頭
    /// 数行") — a full changelog can be arbitrarily long and this is a
    /// small fixed-size window, not a full release-notes reader.
    private static func releaseNotesExcerpt(_ body: String?, maxLines: Int = 6) -> String? {
        guard let body, !body.isEmpty else { return nil }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        let excerpt = lines.prefix(maxLines).joined(separator: "\n")
        return excerpt.isEmpty ? nil : excerpt
    }

    private static func checkErrorMessage(for error: Error) -> String {
        if let clientError = error as? GitHubReleaseClient.ClientError {
            switch clientError {
            case .httpError(let statusCode):
                return String(localized: "GitHubへの問い合わせに失敗しました (HTTP \(statusCode))")
            case .decodingError:
                return String(localized: "GitHubからの応答を解析できませんでした")
            }
        }
        // Most common real-world case: offline / no network route.
        return String(localized: "オフラインか、GitHubに接続できませんでした")
    }

    /// Maps every `AppUpdateInstaller.InstallError` case to one of three
    /// user-facing messages, grouped by what the user should actually do
    /// about it — the specific internal reason (which zip entry was unsafe,
    /// which codesign field didn't match, ...) is deliberately not shown
    /// here; it stays out of user-facing text the same way this app never
    /// surfaces raw relay/server error bodies elsewhere (`PushNotificationSettingsView`'s
    /// doc comment makes the same call for a different subsystem).
    private static func installErrorMessage(for error: Error) -> String {
        guard let installError = error as? AppUpdateInstaller.InstallError else {
            return String(localized: "ダウンロードに失敗しました。しばらくしてから再試行してください。")
        }
        switch installError {
        case .disallowedDownloadHost, .downloadFailed:
            return String(localized: "ダウンロードに失敗しました。しばらくしてから再試行してください。")
        case .emptyArchive, .unsafeZipEntry, .extractionFailed, .appBundleNotFound,
             .appBundleEscapedExtractionDirectory, .signatureUnreadable, .signatureMismatch, .gatekeeperRejected:
            return String(localized: "検証に失敗しました。安全のため更新を中止しました。ダウンロードページから手動でインストールしてください。")
        case .noWritePermission:
            return String(localized: "書き込み権限がありません。ダウンロードページから手動でインストールしてください。")
        case .swapFailed:
            return String(localized: "更新の適用に失敗しました。元のバージョンのまま変更していません。ダウンロードページから手動でインストールしてください。")
        }
    }
}

// MARK: - Per-state rows

private struct IdleUpdateRow: View {
    let onCheck: () -> Void

    var body: some View {
        Button("アップデートを確認", action: onCheck)
            .accessibilityIdentifier("about.checkForUpdates")
    }
}

private struct CheckingUpdateRow: View {
    var body: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("確認しています…")
                .font(OtegamiFont.body())
                .foregroundStyle(OtegamiColor.inkSecondary)
        }
        .accessibilityIdentifier("about.checking")
    }
}

private struct UpToDateUpdateRow: View {
    let currentVersion: String
    let onRecheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            Text("最新版です")
                .font(OtegamiFont.body())
                .foregroundStyle(OtegamiColor.ink)
            Text(String(localized: "現在のバージョン: \(currentVersion)"))
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkTertiary)
            Button("アップデートを確認", action: onRecheck)
        }
        .accessibilityIdentifier("about.upToDate")
    }
}

private struct AvailableUpdateRow: View {
    let version: SemanticVersion
    let currentVersion: String
    let releaseNotesExcerpt: String?
    let onOpenDownloadPage: () -> Void
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
            Text("新しいバージョンがあります")
                .font(OtegamiFont.body())
                .foregroundStyle(OtegamiColor.ink)
            Text(verbatim: version.description)
                .font(OtegamiFont.subheadline())
                .foregroundStyle(OtegamiColor.inkSecondary)
                .accessibilityIdentifier("about.newVersion")
            Text(String(localized: "現在: \(currentVersion)"))
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkTertiary)
            if let releaseNotesExcerpt {
                ScrollView {
                    Text(verbatim: releaseNotesExcerpt)
                        .font(OtegamiFont.caption())
                        .foregroundStyle(OtegamiColor.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }
            HStack(spacing: OtegamiSpacing.sm) {
                Button("更新", action: onInstall)
                    .accessibilityIdentifier("about.installUpdate")
                Button("ダウンロードページを開く", action: onOpenDownloadPage)
                    .accessibilityIdentifier("about.openDownloadPage")
            }
        }
        .accessibilityIdentifier("about.available")
    }
}

private struct CheckFailedUpdateRow: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            Text("確認できませんでした")
                .font(OtegamiFont.body())
                .foregroundStyle(OtegamiColor.ink)
            Text(verbatim: message)
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkTertiary)
            Button("再試行", action: onRetry)
        }
        .accessibilityIdentifier("about.checkFailed")
    }
}

private struct DownloadingUpdateRow: View {
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            HStack(spacing: OtegamiSpacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text(fraction > 0 ? "ダウンロード中…" : "ダウンロードを開始しています…")
                    .font(OtegamiFont.body())
                    .foregroundStyle(OtegamiColor.ink)
                Spacer(minLength: OtegamiSpacing.sm)
                if fraction > 0 {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .font(OtegamiFont.caption())
                        .foregroundStyle(OtegamiColor.inkSecondary)
                        .accessibilityIdentifier("about.downloadPercentage")
                }
            }
            ProgressView(value: fraction)
                .accessibilityIdentifier("about.downloadProgress")
        }
        .accessibilityIdentifier("about.downloading")
    }
}

private struct VerifyingUpdateRow: View {
    var body: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("検証しています…")
                .font(OtegamiFont.body())
                .foregroundStyle(OtegamiColor.inkSecondary)
        }
        .accessibilityIdentifier("about.verifying")
    }
}

private struct InstallingUpdateRow: View {
    var body: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("更新を適用しています…")
                .font(OtegamiFont.body())
                .foregroundStyle(OtegamiColor.inkSecondary)
        }
        .accessibilityIdentifier("about.installing")
    }
}

private struct InstalledUpdateRow: View {
    let version: String
    let onRestartNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            Text("更新が完了しました")
                .font(OtegamiFont.body())
                .foregroundStyle(OtegamiColor.ink)
            Text(String(localized: "現在のバージョン: \(version)"))
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkTertiary)
            Button("今すぐ再起動", action: onRestartNow)
                .accessibilityIdentifier("about.restartNow")
        }
        .accessibilityIdentifier("about.installed")
    }
}

private struct InstallFailedUpdateRow: View {
    let message: String
    let onOpenDownloadPage: (() -> Void)?
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            Text("更新に失敗しました")
                .font(OtegamiFont.body())
                .foregroundStyle(OtegamiColor.ink)
            Text(verbatim: message)
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkTertiary)
            HStack(spacing: OtegamiSpacing.sm) {
                if let onOpenDownloadPage {
                    Button("ダウンロードページを開く", action: onOpenDownloadPage)
                }
                Button("再試行", action: onRetry)
            }
        }
        .accessibilityIdentifier("about.installFailed")
    }
}
#endif
