import Foundation

/// Task #182 (macOS アプリ内アップデート、実機フィードバック「mac 版で...
/// 自身のアップデートができるようにしてほしい」): the host allowlist a
/// download of `GitHubRelease.zipAsset(named:)`'s `browserDownloadURL` must
/// stay inside, **including every redirect hop** — spec: "ダウンロード元は
/// GitHub の Release アセット URL のみ (リダイレクト先も含め、想定外のホスト
/// へ落ちないこと)". A real `browser_download_url` (`github.com/.../releases/
/// download/...`) 302s to a signed, time-limited URL on GitHub's release-
/// asset CDN (`objects.githubusercontent.com`/`release-assets.githubusercontent.com`)
/// — this app-layer download client (`AppUpdateDownloader`, Apple-only) calls
/// `isAllowedDownloadURL` both on the initial request and on every
/// `URLSessionTaskDelegate.willPerformHTTPRedirection` hop, aborting the
/// whole download the instant a hop points anywhere else.
///
/// Kept as pure `Foundation`-only logic in `OtegamiCore` (no `URLSession`)
/// specifically so the allowlist itself is unit-testable without a network
/// stack or an app-layer target.
public enum AppUpdateDownloadPolicy {
    /// Hosts allowed to serve the *initial* request. Both are exact matches
    /// (no subdomain wildcard) since GitHub's own domains for this purpose
    /// don't vary.
    private static let allowedExactHosts: Set<String> = ["github.com", "api.github.com"]

    /// Redirect-target host *suffixes* — GitHub's release-asset CDN uses a
    /// few different `*.githubusercontent.com` hostnames depending on
    /// region/rollout, none of which this app can enumerate exactly, so this
    /// matches the whole `githubusercontent.com` family the same way a
    /// browser's own same-site cookie policy would (a proper suffix on a
    /// `.`-boundary, not a bare substring — see `isAllowedHost`).
    private static let allowedHostSuffixes: [String] = [".githubusercontent.com"]

    /// - Returns: `true` iff `url` is `https`, has a host, and that host is
    ///   either an exact allowlisted host or ends in an allowlisted suffix.
    ///   `http` is never allowed — a downgraded redirect is exactly the kind
    ///   of "unexpected hop" this exists to catch, even if the host itself
    ///   would otherwise pass.
    public static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        return isAllowedHost(url.host)
    }

    public static func isAllowedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if allowedExactHosts.contains(host) { return true }
        return allowedHostSuffixes.contains { suffix in
            // `hasSuffix` alone would also accept "evilgithubusercontent.com"
            // (no dot boundary) — require the character right before the
            // suffix to be a label separator, which for a suffix that
            // already starts with "." is automatically satisfied for a
            // strict tail match; this explicit re-check just documents the
            // intent rather than relying on `suffix`'s leading dot alone.
            host.hasSuffix(suffix) && host.count > suffix.count
        }
    }
}
