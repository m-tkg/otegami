import Testing
@testable import OtegamiCore

/// Task #158 (macOS「アップデートを確認」機能): covers `SemanticVersion`
/// parsing and precedence — the comparison this app's update check relies
/// on to decide whether a GitHub release tag is actually newer than the
/// running `CFBundleShortVersionString`.
struct SemanticVersionTests {
    // MARK: - Parsing

    @Test("parses a bare major.minor.patch with no v prefix")
    func parsesBareVersion() {
        let version = SemanticVersion(parsing: "1.2.3")
        #expect(version == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test("parses a v-prefixed tag")
    func parsesVPrefixedTag() {
        let version = SemanticVersion(parsing: "v1.2.3")
        #expect(version == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test("parses a dotted pre-release suffix")
    func parsesPrereleaseSuffix() {
        let version = SemanticVersion(parsing: "v1.2.3-beta.1")
        #expect(version == SemanticVersion(major: 1, minor: 2, patch: 3, prereleaseIdentifiers: ["beta", "1"]))
    }

    @Test("parses a single-word pre-release suffix (no dot)")
    func parsesSingleWordPrereleaseSuffix() {
        let version = SemanticVersion(parsing: "v1.1.0-beta")
        #expect(version == SemanticVersion(major: 1, minor: 1, patch: 0, prereleaseIdentifiers: ["beta"]))
    }

    @Test("discards build metadata after +")
    func discardsBuildMetadata() {
        let version = SemanticVersion(parsing: "v1.2.3+20260729")
        #expect(version == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test("discards build metadata after a pre-release suffix")
    func discardsBuildMetadataAfterPrerelease() {
        let version = SemanticVersion(parsing: "v1.2.3-beta.1+build.5")
        #expect(version == SemanticVersion(major: 1, minor: 2, patch: 3, prereleaseIdentifiers: ["beta", "1"]))
    }

    @Test("rejects a non-numeric core component")
    func rejectsNonNumericCore() {
        #expect(SemanticVersion(parsing: "v1.2.x") == nil)
    }

    @Test("rejects too few core components")
    func rejectsTooFewComponents() {
        #expect(SemanticVersion(parsing: "v1.2") == nil)
    }

    @Test("rejects an empty pre-release suffix")
    func rejectsEmptyPrereleaseSuffix() {
        #expect(SemanticVersion(parsing: "v1.2.3-") == nil)
    }

    @Test("rejects garbage input")
    func rejectsGarbage() {
        #expect(SemanticVersion(parsing: "not-a-version") == nil)
    }

    // MARK: - Precedence: numeric core

    @Test("orders by major, then minor, then patch")
    func ordersByCore() {
        #expect(SemanticVersion(major: 1, minor: 0, patch: 0) < SemanticVersion(major: 2, minor: 0, patch: 0))
        #expect(SemanticVersion(major: 1, minor: 1, patch: 0) < SemanticVersion(major: 1, minor: 2, patch: 0))
        #expect(SemanticVersion(major: 1, minor: 1, patch: 0) < SemanticVersion(major: 1, minor: 1, patch: 1))
    }

    // MARK: - Precedence: stable vs. pre-release mixed

    @Test("a pre-release ranks below the same core release version")
    func prereleaseRanksBelowRelease() {
        let prerelease = SemanticVersion(parsing: "1.1.0-beta")!
        let release = SemanticVersion(parsing: "1.1.0")!
        #expect(prerelease < release)
        #expect(!(release < prerelease))
    }

    @Test("a pre-release of a lower core version still ranks below a higher release")
    func prereleaseOfLowerCoreRanksBelowHigherRelease() {
        let prerelease = SemanticVersion(parsing: "1.1.0-beta")!
        let release = SemanticVersion(parsing: "1.2.0")!
        #expect(prerelease < release)
    }

    // MARK: - Precedence: equal versions

    @Test("identical versions compare equal, not less-than either way")
    func equalVersionsAreNotLessThanEachOther() {
        let a = SemanticVersion(parsing: "v1.2.3-beta.1")!
        let b = SemanticVersion(parsing: "1.2.3-beta.1")!
        #expect(a == b)
        #expect(!(a < b))
        #expect(!(b < a))
    }

    // MARK: - Precedence: pre-release identifier ordering (SemVer §11 examples)

    @Test("numeric pre-release identifiers compare numerically, not lexically")
    func numericIdentifiersCompareNumerically() {
        #expect(SemanticVersion(parsing: "1.0.0-alpha.2")! < SemanticVersion(parsing: "1.0.0-alpha.10")!)
    }

    @Test("alphanumeric pre-release identifiers compare by ASCII order")
    func alphanumericIdentifiersCompareLexically() {
        #expect(SemanticVersion(parsing: "1.0.0-alpha")! < SemanticVersion(parsing: "1.0.0-beta")!)
        #expect(SemanticVersion(parsing: "1.0.0-alpha")! < SemanticVersion(parsing: "1.0.0-alpha.1")!)
    }

    @Test("a numeric identifier always ranks below an alphanumeric one at the same position")
    func numericIdentifierRanksBelowAlphanumeric() {
        #expect(SemanticVersion(parsing: "1.0.0-1")! < SemanticVersion(parsing: "1.0.0-alpha")!)
    }

    @Test("a strict identifier prefix ranks lower than the fuller set")
    func shorterIdentifierListRanksLower() {
        #expect(SemanticVersion(parsing: "1.0.0-alpha")! < SemanticVersion(parsing: "1.0.0-alpha.1")!)
    }

    @Test("full SemVer §11 example chain sorts in the documented order")
    func semVerExampleChainSortsInOrder() {
        let ordered = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
            "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0",
        ].map { SemanticVersion(parsing: $0)! }
        #expect(ordered == ordered.sorted())
    }

    // MARK: - Precedence: Task #214 undotted pre-release identifiers (betaN)

    /// This project's actual git tags are undotted (`v1.2.0-beta9`, not
    /// `v1.2.0-beta.9` — `docs/release.md`, `git tag -l "v1.2.0-beta*"`).
    /// Task #214: a strict SemVer §11 reading compares `beta9`/`beta13` as
    /// single alphanumeric identifiers by ASCII order, where `"beta13" <
    /// "beta9"` — so beta13 was ranking as *older* than beta9, and the
    /// macOS update check was offering beta9 as "latest" even with beta13
    /// already released. `init?(parsing:)` now splits a trailing digit run
    /// off each identifier so this compares numerically instead.
    @Test("undotted beta9 ranks below undotted beta13")
    func undottedBeta9RanksBelowBeta13() {
        #expect(SemanticVersion(parsing: "v1.2.0-beta9")! < SemanticVersion(parsing: "v1.2.0-beta13")!)
    }

    @Test("undotted beta2 ranks below undotted beta9")
    func undottedBeta2RanksBelowBeta9() {
        #expect(SemanticVersion(parsing: "v1.2.0-beta2")! < SemanticVersion(parsing: "v1.2.0-beta9")!)
    }

    @Test("undotted beta13 ranks below the release version")
    func undottedBeta13RanksBelowRelease() {
        #expect(SemanticVersion(parsing: "v1.2.0-beta13")! < SemanticVersion(parsing: "v1.2.0")!)
    }

    @Test("a release ranks below the next patch's pre-release")
    func releaseRanksBelowNextPatchPrerelease() {
        #expect(SemanticVersion(parsing: "v1.2.0")! < SemanticVersion(parsing: "v1.2.1-beta1")!)
    }

    @Test("undotted betaN and dotted beta.N parse to the same identifiers and compare equal")
    func undottedAndDottedNotationCompareEqual() {
        let undotted = SemanticVersion(parsing: "v1.2.0-beta13")!
        let dotted = SemanticVersion(parsing: "v1.2.0-beta.13")!
        #expect(undotted == dotted)
        #expect(undotted.prereleaseIdentifiers == ["beta", "13"])
        #expect(dotted.prereleaseIdentifiers == ["beta", "13"])
    }

    @Test("undotted and dotted notation cross-compare correctly across different numbers")
    func undottedAndDottedNotationCrossCompare() {
        #expect(SemanticVersion(parsing: "v1.2.0-beta9")! < SemanticVersion(parsing: "v1.2.0-beta.13")!)
        #expect(SemanticVersion(parsing: "v1.2.0-beta.2")! < SemanticVersion(parsing: "v1.2.0-beta9")!)
    }

    @Test("the full v1.2.0-beta2...beta13 tag sequence sorts in numeric order")
    func fullBetaTagSequenceSortsInOrder() {
        let ordered = [
            "v1.2.0-beta", "v1.2.0-beta2", "v1.2.0-beta3", "v1.2.0-beta4", "v1.2.0-beta5",
            "v1.2.0-beta6", "v1.2.0-beta7", "v1.2.0-beta8", "v1.2.0-beta9", "v1.2.0-beta10",
            "v1.2.0-beta11", "v1.2.0-beta12", "v1.2.0-beta13", "v1.2.0",
        ].map { SemanticVersion(parsing: $0)! }
        #expect(ordered == ordered.sorted())
    }

    @Test("a bare word identifier with no trailing digits is unaffected by the split")
    func bareWordIdentifierUnaffectedBySplit() {
        let version = SemanticVersion(parsing: "v1.2.0-beta")!
        #expect(version.prereleaseIdentifiers == ["beta"])
    }

    @Test("a purely numeric identifier is unaffected by the split")
    func purelyNumericIdentifierUnaffectedBySplit() {
        let version = SemanticVersion(parsing: "v1.2.0-1")!
        #expect(version.prereleaseIdentifiers == ["1"])
    }

    // MARK: - description

    @Test("description round-trips a plain version")
    func descriptionRoundTripsPlainVersion() {
        #expect(SemanticVersion(major: 1, minor: 2, patch: 3).description == "1.2.3")
    }

    @Test("description round-trips a pre-release version")
    func descriptionRoundTripsPrereleaseVersion() {
        #expect(SemanticVersion(major: 1, minor: 2, patch: 3, prereleaseIdentifiers: ["beta", "1"]).description == "1.2.3-beta.1")
    }
}
