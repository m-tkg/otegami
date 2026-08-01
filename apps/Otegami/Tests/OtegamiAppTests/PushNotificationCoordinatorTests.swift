import OtegamiStore
import Testing
@testable import Otegami

/// `AppEnvironment.isPushWatchCandidate(_:)` (Task #175) は「relay がこの
/// デバイスの代わりに watch できる意味のある資格情報を持つアカウントか」を
/// 判定する純粋な `nonisolated static func`。`.password` は常に true、
/// `.oauth2` は `.gmail`/`.microsoft` のみ true — 実運用では作られないはずの
/// `.oauth2` + `.generic`/`.icloud` の組み合わせも false になることを確認する
/// (関数のドキュメントコメントに書かれている前提そのもの)。
@Suite("AppEnvironment.isPushWatchCandidate")
struct PushNotificationCoordinatorTests {
    @Test
    func passwordAccountIsAlwaysAWatchCandidate() {
        let account = Self.makeAccount(authType: .password, kind: .generic)
        #expect(AppEnvironment.isPushWatchCandidate(account))
    }

    @Test(arguments: [AccountKind.gmail, .microsoft])
    func oauth2AccountIsAWatchCandidateForGmailAndMicrosoft(kind: AccountKind) {
        let account = Self.makeAccount(authType: .oauth2, kind: kind)
        #expect(AppEnvironment.isPushWatchCandidate(account))
    }

    @Test(arguments: [AccountKind.generic, .icloud])
    func oauth2AccountIsNotAWatchCandidateForOtherKinds(kind: AccountKind) {
        // `.oauth2` と `.generic`/`.icloud` の組み合わせは実運用では作られない
        // (このアプリが作る `.oauth2` アカウントは常に `.gmail`/`.microsoft`)
        // が、関数のドキュメントコメント通り false になることを確認する。
        let account = Self.makeAccount(authType: .oauth2, kind: kind)
        #expect(!AppEnvironment.isPushWatchCandidate(account))
    }

    private static func makeAccount(authType: AccountAuthType, kind: AccountKind) -> AccountRecord {
        AccountRecord(
            displayName: "Test Account",
            email: "test@example.com",
            authType: authType,
            kind: kind,
            imapHost: "imap.example.com",
            imapPort: 993,
            imapSecurity: .tls,
            imapUsername: "test@example.com"
        )
    }
}
