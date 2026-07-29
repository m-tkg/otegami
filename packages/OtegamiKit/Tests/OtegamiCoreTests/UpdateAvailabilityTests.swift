import Foundation
import Testing
@testable import OtegamiCore

/// Task #158 (macOS「アップデートを確認」機能): covers `UpdateAvailability
/// .check` — the stable/pre-release filtering policy plus "is there
/// actually anything newer" decision that sits between GitHub's raw release
/// list and what `UpdateCheckView` (app layer) shows the user.
struct UpdateAvailabilityTests {
    private static func release(
        tag: String,
        prerelease: Bool = false,
        draft: Bool = false
    ) -> GitHubRelease {
        GitHubRelease(
            tagName: tag,
            name: tag,
            body: "リリースノート本文 (\(tag))",
            htmlURL: URL(string: "https://github.com/m-tkg/otegami/releases/tag/\(tag)")!,
            prerelease: prerelease,
            draft: draft
        )
    }

    @Test("finds a newer stable release when only stable is requested")
    func findsNewerStableRelease() {
        let releases = [Self.release(tag: "v1.0.0"), Self.release(tag: "v1.1.0")]
        let outcome = UpdateAvailability.check(currentVersionString: "1.0.0", releases: releases, includePrereleases: false)
        guard case .updateAvailable(let release, let version) = outcome else {
            Issue.record("expected .updateAvailable, got \(outcome)")
            return
        }
        #expect(release.tagName == "v1.1.0")
        #expect(version == SemanticVersion(major: 1, minor: 1, patch: 0))
    }

    @Test("reports up to date when the current version is already the newest")
    func reportsUpToDateWhenAlreadyNewest() {
        let releases = [Self.release(tag: "v1.0.0"), Self.release(tag: "v1.1.0")]
        let outcome = UpdateAvailability.check(currentVersionString: "1.1.0", releases: releases, includePrereleases: false)
        #expect(outcome == .upToDate)
    }

    @Test("reports up to date when the current version is already newer than every release")
    func reportsUpToDateWhenAheadOfEverything() {
        let releases = [Self.release(tag: "v1.0.0")]
        let outcome = UpdateAvailability.check(currentVersionString: "2.0.0", releases: releases, includePrereleases: false)
        #expect(outcome == .upToDate)
    }

    @Test("ignores a pre-release when includePrereleases is false")
    func ignoresPrereleaseByDefault() {
        let releases = [Self.release(tag: "v1.0.0"), Self.release(tag: "v1.1.0-beta", prerelease: true)]
        let outcome = UpdateAvailability.check(currentVersionString: "1.0.0", releases: releases, includePrereleases: false)
        #expect(outcome == .upToDate)
    }

    @Test("includes a pre-release when includePrereleases is true (option-click)")
    func includesPrereleaseWhenRequested() {
        let releases = [Self.release(tag: "v1.0.0"), Self.release(tag: "v1.1.0-beta", prerelease: true)]
        let outcome = UpdateAvailability.check(currentVersionString: "1.0.0", releases: releases, includePrereleases: true)
        guard case .updateAvailable(let release, let version) = outcome else {
            Issue.record("expected .updateAvailable, got \(outcome)")
            return
        }
        #expect(release.tagName == "v1.1.0-beta")
        #expect(version == SemanticVersion(major: 1, minor: 1, patch: 0, prereleaseIdentifiers: ["beta"]))
    }

    @Test("a mixed stable+pre-release list still prefers the higher stable release over a lower pre-release, even with includePrereleases")
    func prefersHigherStableOverLowerPrerelease() {
        let releases = [
            Self.release(tag: "v1.0.0-beta", prerelease: true),
            Self.release(tag: "v1.0.0"),
        ]
        let outcome = UpdateAvailability.check(currentVersionString: "0.9.0", releases: releases, includePrereleases: true)
        guard case .updateAvailable(let release, _) = outcome else {
            Issue.record("expected .updateAvailable, got \(outcome)")
            return
        }
        #expect(release.tagName == "v1.0.0")
    }

    @Test("never surfaces a draft release even with includePrereleases")
    func neverSurfacesDraftRelease() {
        let releases = [Self.release(tag: "v9.9.9", draft: true)]
        let outcome = UpdateAvailability.check(currentVersionString: "1.0.0", releases: releases, includePrereleases: true)
        #expect(outcome == .upToDate)
    }

    @Test("treats an unparsable current version as up to date rather than erroring")
    func unparsableCurrentVersionIsUpToDate() {
        let releases = [Self.release(tag: "v1.0.0")]
        let outcome = UpdateAvailability.check(currentVersionString: "?", releases: releases, includePrereleases: false)
        #expect(outcome == .upToDate)
    }

    @Test("an empty release list is up to date")
    func emptyReleaseListIsUpToDate() {
        let outcome = UpdateAvailability.check(currentVersionString: "1.0.0", releases: [], includePrereleases: false)
        #expect(outcome == .upToDate)
    }

    @Test("skips releases whose tag doesn't parse as SemVer")
    func skipsUnparsableTags() {
        let releases = [Self.release(tag: "not-a-version"), Self.release(tag: "v1.1.0")]
        let outcome = UpdateAvailability.check(currentVersionString: "1.0.0", releases: releases, includePrereleases: false)
        guard case .updateAvailable(let release, _) = outcome else {
            Issue.record("expected .updateAvailable, got \(outcome)")
            return
        }
        #expect(release.tagName == "v1.1.0")
    }
}
