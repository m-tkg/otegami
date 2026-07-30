import Testing
@testable import OtegamiCore

/// Task #182 (macOS アプリ内アップデート): covers parsing `codesign -dv
/// --verbose=4`'s text dump and the same-signer comparison
/// `AppUpdateInstaller` uses to decide whether a downloaded update is safe to
/// install in place of the running app — see `CodeSignatureIdentity`'s doc
/// comment. Fixture text below uses an obviously-fake team id/name (never
/// this project's real one — `CLAUDE.md`'s no-real-Team-ID rule), shaped
/// exactly like a real `codesign -dv --verbose=4` dump.
struct CodeSignatureIdentityTests {
    private static let sampleDump = """
    Executable=/Applications/Otegami.app/Contents/MacOS/Otegami
    Identifier=com.mtkg.otegami
    Format=app bundle with Mach-O thin (arm64)
    CodeDirectory v=20500 size=1234 flags=0x10000(runtime) hashes=32+7 location=embedded
    Signature size=4661
    Authority=Developer ID Application: Example Developer (ABCDE12345)
    Authority=Developer ID Certification Authority
    Authority=Apple Root CA
    Timestamp=Jul 30, 2026 at 12:00:00
    Info.plist entries=45
    TeamIdentifier=ABCDE12345
    Runtime Version=15.0.0
    Sealed Resources version=2 rules=13 files=210
    Internal requirements count=1 size=180
    """

    @Test("parses TeamIdentifier and the first Authority line out of a real codesign -dv dump")
    func parsesTeamIdentifierAndAuthority() {
        let identity = CodeSignatureIdentity.parse(codesignOutput: Self.sampleDump)
        #expect(identity.teamIdentifier == "ABCDE12345")
        #expect(identity.authority == "Developer ID Application: Example Developer (ABCDE12345)")
    }

    @Test("treats the literal 'TeamIdentifier=not set' as no team identifier")
    func treatsNotSetAsNil() {
        let identity = CodeSignatureIdentity.parse(codesignOutput: "TeamIdentifier=not set\n")
        #expect(identity.teamIdentifier == nil)
    }

    @Test("returns nil for both fields when neither line is present (unsigned binary)")
    func returnsNilForUnsignedBinary() {
        let identity = CodeSignatureIdentity.parse(codesignOutput: "code object is not signed at all\n")
        #expect(identity.teamIdentifier == nil)
        #expect(identity.authority == nil)
    }

    @Test("identical team identifier and authority are the same signer")
    func identicalIdentitiesMatch() {
        let a = CodeSignatureIdentity(teamIdentifier: "ABCDE12345", authority: "Developer ID Application: Example Developer (ABCDE12345)")
        let b = CodeSignatureIdentity(teamIdentifier: "ABCDE12345", authority: "Developer ID Application: Example Developer (ABCDE12345)")
        #expect(a.isSameSigner(as: b))
    }

    @Test("a different team identifier is never the same signer, even with a matching authority string")
    func differentTeamIdentifierFails() {
        let running = CodeSignatureIdentity(teamIdentifier: "ABCDE12345", authority: "Developer ID Application: Example Developer (ABCDE12345)")
        let attacker = CodeSignatureIdentity(teamIdentifier: "ZZZZZ99999", authority: "Developer ID Application: Example Developer (ABCDE12345)")
        #expect(!running.isSameSigner(as: attacker))
    }

    @Test("a different authority string is never the same signer, even with a matching team identifier")
    func differentAuthorityFails() {
        let running = CodeSignatureIdentity(teamIdentifier: "ABCDE12345", authority: "Developer ID Application: Example Developer (ABCDE12345)")
        let impostor = CodeSignatureIdentity(teamIdentifier: "ABCDE12345", authority: "Developer ID Application: Someone Else (ABCDE12345)")
        #expect(!running.isSameSigner(as: impostor))
    }

    @Test("an unsigned candidate never matches a signed running app")
    func unsignedCandidateFails() {
        let running = CodeSignatureIdentity(teamIdentifier: "ABCDE12345", authority: "Developer ID Application: Example Developer (ABCDE12345)")
        let unsigned = CodeSignatureIdentity(teamIdentifier: nil, authority: nil)
        #expect(!running.isSameSigner(as: unsigned))
    }

    @Test("two unsigned identities never count as the same signer")
    func twoUnsignedNeverMatch() {
        let a = CodeSignatureIdentity(teamIdentifier: nil, authority: nil)
        let b = CodeSignatureIdentity(teamIdentifier: nil, authority: nil)
        #expect(!a.isSameSigner(as: b))
    }
}
