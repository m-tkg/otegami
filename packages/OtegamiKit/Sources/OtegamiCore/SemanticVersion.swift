import Foundation

/// Task #158 (macOS「アップデートを確認」機能): a minimal [SemVer
/// 2.0.0](https://semver.org)-precedence-compatible version, used to compare
/// this app's own `CFBundleShortVersionString` against a GitHub release's
/// tag name (`v1.2.3`, `v1.2.3-beta.1`, etc. — `docs/xcode-cloud.md`'s `v*`
/// tag convention). Deliberately pure `Foundation`, no dependencies —
/// lives in `OtegamiCore` (Linux-compatible layer) so it's unit-testable
/// via a plain `swift test` with no networking or platform APIs involved.
///
/// Only implements what this app actually needs to compare: major.minor.patch
/// plus dot-separated pre-release identifiers (build metadata after `+` is
/// parsed away, per spec, since it never affects precedence). Does not claim
/// full SemVer *validation* — `init?(parsing:)` is deliberately permissive
/// about anything past the three required numeric components.
///
/// Task #214: `init?(parsing:)` also does one thing standard SemVer §11
/// precedence does *not* — it splits a trailing digit run off an
/// alphanumeric identifier (`beta9` → `["beta", "9"]`) so it compares
/// numerically. See the comment at that call site for why: this project's
/// actual tags are undotted (`v1.2.0-beta9`, not `v1.2.0-beta.9`), and
/// without this, `beta13` sorts as *older* than `beta9` under a strict
/// reading of the spec.
public struct SemanticVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Dot-separated identifiers after the first `-` (e.g. `["beta", "1"]`
    /// for `1.2.3-beta.1`). Empty means this is a release version, not a
    /// pre-release — the highest-precedence case for a given
    /// major.minor.patch per SemVer §11.
    public let prereleaseIdentifiers: [String]

    public init(major: Int, minor: Int, patch: Int, prereleaseIdentifiers: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prereleaseIdentifiers = prereleaseIdentifiers
    }

    /// Parses e.g. `"v1.2.3"`, `"1.2.3-beta.1"`, `"v1.2.3-beta.1+build.5"`.
    /// A leading `v`/`V` (this project's tag convention) is stripped if
    /// present but not required, so this also parses a bare
    /// `CFBundleShortVersionString` like `"1.2.3"`. Returns `nil` if the
    /// core isn't exactly three dot-separated non-negative integers.
    public init?(parsing raw: String) {
        var remainder = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.hasPrefix("v") || remainder.hasPrefix("V") {
            remainder.removeFirst()
        }
        // Build metadata never affects precedence (SemVer §10) — discard it.
        if let plusIndex = remainder.firstIndex(of: "+") {
            remainder = String(remainder[remainder.startIndex..<plusIndex])
        }
        var core = remainder
        var prerelease: [String] = []
        if let dashIndex = remainder.firstIndex(of: "-") {
            core = String(remainder[remainder.startIndex..<dashIndex])
            let prereleasePart = String(remainder[remainder.index(after: dashIndex)...])
            guard !prereleasePart.isEmpty else { return nil }
            prerelease = prereleasePart.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard prerelease.allSatisfy({ !$0.isEmpty }) else { return nil }
            // Task #214: this project's actual tag convention (docs/release.md,
            // `git tag -l "v1.2.0-beta*"`) is undotted — `beta9`, `beta13`, not
            // `beta.9`. Strict SemVer §11 treats `beta9` as a single alphanumeric
            // identifier and compares it to `beta13` by ASCII order, where
            // `"beta13" < "beta9"` (the byte '1' < '3' at the first differing
            // position) — i.e. beta13 would rank as *older* than beta9. That is
            // exactly the bug this task fixes (a real GitHub release comparison
            // picked beta9 as "latest" over beta13).
            //
            // Deliberate departure from the spec: split a trailing run of digits
            // off each identifier here, at parse time, so `beta9` becomes
            // `["beta", "9"]` and `beta13` becomes `["beta", "13"]` — the same
            // two identifiers `beta.13` would already produce. This makes the
            // numeric tail compare numerically (13 > 9) regardless of whether
            // the tag used a dot, so `v1.2.0-beta9`/`v1.2.0-beta.9` and
            // `v1.2.0-beta13`/`v1.2.0-beta.13` always compare identically.
            prerelease = prerelease.flatMap(Self.splittingTrailingDigits)
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0,
              let patch = Int(parts[2]), patch >= 0
        else { return nil }
        self.init(major: major, minor: minor, patch: patch, prereleaseIdentifiers: prerelease)
    }

    /// Splits a `"word" + trailing digits` identifier like `"beta9"` into
    /// `["beta", "9"]`; anything else (already purely numeric, or with no
    /// trailing digit run at all, e.g. `"beta"`/`"rc"`) is returned unchanged
    /// as a single-element array. See the call site in `init?(parsing:)` for
    /// why this exists — it's what makes `beta9` and `beta.9` parse to the
    /// same identifier list.
    private static func splittingTrailingDigits(_ identifier: String) -> [String] {
        guard let lastNonDigitIndex = identifier.lastIndex(where: { !$0.isNumber }) else {
            // Entirely digits already — a valid numeric identifier as-is,
            // nothing to split (and splitting further would just yield an
            // empty prefix).
            return [identifier]
        }
        let digitsStart = identifier.index(after: lastNonDigitIndex)
        guard digitsStart < identifier.endIndex else {
            // No trailing digit run at all (e.g. "beta").
            return [identifier]
        }
        return [String(identifier[identifier.startIndex..<digitsStart]), String(identifier[digitsStart...])]
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        guard !prereleaseIdentifiers.isEmpty else { return core }
        return "\(core)-\(prereleaseIdentifiers.joined(separator: "."))"
    }

    /// SemVer §11 precedence: major.minor.patch compared numerically first;
    /// for equal core versions, a version *without* a pre-release always
    /// outranks one *with* a pre-release (`1.1.0-beta < 1.1.0`); between two
    /// pre-releases, identifiers are compared pairwise left-to-right —
    /// numeric identifiers compare numerically and always rank below
    /// alphanumeric ones, alphanumeric identifiers compare by ASCII order,
    /// and a version whose identifiers are a strict prefix of the other's
    /// (all shared identifiers equal, but one has more) ranks lower.
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.prereleaseIdentifiers.isEmpty, rhs.prereleaseIdentifiers.isEmpty) {
        case (true, true):
            return false
        case (true, false):
            return false
        case (false, true):
            return true
        case (false, false):
            let lhsIds = lhs.prereleaseIdentifiers
            let rhsIds = rhs.prereleaseIdentifiers
            for index in 0..<min(lhsIds.count, rhsIds.count) {
                let lhsId = lhsIds[index]
                let rhsId = rhsIds[index]
                if lhsId == rhsId { continue }
                switch (Int(lhsId), Int(rhsId)) {
                case let (lhsNumber?, rhsNumber?):
                    return lhsNumber < rhsNumber
                case (nil, nil):
                    return lhsId < rhsId
                case (nil, _?):
                    // lhs is alphanumeric, rhs is numeric — numeric always
                    // ranks lower, so lhs is NOT less than rhs.
                    return false
                case (_?, nil):
                    // lhs is numeric, rhs is alphanumeric — lhs ranks lower.
                    return true
                }
            }
            return lhsIds.count < rhsIds.count
        }
    }
}
