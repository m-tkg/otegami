import Foundation

/// Task #158 (macOS「アップデートを確認」機能): one entry from GitHub's
/// [list releases](https://docs.github.com/en/rest/releases/releases#list-releases)
/// API (`GET /repos/m-tkg/otegami/releases`, unauthenticated — this is a
/// public repo). Only the fields this app actually reads; the real response
/// has many more. `OtegamiCore`-resident (pure `Codable` data, no networking)
/// so `UpdateAvailability.check` can be unit-tested with hand-built fixtures
/// instead of a real HTTP round trip — the app layer
/// (`Features/Updates/GitHubReleaseClient.swift`) owns the actual
/// `URLSession` fetch and decode.
public struct GitHubRelease: Codable, Sendable, Equatable {
    /// The git tag, e.g. `"v1.2.3"` or `"v1.2.3-beta.1"` (`docs/xcode-cloud.md`'s
    /// `v*` tag convention) — this app's own release tags always parse via
    /// `SemanticVersion.init(parsing:)`; a release from some other tagging
    /// scheme would just be skipped by `UpdateAvailability.check` instead of
    /// crashing anything.
    public let tagName: String
    public let name: String?
    /// Release notes body (Markdown) — the app shows only its first few
    /// lines, not this whole string.
    public let body: String?
    public let htmlURL: URL
    public let prerelease: Bool
    public let draft: Bool

    public init(tagName: String, name: String?, body: String?, htmlURL: URL, prerelease: Bool, draft: Bool) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.prerelease = prerelease
        self.draft = draft
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case prerelease
        case draft
    }
}

/// The result of comparing this app's current version against the releases
/// GitHub reports — what `UpdateCheckView` (app layer) renders directly.
public enum UpdateCheckOutcome: Sendable, Equatable {
    /// A release newer than the current version was found, along with the
    /// `SemanticVersion` it parsed to (so the view doesn't need to re-parse
    /// `release.tagName` just to display it consistently formatted).
    case updateAvailable(release: GitHubRelease, version: SemanticVersion)
    /// Either the current version is already the newest of the eligible
    /// releases, or there were no eligible releases at all (e.g. an empty
    /// repo, or every release's tag failed to parse as SemVer) — both read
    /// as "最新版です" to the user; there is nothing actionable to tell them
    /// apart on, and treating "nothing to update to" as an error would be
    /// misleading since the fetch itself succeeded.
    case upToDate
}

/// Pure comparison logic — no networking, no current-version lookup beyond
/// the string it's handed. Kept as a standalone enum (rather than a method
/// on `GitHubRelease`/`SemanticVersion`) since it composes both plus a
/// filtering policy (drafts always excluded; pre-releases excluded unless
/// `includePrereleases`) that belongs to neither type individually.
public enum UpdateAvailability {
    /// - Parameters:
    ///   - currentVersionString: this app's own version, e.g. `Bundle.main
    ///     .infoDictionary?["CFBundleShortVersionString"]`. A `v` prefix is
    ///     tolerated but not required.
    ///   - releases: the raw list GitHub's releases API returned, in any
    ///     order — this does not assume they're pre-sorted by recency.
    ///   - includePrereleases: option-click behavior (spec: 通常クリック =
    ///     安定版のみ, option+クリック = pre-release も対象) — when `false`,
    ///     every `release.prerelease == true` entry is ignored entirely, as
    ///     if it didn't exist.
    /// - Returns: `.upToDate` if `currentVersionString` doesn't even parse as
    ///   a `SemanticVersion` — an unparsable "current version" can't be
    ///   meaningfully compared against anything, and silently doing nothing
    ///   is safer than reporting a phantom update.
    public static func check(
        currentVersionString: String,
        releases: [GitHubRelease],
        includePrereleases: Bool
    ) -> UpdateCheckOutcome {
        guard let currentVersion = SemanticVersion(parsing: currentVersionString) else { return .upToDate }

        let eligible = releases.filter { release in
            !release.draft && (includePrereleases || !release.prerelease)
        }
        let parsed = eligible.compactMap { release -> (release: GitHubRelease, version: SemanticVersion)? in
            guard let version = SemanticVersion(parsing: release.tagName) else { return nil }
            return (release, version)
        }
        guard let latest = parsed.max(by: { $0.version < $1.version }) else { return .upToDate }

        guard latest.version > currentVersion else { return .upToDate }
        return .updateAvailable(release: latest.release, version: latest.version)
    }
}
