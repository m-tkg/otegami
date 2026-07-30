import Foundation

/// Task #182 (macOS アプリ内アップデート): the two facts this app compares
/// between the **currently-running** app bundle and a freshly-downloaded
/// candidate before ever replacing the former with the latter — spec:
/// "少なくとも Developer ID 署名が現在動いているアプリと同一であることを
/// 確認する (`codesign -dv` 相当の情報を取得して Team ID / 署名者を比較)"。
/// "検証に失敗したら差し替えない" is non-negotiable, so `AppUpdateInstaller`
/// (app layer, macOS-only) treats any mismatch — including either side
/// failing to parse at all — as a hard failure, never a "probably fine".
///
/// Deliberately **not** the Team ID/actual signer's real value baked in here
/// (`CLAUDE.md`'s "実名・Team ID...を書き込まない" — this repo is public) —
/// `AppUpdateInstaller` always derives both sides at runtime from whatever
/// this build and this download actually are, and `isSameSigner` compares
/// them structurally. Nothing in this type or its tests hardcodes this
/// project's real Team ID.
public struct CodeSignatureIdentity: Equatable, Sendable {
    /// Apple's stable per-developer-account identifier — survives
    /// certificate renewal (unlike `authority`'s embedded expiry/serial),
    /// so this is the primary signal `isSameSigner` checks.
    public let teamIdentifier: String?
    /// The first `Authority=` line (e.g. `"Developer ID Application: Example
    /// Developer (TEAMID1234)"`) — a secondary, defense-in-depth check
    /// alongside `teamIdentifier` (see `isSameSigner`'s doc comment).
    public let authority: String?

    public init(teamIdentifier: String?, authority: String?) {
        self.teamIdentifier = teamIdentifier
        self.authority = authority
    }

    /// Parses the text `/usr/bin/codesign -dv --verbose=4 <path>` writes —
    /// **to stderr**, a long-standing `codesign` quirk callers must
    /// remember to capture (the app-layer call site's own doc comment notes
    /// this again at the actual `Process` invocation). Only reads the two
    /// lines this type stores; every other line in the (often 20+ line)
    /// dump is ignored.
    public static func parse(codesignOutput: String) -> CodeSignatureIdentity {
        var teamIdentifier: String?
        var authority: String?
        for line in codesignOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if teamIdentifier == nil, trimmed.hasPrefix("TeamIdentifier=") {
                let value = trimmed.dropFirst("TeamIdentifier=".count)
                // Unsigned/ad-hoc-signed binaries print the literal string
                // "not set" here rather than omitting the line — treat that
                // the same as "no team identifier at all".
                teamIdentifier = (value == "not set") ? nil : String(value)
            } else if authority == nil, trimmed.hasPrefix("Authority=") {
                authority = String(trimmed.dropFirst("Authority=".count))
            }
        }
        return CodeSignatureIdentity(teamIdentifier: teamIdentifier, authority: authority)
    }

    /// Whether `self` (conventionally: the running app) and `candidate`
    /// (conventionally: the downloaded update) were signed by the same
    /// Developer ID identity. Requires **both** a non-nil, equal
    /// `teamIdentifier` **and** a non-nil, equal `authority` — either side
    /// being unsigned, ad-hoc-signed, or signed by a different identity
    /// fails this. Order doesn't matter (the comparison is symmetric); it's
    /// written as an instance method on the "current" side purely for
    /// readability at the call site (`currentIdentity.isSameSigner(as:
    /// candidateIdentity)`).
    public func isSameSigner(as candidate: CodeSignatureIdentity) -> Bool {
        guard let teamIdentifier, let candidateTeam = candidate.teamIdentifier, teamIdentifier == candidateTeam else {
            return false
        }
        guard let authority, let candidateAuthority = candidate.authority, authority == candidateAuthority else {
            return false
        }
        return true
    }
}
